defmodule Samen.Automation.Actions.AssignRecordOwner do
  @moduledoc """
  The `assign_record_owner` WRITE-effect action (ADR-047 §5.3, batch A4) — the first
  agent tool with a side effect, and the v1 support-triage write the ADR's driving
  example asks for: *"why is shipment 4471 late **and who should own it?**"* (§1).

  Registered in the ONE `Samen.Automation.Action` registry (never a forked second
  allowlist — the A3 precedent for `search_records`/`fetch_record`, applied to the write
  side) and opted in as an agent tool via `tool_schema/0` + `effect/0 :: :write`.

  ## It does not execute when an agent calls it (ADR-043 §6.2, unamended)

  `effect/0` returning `:write` is the whole point: `Samen.AI.Agent` NEVER invokes
  `run/2` for a write tool from a turn. The turn opens an E3 approval
  (`Samen.AI.Agent.WriteProposal`) and the run parks `:awaiting_approval`. `run/2` is
  reached ONLY from `Samen.AI.Agent.execute_approved/3`, after a DISTINCT human approved,
  and it then runs with the **APPROVER's** actor — so this module can never be a path to
  a mutation carrying the agent's or the AI service principal's authority.

  ## Why a NEW kind rather than opting in `assign_owner`

  ADR-039's `assign_owner` targets the fire-time SUBJECT (`ctx.resource_key` /
  `ctx.record_id`) supplied by a workflow trigger. An agent has no trigger subject: it
  discovers a record through `search_records`/`fetch_record` and names it in the CALL.
  Retrofitting the agent arg shape onto `assign_owner`'s `validate/2` would widen a
  validator the Workflow changeset also uses — a real risk for a cosmetic saving. A3 set
  the precedent by ADDING read actions rather than retrofitting the 8; this follows it.
  `assign_owner` therefore stays `:not_a_tool` and `effect: :write`, like all 8.

  ## Args are untrusted model output (ADR-047 §4.3)

  `validate/2` is DEFAULT-DENY: exactly `"resource"`, `"id"`, `"user_id"` — any other key
  refuses `:invalid_args`; the resource key is a bounded module string; both ids must be
  UUIDs. The attribute written is the fixed `:owner_id` — deliberately NOT an argument,
  so the model cannot choose which column a governed update writes. A resource without a
  public writable `owner_id` is an honest `:no_owner_attribute`, never a silent no-op.

  ## The write is governed, org-scoped, and never elevated

  Both the re-read and the update run through `scope: ctx.actor` — the `%Samen.Scope{}`
  the engine resolved, threaded as `Ash.Scope.ToOpts` exactly as A3's `fetch_record` does
  its `Ash.read/2`. There is no `authorize?: false` anywhere on this path, so
  `Samen.Policy.OrgScope`'s FilterCheck means a foreign org's record does not exist
  (RP-AG-10) and a policy denial surfaces as the bounded `:not_authorized` — never an
  orphaned write.

  `undo/3` is a documented no-op, exactly as `assign_owner`'s is: reversing needs the
  PRIOR owner value, which the engine deliberately never captures (INV-1 over undo
  fidelity — ADR-039 §5.2 #3).
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Actions.Support
  alias Samen.Automation.Context

  require Ash.Query

  @max_resource_bytes 200
  @owner_attribute :owner_id

  # ADR-047 §4.2: a compile-time constant — never derived from tenant data.
  @tool_schema %{
    name: "assign_record_owner",
    description:
      "Propose assigning an owner to one record of this organization. This is a WRITE: " <>
        "it does NOT take effect when you call it — it opens an approval that a person " <>
        "must approve before anything changes.",
    params: [
      %{
        name: "resource",
        type: "string",
        required: true,
        description: "the fully-qualified resource module name (as reported by search hits)"
      },
      %{name: "id", type: "string", required: true, description: "the record's UUID"},
      %{
        name: "user_id",
        type: "string",
        required: true,
        description: "the UUID of the member who should own the record"
      }
    ]
  }

  @impl true
  def kind, do: :assign_record_owner

  @impl true
  def tool_schema, do: @tool_schema

  @impl true
  def effect, do: :write

  # T183 (ADR-047 §5.1a): TENANT PLANE ONLY. Deliberately NOT `:ci_eval` — this tool's
  # admitted call opens a REAL E3 approval (ADR-043 §6.2), which is a side effect the
  # keyless, deterministic eval lane must not be able to cause. Never `:operator` either.
  @impl true
  def tool_surfaces, do: [:tenant]

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    resource = config["resource"] || config[:resource]
    id = config["id"] || config[:id]
    user_id = config["user_id"] || config[:user_id]

    cond do
      # Default-deny: only the declared arg names may appear (untrusted model output).
      not (config |> Map.keys() |> Enum.all?(&(to_string(&1) in ["resource", "id", "user_id"]))) ->
        {:error, :invalid_args}

      not is_binary(resource) or String.trim(resource) == "" or
          byte_size(resource) > @max_resource_bytes ->
        {:error, :invalid_resource}

      not match?({:ok, _}, Ecto.UUID.cast(id)) ->
        {:error, :invalid_id}

      not match?({:ok, _}, Ecto.UUID.cast(user_id)) ->
        {:error, :invalid_user_id}

      true ->
        {:ok, %{"resource" => String.trim(resource), "id" => id, "user_id" => user_id}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    with {:ok, resource} <- resolve(config["resource"]),
         :ok <- owner_attribute?(resource),
         {:ok, record} <- fetch(resource, config["id"], ctx.actor),
         {:ok, updated} <- assign(record, config["user_id"], ctx.actor) do
      {:ok,
       %{
         kind: :assign_record_owner,
         resource: config["resource"],
         record_id: to_string(updated.id),
         attribute: to_string(@owner_attribute),
         assigned: true
       }}
    end
  end

  def run(_config, _ctx), do: {:error, :invalid_config}

  @impl true
  def undo(_config, _meta, _ctx), do: :ok

  # --- internals ------------------------------------------------------------------------

  defp resolve(resource_key) do
    case Support.resolve_resource(resource_key) do
      {:ok, mod} ->
        if function_exported?(mod, :spark_dsl_config, 0), do: {:ok, mod}, else: {:error, :unknown_resource}

      :error ->
        {:error, :unknown_resource}
    end
  end

  # Fail-closed: the fixed target column must genuinely exist and be writable. A resource
  # without it is an honest bounded error the model sees — never a silent no-op update.
  defp owner_attribute?(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.find(&(&1.name == @owner_attribute))
    |> case do
      %{writable?: true} -> :ok
      _ -> {:error, :no_owner_attribute}
    end
  rescue
    _ -> {:error, :no_owner_attribute}
  end

  # The governed read (arm 4): a foreign org's record does not exist for this scope.
  defp fetch(resource, id, %Samen.Scope{} = scope) do
    resource
    |> Ash.Query.new()
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, [record]} -> {:ok, record}
      {:ok, []} -> {:error, :record_not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :not_authorized}
      {:error, _} -> {:error, :tool_failed}
    end
  rescue
    _ -> {:error, :tool_failed}
  end

  defp fetch(_resource, _id, _actor), do: {:error, :not_authorized}

  # The governed WRITE — `scope:`, never `authorize?: false`. This is the ONLY mutating
  # call in the module, and it is reachable only from `Samen.AI.Agent.execute_approved/3`
  # with the APPROVER's scope.
  defp assign(record, user_id, %Samen.Scope{} = scope) do
    record
    |> Ash.Changeset.for_update(:update, %{@owner_attribute => user_id}, scope: scope)
    |> Ash.update(scope: scope)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :not_authorized}
      {:error, _} -> {:error, :write_failed}
    end
  rescue
    _ -> {:error, :write_failed}
  end

  # (No non-Scope clause: `fetch/3` above already refuses a non-`%Samen.Scope{}` actor,
  # so this function is unreachable without one — Elixir's own inference proves it.)
end
