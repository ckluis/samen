defmodule Samen.Web.Automation.Reads do
  @moduledoc """
  The framework AUTOMATION (workflow) read/write layer for the tenant-plane builder
  (ADR-039 §12 done-criterion 4; T118). Rides T39's engine substrate verbatim — this
  module adds NO policy, NO evaluator, NO classification of its own.

  ## A3 read-bounding

  The list reads through `workflows_page/3`, built on `Samen.Web.Reads.page!/3`
  (BOUNDED BY CONSTRUCTION); every lookup read carries an explicit `limit(1)`.

  ## Write side — the SAME governed actions T39 shipped, no elevation needed

  `Automation.Workflow`'s create/update/destroy policy is `OrgScope` +
  `RoleAtLeast :member` — the plain tenant mount scope (`Samen.Web.Plane.scope/2`'s
  `:tenant` clause) is already `role: :member`, so unlike `Samen.Web.Flags.Reads`
  (admin-gated) this module needs NO write-scope elevation. Every mutation goes
  through the SAME `:create`/`:update` actions, so `Samen.Automation.NonPiiPredicates`
  (INV-1 — condition keys / action interpolations must be condition-eligible) runs on
  EVERY write, whether it originates from the builder's condition form or a forged
  `handle_event` payload that never touched the picker.

  ## Pause/resume — the TENANT switch, not the operator kill-switch

  `toggle_pause/3` writes `status: :paused | :active` through the ordinary `:update`
  action (ADR-039 §8.4: "Tenant pause — owner-controlled in the builder"). It never
  touches `disabled_by_operator_at`/`disabled_reason` — those are the OPERATOR-only
  columns T42's `Samen.Web.Operator.AutomationHealthLive` kill-switch writes (a
  cross-org emergency stop, bypass-authorized, out of this task's scope per the
  handoff's non-goals). Two independent switches, same as ADR-039 §8.4 documents;
  this module owns exactly one of them.

  ## Manual "Run now" — the SAME dispatch pipeline, tagged `trigger_kind: :manual`

  `run_now/3` calls `Samen.Automation.trigger_manual/2` with EXPLICIT opts derived
  from the mount (`workflow_module: Mount.resource(mount, Workflow)`, `repo:
  mount.repo`) — opts win over host config (`Samen.Automation`'s own contract), so
  this works on any host regardless of whether it has ALSO wired the global
  `config :samen_core, Samen.Automation, ...` fallback. It enqueues the SAME
  `Samen.Automation.DispatchWorker` job an event/schedule trigger would.

  ## Eligibility — the ONE oracle, never a second list

  `eligible_attributes/1` delegates to `Samen.Automation.NonPiiPredicates.eligible_names/1`
  — the SAME classifier the write-time validation runs. A vault (`:token`) or
  `:plaintext_pii` attribute of the target resource is structurally never returned
  here, so the condition-key `<select>` never renders it as an option (INV-1's UI
  half — the write-time refusal is the enforcement; this is the "don't even offer it"
  posture the handoff names).
  """

  require Ash.Query

  alias Samen.Automation.{Action, NonPiiPredicates}
  alias Samen.Web.Mount

  @doc """
  Read ONE keyset page of the org's workflows — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`), built on `Samen.Web.Reads.page!/3`
  (BOUNDED BY CONSTRUCTION). `webhook_secret` is `public?: false` on the resource
  itself (never selectable through a public read) — not re-excluded here, it simply
  cannot appear. On any read error the page is EMPTY (fail-honest, never a raise
  surfaced to the render).
  """
  def workflows_page(mount, scope, state) do
    Mount.resource(mount, Workflow)
    |> Ash.Query.ensure_selected([
      :name,
      :status,
      :trigger_kind,
      :resource_key,
      :event,
      :schedule_cron,
      :next_fire_at,
      :conditions,
      :actions,
      :owner_id,
      :disabled_by_operator_at,
      :disabled_reason
    ])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :resource_key])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc "Read ONE workflow by id for `scope` (bounded lookup). `nil` when absent/denied."
  def get_workflow(mount, scope, id) do
    Mount.resource(mount, Workflow)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
  rescue
    _ -> nil
  end

  @doc """
  Author a NEW workflow through the sanctioned `:create` action (accepts `:*` —
  `name`/`status`/`trigger_kind`/`resource_key`/`event`/`schedule_cron`/
  `next_fire_at`/`conditions`/`actions`/`owner_id`). `conditions`/`actions` default
  to `[]` — a brand-new workflow starts as a bare trigger shell; conditions/actions
  are added via `update_workflow/4` once the row exists (mirrors the flags targeting-
  rule editor's add-after-create shape). `org_id` defaults to the acting scope's org.
  `{:ok, workflow}` or `{:error, message}` (friendly, surfaces the NonPiiPredicates
  refusal verbatim when the caller forges a non-eligible key). `owner_id` is left
  as the caller supplied it (a real host wires a proper member picker — the
  mount's own synthetic tenant actor id is NOT a valid `owner_id` uuid, so this
  module never defaults it from the acting scope).
  """
  def create_workflow(mount, scope, attrs) do
    attrs = Map.put_new(attrs, :org_id, actor_org_id(scope))

    Mount.resource(mount, Workflow)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
    |> friendly()
  end

  @doc """
  Update an EXISTING workflow through the sanctioned `:update` action (the SAME
  action the pause/resume switch uses). `{:ok, workflow}` or `{:error, message}`.
  """
  def update_workflow(mount, scope, id, attrs) do
    case get_workflow(mount, scope, id) do
      nil ->
        {:error, "Workflow not found."}

      workflow ->
        workflow
        |> Ash.Changeset.for_update(:update, attrs, scope: scope)
        |> Ash.update()
        |> friendly()
    end
  end

  @doc """
  Flip the TENANT pause switch (`status: :active <-> :paused`) through the ordinary
  `:update` action — see moduledoc. `{:ok, workflow}` or `{:error, message}`.
  """
  def toggle_pause(mount, scope, id) do
    case get_workflow(mount, scope, id) do
      nil -> {:error, "Workflow not found."}
      %{status: :paused} = wf -> update_workflow(mount, scope, wf.id, %{status: :active})
      wf -> update_workflow(mount, scope, wf.id, %{status: :paused})
    end
  end

  @doc """
  Add ONE condition to a workflow's bounded `conditions` list, through the SAME
  `:update` action — so `NonPiiPredicates` runs on the write REGARDLESS of whether
  `attribute` came from the eligible-names `<select>` or a forged event payload
  (the red-path proof this module exists to make possible). `{:ok, workflow}` or
  `{:error, message}` (the refusal message on an ineligible attribute).
  """
  def add_condition(mount, scope, id, condition) when is_map(condition) do
    case get_workflow(mount, scope, id) do
      nil -> {:error, "Workflow not found."}
      wf -> update_workflow(mount, scope, id, %{conditions: (wf.conditions || []) ++ [condition]})
    end
  end

  @doc "Remove the condition at `index` from a workflow's `conditions` list."
  def remove_condition(mount, scope, id, index) when is_integer(index) do
    case get_workflow(mount, scope, id) do
      nil -> {:error, "Workflow not found."}
      wf -> update_workflow(mount, scope, id, %{conditions: List.delete_at(wf.conditions || [], index)})
    end
  end

  @doc """
  Add ONE action to a workflow's bounded `actions` list. Same write-time gate as
  `add_condition/4` — an action config interpolating a non-eligible attribute is
  refused (ADR-039 §4.4 gate 2).
  """
  def add_action(mount, scope, id, action) when is_map(action) do
    case get_workflow(mount, scope, id) do
      nil -> {:error, "Workflow not found."}
      wf -> update_workflow(mount, scope, id, %{actions: (wf.actions || []) ++ [action]})
    end
  end

  @doc "Remove the action at `index` from a workflow's `actions` list."
  def remove_action(mount, scope, id, index) when is_integer(index) do
    case get_workflow(mount, scope, id) do
      nil -> {:error, "Workflow not found."}
      wf -> update_workflow(mount, scope, id, %{actions: List.delete_at(wf.actions || [], index)})
    end
  end

  @doc """
  Manually fire a workflow (the builder's "Run now") — `Samen.Automation.trigger_manual/2`
  with EXPLICIT `workflow_module`/`repo` opts derived from `mount` (opts win over host
  config, per `Samen.Automation`'s own contract — see moduledoc). Enqueues the SAME
  `DispatchWorker` pipeline an event/schedule trigger uses, tagged `trigger_kind:
  :manual`. `{:ok, %{enqueued: true, ...}}` or `{:error, reason}` (fails CLOSED —
  `:no_automation_module` — when the host never wired the engine; never a silent
  no-op, per the fail-honest adapter contract).
  """
  def run_now(mount, org_id, %{id: id} = workflow) do
    Samen.Automation.trigger_manual(
      %{
        workflow_id: id,
        org_id: org_id,
        resource_key: workflow.resource_key,
        record_id: nil,
        subject_ref: "samen:workflow:#{id}:manual"
      },
      workflow_module: Mount.resource(mount, Workflow),
      repo: mount.repo
    )
  end

  @doc """
  The condition-eligible LOGICAL attribute names for `resource_key` — delegates to
  `Samen.Automation.NonPiiPredicates.eligible_names/1`, the ONE oracle (ADR-039 §4.4).
  Always a sorted list (never a bare `MapSet`, and never raises): `[]` for a blank/
  unresolvable `resource_key` (the honest "pick a resource_key first" empty state) —
  the SAME default-deny posture the write-time gate has, surfaced here as an empty
  picker rather than a crash.
  """
  @spec eligible_attributes(String.t() | nil) :: [String.t()]
  def eligible_attributes(resource_key) when is_binary(resource_key) and resource_key != "" do
    case NonPiiPredicates.eligible_names(resource_key) do
      {:ok, set} -> set |> MapSet.to_list() |> Enum.sort()
      {:error, _, _, _} -> []
    end
  end

  def eligible_attributes(_), do: []

  @doc """
  The bounded set of known action `kind` strings — delegates to
  `Samen.Automation.Action.kinds/0` (T39's `notify` + T40's remaining seven, read
  LIVE from the registry; the builder never hardcodes a kind list, per the handoff's
  non-goal "does not add to the registry itself").
  """
  @spec action_kinds() :: [String.t()]
  def action_kinds, do: Action.kinds()

  @doc "The acting scope's own actor id (bounded id, never a PII value)."
  def actor_id(%Samen.Scope{actor: %{id: id}}), do: id
  def actor_id(_), do: nil

  @doc "The acting scope's own actor org id."
  def actor_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  def actor_org_id(_), do: nil

  # -- friendly errors -----------------------------------------------------------

  defp friendly({:ok, workflow}), do: {:ok, workflow}
  defp friendly({:error, error}), do: {:error, friendly_error(error)}

  @doc """
  A FRIENDLY, bounded message for a refused workflow write. Surfaces the kernel
  validation's own message verbatim (e.g. `NonPiiPredicates`' refusal names the
  attribute and the reason) — framework/validation copy only, never a field value.
  """
  def friendly_error(error) do
    error
    |> flatten_errors()
    |> Enum.find_value(fn e ->
      case e do
        %{message: msg} when is_binary(msg) and msg != "" -> interpolate(msg, Map.get(e, :vars) || [])
        _ -> nil
      end
    end) || "Could not save this workflow change."
  end

  defp flatten_errors(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten_errors/1)
  defp flatten_errors(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten_errors/1)
  defp flatten_errors(error), do: [error]

  defp interpolate(msg, vars) do
    Enum.reduce(vars, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
