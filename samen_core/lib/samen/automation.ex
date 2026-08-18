defmodule Samen.Automation do
  @moduledoc """
  Public API + host-wired seams for the E1 automation engine (ADR-039 §3.2). The
  kernel is mount-agnostic: the concrete `Workflow` resource + repo are host-owned
  modules resolved from config at runtime (the `Samen.Notifications.Engine`
  convention), never compiled in.

      config :samen_core, Samen.Automation,
        workflow_module: Demo.AutomationScope.Workflow,
        repo:            Demo.Repo

  Every public entry accepts these as explicit opts (a test/caller override); opts win
  over config. When no `:workflow_module` is reachable the engine is **inert** (capture
  inserts nothing, dispatch finds nothing) rather than raising — automation is opt-in
  per host, exactly like the notifications engine's unwired posture. The public
  fire entrypoints, by contrast, fail CLOSED (`{:error, :no_automation_module}`) so a
  caller that explicitly asks to run an automation gets an honest failure, not a
  silent drop.

  ## Trigger taxonomy (ADR-039 §4.1)

    * `resource_event` — captured in-transaction by `Samen.Automation.EventCapture`.
    * `schedule` — the AshOban `:schedule_scan` trigger on the Workflow resource.
    * `manual` — `trigger_manual/4` (the builder's "Run now").
  """

  alias Samen.Automation.{DispatchWorker, EventCapture}

  @doc "Resolve the host `Workflow` module (opts win over config); `nil` when unwired."
  @spec workflow_module(keyword()) :: module() | nil
  def workflow_module(opts \\ []), do: opt(opts, :workflow_module)

  @doc "Resolve the host repo (opts win over config)."
  @spec repo(keyword()) :: module() | nil
  def repo(opts \\ []), do: opt(opts, :repo)

  @doc """
  Resolve the host `Run` module (opts win over config); `nil` when unwired
  (ADR-039 §8.1; T42). `Samen.Automation.RunRecord`/`Health`/`Breaker` degrade
  to no-ops when this is unset — observability is opt-in per host, exactly
  like the engine itself.
  """
  @spec run_module(keyword()) :: module() | nil
  def run_module(opts \\ []), do: opt(opts, :run_module)

  @doc "The configured loop depth cap (ADR-039 §4.7 guard 2). Default 3."
  @spec max_depth() :: non_neg_integer()
  def max_depth, do: Application.get_env(:samen_core, :automation_max_depth, 3)

  @doc """
  Fire a workflow **manually** against a chosen subject (the builder "Run now"; also
  the test-run affordance). Enqueues the same pipeline as an event trigger, tagged
  `trigger_kind: :manual`. Fails closed when the engine is unwired.

  `subject_ref` is an object ref (`"samen:<key>:<id>"`); `record_id`/`resource_key`
  locate the governed re-read.
  """
  @spec trigger_manual(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def trigger_manual(%{workflow_id: _, org_id: _} = attrs, opts \\ []) do
    if is_nil(workflow_module(opts)) do
      {:error, :no_automation_module}
    else
      envelope =
        %{
          "org_id" => attrs.org_id,
          "workflow_id" => attrs.workflow_id,
          "resource_key" => Map.get(attrs, :resource_key),
          "record_id" => Map.get(attrs, :record_id),
          "subject_ref" => Map.get(attrs, :subject_ref),
          "event" => "manual",
          "trigger_kind" => "manual",
          "changed" => [],
          "event_id" => Map.get(attrs, :event_id, Ecto.UUID.generate()),
          "depth" => 0,
          "chain" => []
        }

      case Oban.insert(DispatchWorker.new(envelope)) do
        {:ok, job} -> {:ok, %{enqueued: true, job_id: job.id, event_id: envelope["event_id"]}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Build the non-PII resource-event envelope (ADR-039 §4.2) for a committed write.
  Exposed for `Samen.Automation.EventCapture` and for direct testing of the envelope
  shape (the §11 "ids/names only, no values" assertion). Carries attribute NAMES
  (catalog metadata), never attribute VALUES.
  """
  @spec event_envelope(map()) :: map()
  def event_envelope(fields), do: EventCapture.envelope(fields)

  # ---------------------------------------------------------------------------

  defp opt(opts, key) do
    Keyword.get(opts, key) || Keyword.get(config(), key)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end
