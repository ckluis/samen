defmodule Samen.Replay.Supervisor do
  @moduledoc """
  The capture plane's supervision tree, started by `Samen.Observability.child_specs/2` ONLY when
  the host turns replay on (`replay: true` / a keyword list). With replay off, the child list
  is byte-for-byte what it was before ADR-052 P2.

  At start it validates the configuration (fail-honest: an out-of-range retention window or
  cap raises before anything is captured), installs the replay retention specs into
  `:samen_core, :retention_specs` (idempotent — the host's boot already installs them wherever
  the replay tables are mounted, capture on or off: `Samen.Observability.child_specs/2`,
  ADR-052 §2.4.1), publishes the runtime config, and attaches the `Samen.Replay.Capture` event
  handler. Persist tasks are bounded (`max_persist_tasks`, `Samen.Replay.Monitor`).
  """
  use Supervisor

  alias Samen.Replay.{Capture, Monitor}

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    cfg = Samen.Replay.config!(opts)
    _ = Samen.Replay.install_retention_specs(retention_days: cfg.retention_days)

    children = [
      {Task.Supervisor, name: Samen.Replay.TaskSupervisor, max_children: cfg.max_persist_tasks},
      {Monitor, task_sup: Samen.Replay.TaskSupervisor},
      %{
        id: Samen.Replay.Activate,
        start: {__MODULE__, :activate, [cfg]},
        restart: :transient,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  # Publish the config + attach the event handler once the buffer table exists.
  @spec activate(Samen.Replay.config()) :: :ignore
  def activate(cfg) do
    Samen.Replay.put_runtime_config(cfg)
    _ = Capture.attach()
    :ignore
  end
end
