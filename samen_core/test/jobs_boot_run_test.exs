defmodule Samen.Jobs.BootRunTest do
  @moduledoc """
  `Samen.Jobs.BootRun`: a real Oban instance with the plugin enqueues its workers once at
  start — the boot-time `aud_event` partition roll-forward every generated app gets from
  `Samen.Jobs.install_defaults/1` — dedupes on a restart, and retries an insert that raised.

  Each test waits on the plugin itself, not on a duration: `:sys.get_state/1` returns only
  after the plugin's `handle_continue/2` (its boot enqueue) has run.
  """
  use ExUnit.Case, async: false

  # The retry test logs the raised insert by design.
  @moduletag :capture_log

  import Ecto.Query

  alias Samen.AuditEvent.PartitionManager
  alias Samen.Jobs.BootRun
  alias SamenCore.TestRepo, as: Repo

  # Raises on its first `new/1`, then builds a normal job; reports each attempt to the test.
  defmodule RaisesOnceWorker do
    def new(args) do
      {test_pid, attempts} = :persistent_term.get(__MODULE__)
      :ok = :counters.add(attempts, 1, 1)
      attempt = :counters.get(attempts, 1)
      send(test_pid, {:boot_run_attempt, attempt})
      if attempt == 1, do: raise(DBConnection.ConnectionError, "connection not available")
      Oban.Job.new(args, worker: __MODULE__, queue: :maintenance)
    end
  end

  setup do
    # The plugin inserts from its own process: it reaches the test's sandboxed connection
    # through shared mode, and its rows roll back with the test.
    Samen.TestSandbox.shared!(Repo)
    :ok
  end

  # Started after `shared!/1`, so ExUnit stops it before that owner is released. No queues:
  # the enqueued job stays `available`, where the test can count it.
  defp start_oban(plugin_opts) do
    start_supervised!(
      {Oban,
       repo: Repo,
       queues: false,
       plugins: [{BootRun, plugin_opts}],
       notifier: Oban.Notifiers.PG,
       peer: false,
       name: BootRunTestOban},
      id: :boot_run_oban
    )

    plugin = Oban.Registry.whereis(BootRunTestOban, {:plugin, BootRun})
    assert is_pid(plugin), "Oban did not start the BootRun plugin"
    plugin
  end

  defp jobs_for(worker) do
    name = inspect(worker)
    Repo.all(from j in Oban.Job, where: j.worker == ^name, select: j.state)
  end

  test "an Oban start with BootRun enqueues the partition roll-forward once" do
    assert jobs_for(PartitionManager) == []

    plugin = start_oban(workers: [PartitionManager])

    assert %{pending: []} = :sys.get_state(plugin)
    assert jobs_for(PartitionManager) == ["available"]
  end

  test "a job from today's cron run, or from an earlier boot, dedupes it" do
    # What the 01:00 cron leaves behind: a completed PartitionManager job, with cron meta.
    Repo.insert!(
      PartitionManager.new(%{}, meta: %{"cron" => true, "cron_expr" => "0 1 * * *"})
      |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    )

    plugin = start_oban(workers: [PartitionManager])
    assert %{pending: []} = :sys.get_state(plugin)
    assert jobs_for(PartitionManager) == ["completed"]

    stop_supervised!(:boot_run_oban)
    plugin = start_oban(workers: [PartitionManager])
    assert %{pending: []} = :sys.get_state(plugin)
    assert jobs_for(PartitionManager) == ["completed"]
  end

  test "an insert that raised is retried until it lands" do
    :persistent_term.put(RaisesOnceWorker, {self(), :counters.new(1, [])})
    on_exit(fn -> :persistent_term.erase(RaisesOnceWorker) end)

    plugin = start_oban(workers: [RaisesOnceWorker], retry_ms: 1)

    assert_receive {:boot_run_attempt, 1}
    assert_receive {:boot_run_attempt, 2}
    assert %{pending: []} = :sys.get_state(plugin)
    assert jobs_for(RaisesOnceWorker) == ["available"]
    refute_received {:boot_run_attempt, 3}
  end
end
