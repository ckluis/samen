defmodule Samen.Automation.Context do
  @moduledoc """
  The fire-time context handed to every `Samen.Automation.Action` (ADR-039 §5.1).

  Carries ONLY bounded ids/enums/refs + the governed subject re-read (a map of
  condition-eligible attributes — never a vault field). `actor` is the workflow
  OWNER re-resolved at run time (ADR-039 §4.5): every action executes through
  governed Ash actions authorized as that member on the tenant plane, so a vault
  field read resolves to `%Masked{}` and no plaintext leaks (INV-1).

  ## T40 additions (record-mutation + webhook actions)

  T39 shipped the fields the `notify` action needed. T40's record-mutation family
  (`mutate_record` update mode, `assign_owner`, `add_tag`) needs to locate and
  re-fetch the SUBJECT record itself, and the `webhook` action needs the
  workflow's signing secret and the triggering event's id (for a stable
  `delivery_id`) — none of which `notify` ever touched. Four fields are added,
  all optional/additive (a struct match on `%Context{}` is unaffected; `Notify`
  ignores them):

    * `:resource_key` — the trigger's target resource module string (mirrors the
      envelope field `Samen.Automation.RunWorker` already reads to build the
      eligible-only `subject` map — now threaded onto the struct too).
    * `:record_id` — the subject record's id (nil for a schedule/manual trigger
      with no chosen record).
    * `:event_id` — the envelope's event id (nil for schedule/manual).
    * `:webhook_secret` — the workflow's per-row HMAC secret (ADR-039 §5.3), read
      once by `RunWorker` from the Workflow row — never re-fetched by the action,
      never logged, never placed in any outcome meta.

  ## A3 addition (ADR-047 §5.1): `:origin`

  An AGENT tool call also fires a governed action, but an agent run is not a
  workflow — stuffing a run id into `:workflow_id` would be a lie the Health
  surface then renders. One optional, additive field carries the provenance
  instead (exactly as T40 added four optional fields without breaking any
  `%Context{}` match):

    * `:origin` — `{:workflow, workflow_id}` | `{:agent, run_id}` | `nil` (a
      pre-A3 workflow context). `:workflow_id` is nil-able ONLY when `origin` is
      `{:agent, _}`, and the ONE site constructing an agent-origin context is
      `Samen.AI.Agent.Context.build/2` — the workflow pipeline never sets it.
  """

  @enforce_keys [:org_id, :workflow_id, :subject_ref]
  defstruct [
    :org_id,
    :workflow_id,
    :run_id,
    :subject_ref,
    :subject,
    :actor,
    :event,
    :resource_key,
    :record_id,
    :event_id,
    :webhook_secret,
    :origin,
    depth: 0,
    chain: []
  ]

  @type t :: %__MODULE__{
          org_id: String.t(),
          workflow_id: String.t() | nil,
          run_id: String.t() | nil,
          subject_ref: String.t(),
          subject: map() | nil,
          actor: term(),
          event: atom() | nil,
          resource_key: String.t() | nil,
          record_id: String.t() | nil,
          event_id: String.t() | nil,
          webhook_secret: String.t() | nil,
          origin: {:workflow, String.t()} | {:agent, String.t()} | nil,
          depth: non_neg_integer(),
          chain: [String.t()]
        }
end

