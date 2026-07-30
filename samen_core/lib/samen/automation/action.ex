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
    depth: 0,
    chain: []
  ]

  @type t :: %__MODULE__{
          org_id: String.t(),
          workflow_id: String.t(),
          run_id: String.t() | nil,
          subject_ref: String.t(),
          subject: map() | nil,
          actor: term(),
          event: atom() | nil,
          resource_key: String.t() | nil,
          record_id: String.t() | nil,
          event_id: String.t() | nil,
          webhook_secret: String.t() | nil,
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

  ## Registry

  Bounded `kind` string → module. Host-extendable via
  `config :samen_core, Samen.Automation.Action, extra: %{"kind" => Module}`; the core
  kinds below always win over host entries (a host cannot shadow `notify`).
  """

  @callback kind() :: atom()
  @callback validate(config :: map(), resource_key :: String.t()) ::
              {:ok, normalized :: map()} | {:error, term()}
  @callback run(config :: map(), ctx :: Samen.Automation.Context.t()) ::
              {:ok, meta :: map()} | {:error, error_kind :: atom()}
  @callback undo(config :: map(), meta :: map(), ctx :: Samen.Automation.Context.t()) ::
              :ok | {:error, term()}

  @optional_callbacks undo: 3

  # The core-shipped kinds (ADR-039 §5.2 — exactly 8; T39 shipped `notify`, T40
  # fills the remaining 7). `mutate_record` merges the spec's "create/update a
  # record" into ONE kind with a `mode` (ADR-039 §5.2 note) — this map has 8
  # entries, matching T40's table-driven one-test-per-action test.
  @core %{
    "notify" => Samen.Automation.Notify,
    "send_email" => Samen.Automation.Actions.SendEmail,
    "mutate_record" => Samen.Automation.Actions.MutateRecord,
    "assign_owner" => Samen.Automation.Actions.AssignOwner,
    "add_tag" => Samen.Automation.Actions.AddTag,
    "escalate" => Samen.Automation.Actions.Escalate,
    "webhook" => Samen.Automation.Actions.Webhook,
    "enqueue_reminder" => Samen.Automation.Actions.EnqueueReminder
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
