defmodule Samen.Delivery.ThrottleSnoozeStubAdapter do
  @moduledoc """
  Adapter double for the T170 worker reds. Its `deliver/2` returns whatever
  `config[:canned_response]` holds — the harness threads it through the worker's
  `adapter_config`, which is the same `:adapter_config` seam a host uses, so the worker
  is driven through its REAL `Chokepoint.send/2` path.
  """
  use Samen.Delivery.Provider

  @impl true
  def configured?(_config), do: true

  @impl true
  def deliver(_message, config) do
    Map.get(config, :canned_response, {:ok, %{provider_message_id: "stub-1"}})
  end
end

defmodule Samen.Delivery.ThrottleSnoozeTest do
  @moduledoc """
  T170 (bug half) RED PATHS at the WORKER boundary — an ESP throttle must come back from
  `perform/1` as `{:snooze, seconds}`, never as `{:error, _}`.

  This is the half of the bug that actually storms: the three Oban workers below return
  `{:error, reason}` to Oban, and Oban retries it on its ordinary exponential schedule.
  Before T170 an ESP `429` was an ordinary error, so each throttle became a retry against
  an account that had just said "too fast", and burned one of 20 attempts.

  `{:snooze, seconds}` is the fix: Oban re-schedules and raises `max_attempts` to
  compensate, so a throttle costs NO attempt.

  `Samen.Sequences.SendWorker` is deliberately NOT here: it returns `:ok` to Oban on
  EVERY determined outcome by design (its enrollment-level watchdog is the one retry
  authority for a sequence step), so no Oban retry storm exists on that path to fix.

  Positive controls per worker: a 500 still comes back as an `{:error, _}` Oban retries
  exactly as today, and a 2xx still returns `:ok`.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Delivery.ThrottleSnoozeStubAdapter, as: Stub
  alias Samen.Notifications.EmailDispatchWorker
  alias Samen.Scopes.Marketing.SendWorker
  alias SamenCore.TestRepo

  @workers [
    {EmailWorker, %{"send_id" => "s1", "org_id" => nil, "event" => "welcome"}},
    {SendWorker, %{"send_id" => "s2", "org_id" => nil}},
    {EmailDispatchWorker, %{"send_id" => "s3", "org_id" => nil}}
  ]

  setup do
    # Issue #45: every worker below routes through Samen.Delivery.Chokepoint,
    # and its :adapter_unconfigured arm (SendWorker.emit_blocked_audit/2 in
    # particular) writes this test's non-UUID "s1"/"s2"/"s3" send_ids straight
    # into aud_event.aud_subject_id (Samen.AuditEvent.insert/2). Every sibling
    # suite that touches Postgres takes this same sandbox checkout (see
    # test/retention_sweep_test.exs, test/feature_flags_engine_test.exs) so
    # its writes roll back with the test; this file omitted it, so those rows
    # could survive the test and later poison Samen.Rollup.refresh/2's
    # aud_subject_id::uuid cast (ERROR 22P02) for every rollup rebuild in the
    # same run — see test/delivery/throttle_snooze_isolation_test.exs.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

    previous =
      Map.new([EmailWorker, SendWorker, EmailDispatchWorker], fn worker ->
        {worker, Application.get_env(:samen_core, worker)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {worker, nil} -> Application.delete_env(:samen_core, worker)
        {worker, value} -> Application.put_env(:samen_core, worker, value)
      end)
    end)

    :ok
  end

  defp configure(worker, response) do
    Application.put_env(:samen_core, worker,
      adapter: Stub,
      adapter_config: %{canned_response: response}
    )
  end

  defp run(worker, args, response) do
    configure(worker, response)
    worker.perform(%Oban.Job{args: args})
  end

  # ---------------------------------------------------------------------------
  # RED

  test "T170 RED: an ESP throttle SNOOZES for the ESP's own Retry-After — no burned attempt" do
    for {worker, args} <- @workers do
      result = run(worker, args, {:error, {:throttled, 90}})

      assert result == {:snooze, 90},
             "#{inspect(worker)}.perform/1 must SNOOZE on an ESP throttle, got: #{inspect(result)}"
    end
  end

  test "T170 RED: a throttle is never returned to Oban as an error (that IS the retry storm)" do
    for {worker, args} <- @workers do
      result = run(worker, args, {:error, {:throttled, 5}})

      refute match?({:error, _}, result),
             "#{inspect(worker)}.perform/1 returned an Oban RETRY for a throttle: #{inspect(result)}"

      assert {:snooze, 5} = result
    end
  end

  test "T170 RED: the snooze carries the adapter's seconds verbatim, not a fixed constant" do
    for {worker, args} <- @workers do
      assert {:snooze, 1} = run(worker, args, {:error, {:throttled, 1}})
      assert {:snooze, 3600} = run(worker, args, {:error, {:throttled, 3600}})
    end
  end

  # ---------------------------------------------------------------------------
  # POSITIVE CONTROLS

  test "T170 POSITIVE CONTROL: a 500 from the ESP still comes back as an Oban RETRY" do
    for {worker, args} <- @workers do
      result = run(worker, args, {:error, {:http_status, 500}})

      assert match?({:error, _}, result),
             "#{inspect(worker)}.perform/1 must still ask Oban to retry a genuine failure, " <>
               "got: #{inspect(result)}"

      refute match?({:snooze, _}, result)
    end
  end

  test "T170 POSITIVE CONTROL: :adapter_unconfigured is still the blocked error, never a snooze" do
    for {worker, args} <- @workers do
      result = run(worker, args, {:error, :adapter_unconfigured})
      refute match?({:snooze, _}, result)
    end
  end

  test "T170 POSITIVE CONTROL: a successful delivery still returns :ok" do
    for {worker, args} <- @workers do
      result = run(worker, args, {:ok, %{provider_message_id: "stub-1"}})

      assert result == :ok,
             "#{inspect(worker)}.perform/1 must still return :ok on a real delivery, " <>
               "got: #{inspect(result)}"
    end
  end
end