defmodule Samen.Automation.Action do
  @moduledoc """
  The E2 action behaviour (ADR-039 §5.1). T39 ships the behaviour + the single
  `Samen.Automation.Notify` action (the minimal end-to-end proof); T40 fills the
  remaining seven and the webhook egress contract. T40 plugs in by adding modules
  to the registry — the pipeline (capture → dispatch → run → compile) never changes.

  ## The three faces

    * `kind/0` — the bounded registry string key.
    * `validate/2` — WRITE-time config validation, called by the Workflow changeset
      ALONGSIDE `Samen.Automation.NonPiiPredicates` (bad configs refused at save,
      never at fire time). Interpolations that reference a subject attribute must
      reference a **condition-eligible** one — the same oracle gate (ADR-039 §5.2).
    * `run/2` — fire time. Returns `{:ok, meta}` (bounded ids/enums only — lands in
      the Run outcome) or `{:error, error_kind}`. An action error NEVER crashes the
      engine (ADR-039 §5.1): the run finalizes `:failed`, completed steps compensate.
    * `undo/3` — optional Reactor compensation face (ADR-037 §5.7).

  ## The two AGENT-TOOL faces (ADR-047 §5.1, batch A3 — both fail-closed by default)

    * `tool_schema/0` — the EXPLICIT per-action agent-tool opt-in. An action that does
      not export it (or returns `:not_a_tool`) is **not a tool**: it can never be
      offered to, or called by, a `Samen.AI.Agent` run, no matter what an agent
      definition declares. A returned schema MUST be a compile-time constant of the
      action module (a bounded `%{name:, description:, params: [...]}` map — never
      derived from tenant data; ADR-047 §4.2's static-schema rule, enforced at the
      chokepoint by the registered-static-def membership check and structurally by
      `mix samen.verify.ai_prompt_masking` check (d) at A7).
    * `effect/0` — `:read | :write`. An action that does not declare is `:write`
      (approval-gated through E3, ADR-047 §5.3) — forgetting to declare parks an
      action under the approval gate rather than executing it autonomously. Batch A3
      executes ONLY `effect: :read` tools inline; `:write` tools propose via
      `Samen.Approvals.Gate` at A4.

  **No shipped action becomes a tool by accident**: the 8 ADR-039 kinds export
  NEITHER callback, so all 8 are `:not_a_tool` (and would be `:write` even if opted
  in). The only opted-in tools are A3's two read-effect actions and A4's ONE
  write-effect action below — every one an explicit, reviewed edit to a module.

  A4's `assign_record_owner` is `effect: :write`: `Samen.AI.Agent` never invokes its
  `run/2` from a turn. The turn opens an E3 approval and the run parks; a distinct human's
  approve is the only thing that executes it, with the APPROVER's actor (ADR-043 §6.2,
  unamended — ADR-047 §5.3).

  ## Registry

  Bounded `kind` string → module. Host-extendable via
  `config :samen_core, Samen.Automation.Action, extra: %{"kind" => Module}`; the core
  kinds below always win over host entries (a host cannot shadow `notify`).
  """

  @callback kind() :: atom()
  @callback validate(config :: map(), resource_key :: String.t() | nil) ::
              {:ok, normalized :: map()} | {:error, term()}
  @callback run(config :: map(), ctx :: Samen.Automation.Context.t()) ::
              {:ok, meta :: map()} | {:error, error_kind :: atom()}
  @callback undo(config :: map(), meta :: map(), ctx :: Samen.Automation.Context.t()) ::
              :ok | {:error, term()}
  @callback tool_schema() :: map() | :not_a_tool
  @callback effect() :: :read | :write

  @optional_callbacks undo: 3, tool_schema: 0, effect: 0

  # The core-shipped kinds. ADR-039 §5.2's exactly-8 side-effecting kinds (T39 shipped
  # `notify`, T40 the remaining 7; `mutate_record` merges the spec's "create/update a
  # record" into ONE kind with a `mode` — ADR-039 §5.2 note, matching T40's
  # table-driven one-test-per-action test), PLUS ADR-047 §5.1's two READ-EFFECT
  # agent-tool actions (batch A3: `search_records`, `fetch_record`) — added to the
  # SAME registry, never a forked second read-tool allowlist: **one registry stays
  # the one allowlist**, which is the whole reason the registry is trustworthy.
  @core %{
    "notify" => Samen.Automation.Notify,
    "send_email" => Samen.Automation.Actions.SendEmail,
    "mutate_record" => Samen.Automation.Actions.MutateRecord,
    "assign_owner" => Samen.Automation.Actions.AssignOwner,
    "add_tag" => Samen.Automation.Actions.AddTag,
    "escalate" => Samen.Automation.Actions.Escalate,
    "webhook" => Samen.Automation.Actions.Webhook,
    "enqueue_reminder" => Samen.Automation.Actions.EnqueueReminder,
    "search_records" => Samen.Automation.Actions.SearchRecords,
    "fetch_record" => Samen.Automation.Actions.FetchRecord,
    "assign_record_owner" => Samen.Automation.Actions.AssignRecordOwner
  }

  @doc "Resolve a bounded action `kind` string to its module, or `nil`."
  @spec module_for(String.t()) :: module() | nil
  def module_for(kind) when is_binary(kind) do
    Map.get(@core, kind) || Map.get(host_extra(), kind)
  end

  def module_for(_), do: nil

  @doc "The full registry (core kinds win over host `:extra`)."
  @spec registry() :: %{optional(String.t()) => module()}
  def registry, do: Map.merge(host_extra(), @core)

  @doc "The bounded set of known action kind strings."
  @spec kinds() :: [String.t()]
  def kinds, do: registry() |> Map.keys() |> Enum.sort()

  @doc """
  The action module's agent-tool schema, or `:not_a_tool` (ADR-047 §5.1 — the
  DEFAULT for every module that does not explicitly export `tool_schema/0`).
  Fail-closed on every edge: a not-loadable module, a raising callback, or a
  non-map return all resolve `:not_a_tool` — an action never becomes a tool by
  accident, malfunction, or partial declaration.
  """
  @spec tool_schema_for(module() | nil) :: map() | :not_a_tool
  def tool_schema_for(mod) when is_atom(mod) and not is_nil(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :tool_schema, 0) do
      case mod.tool_schema() do
        schema when is_map(schema) and not is_struct(schema) -> schema
        _ -> :not_a_tool
      end
    else
      :not_a_tool
    end
  rescue
    _ -> :not_a_tool
  end

  def tool_schema_for(_), do: :not_a_tool

  @doc """
  The action module's declared effect class — `:read | :write` (ADR-047 §5.1).
  DEFAULT `:write` (fail-closed): a module that does not export `effect/0`, cannot
  be loaded, raises, or returns anything but the literal `:read` is `:write` —
  approval-gated, never inline-executed.
  """
  @spec effect_for(module() | nil) :: :read | :write
  def effect_for(mod) when is_atom(mod) and not is_nil(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :effect, 0) and
         mod.effect() == :read do
      :read
    else
      :write
    end
  rescue
    _ -> :write
  end

  def effect_for(_), do: :write

  @doc "The bounded set of OPTED-IN agent-tool kind strings (ADR-047 §5.1 arm 2)."
  @spec tool_kinds() :: [String.t()]
  def tool_kinds do
    registry()
    |> Enum.filter(fn {_kind, mod} -> tool_schema_for(mod) != :not_a_tool end)
    |> Enum.map(fn {kind, _mod} -> kind end)
    |> Enum.sort()
  end

  defp host_extra do
    :samen_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:extra, %{})
    |> case do
      m when is_map(m) -> m
      _ -> %{}
    end
  end
end
