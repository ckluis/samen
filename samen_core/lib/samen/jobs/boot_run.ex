defmodule Samen.Jobs.BootRun do
  @moduledoc """
  Oban plugin that enqueues each of its `:workers` once, when Oban starts.

  For a job a node must not wait a day for. `Samen.AuditEvent.PartitionManager` is the
  case: its cron runs at 01:00 UTC, so an app that boots without the current month's
  `aud_event` partition — an adopter whose migration seeded only a fixed launch month,
  or an app restarted after more than its two-month lookahead of downtime — would refuse
  every audit write until then. `Samen.Jobs.install_defaults/1` installs this plugin
  with `Samen.Jobs.default_boot_workers/0`.

      plugins: [{Samen.Jobs.BootRun, workers: [Samen.AuditEvent.PartitionManager]}]

  Each worker is enqueued as `worker.new(%{})`, with the worker's own options. Every
  node that boots enqueues, so the workers listed here must be unique (the
  PartitionManager is, for 23 hours): a second node, a quick restart, or the day's cron
  run then dedupes to one job. An insert that raises — the database not reachable yet —
  is retried every `:retry_ms` (default 30 s) until it lands.
  """

  @behaviour Oban.Plugin

  use GenServer

  require Logger

  alias Oban.Validation

  @default_retry_ms 30_000

  @impl Oban.Plugin
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl Oban.Plugin
  def validate(opts) do
    Validation.validate_schema(opts,
      conf: :any,
      name: :any,
      workers: {:list, :atom},
      retry_ms: :pos_integer
    )
  end

  @impl GenServer
  def init(opts) do
    # Oban has already run `validate/1` on these options (`Oban.Config`).
    state = %{
      conf: Keyword.fetch!(opts, :conf),
      pending: Keyword.get(opts, :workers, []),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms)
    }

    {:ok, state, {:continue, :enqueue}}
  end

  @impl GenServer
  def handle_continue(:enqueue, state), do: {:noreply, enqueue(state), :hibernate}

  @impl GenServer
  def handle_info(:enqueue, state), do: {:noreply, enqueue(state), :hibernate}

  # Enqueue what is still pending; keep what failed and try it again after `retry_ms`.
  # The process stays up once done: Oban restarts a plugin that exits, even normally.
  defp enqueue(%{pending: pending} = state) do
    failed = Enum.reject(pending, &settled?(state.conf, &1))
    if failed != [], do: Process.send_after(self(), :enqueue, state.retry_ms)
    %{state | pending: failed}
  end

  # true once the insert is done with: enqueued (or deduped), or refused for good.
  defp settled?(conf, worker) do
    case Oban.insert(conf.name, worker.new(%{})) do
      {:ok, _job} ->
        true

      # Refused, not unreachable (an invalid changeset): retrying cannot change that.
      {:error, reason} ->
        Logger.error("[Samen.Jobs.BootRun] #{inspect(worker)} not enqueued: #{inspect(reason)}")
        true
    end
  rescue
    error ->
      Logger.warning(
        "[Samen.Jobs.BootRun] #{inspect(worker)} not enqueued yet, retrying: " <>
          Exception.message(error)
      )

      false
  end
end
