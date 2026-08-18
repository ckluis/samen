defmodule Samen.Automation.Actions.FetchRecord do
  @moduledoc """
  The `fetch_record` READ-effect action (ADR-047 §5.1, batch A3) — a governed
  single-record read, registered in the ONE `Samen.Automation.Action` registry and
  opted in as an agent tool (`tool_schema/0` + `effect/0 :: :read`).

  ## The projection rule (ADR-047 §10's A3-deferred spelling, decided here)

  The result is projected to **catalog-declared, condition-eligible attributes
  only** — the ONE eligibility oracle (`Samen.Automation.NonPiiPredicates.
  eligible_names/1`, ADR-039 §4.4: an attribute is eligible iff it projects through
  `Samen.Cdc.Projection` as a non-token, non-plaintext kind). So:

    * a **vault-routed (🔒) field** is carried on the read record as `%Samen.Masked{}`
      and rendered `••••` by `Samen.AI.Agent.ToolResult.render/2` (present-but-masked
      on the AI plane — masking is load-bearing, ADR-047 §9#7);
    * a **plaintext-PII freeform field** (e.g. an uncleared `title`) is simply NOT in
      the projection — mask-by-OMISSION, the stronger posture;
    * bounded ids / enums / timestamps / numbers / booleans render as values.

  ## The actor's policy envelope is the gate (ADR-047 §5.1 arm 4)

  The read runs `Ash.read(..., scope: ctx.actor)` as the run's OWNER actor — the
  resource's own policies apply (`Samen.Policy.OrgScope` FilterCheck: a foreign
  org's record does not exist for this scope, RP-AG-10), and a refused/absent
  record is an HONEST bounded error (`:record_not_found` / `:not_authorized`),
  recorded on the turn row and fed back to the model — never a silent skip, never
  an `authorize?: false` bypass.

  ## As an agent tool (EG2)

  The tool schema is a COMPILE-TIME CONSTANT (ADR-047 §4.2). Args are untrusted
  model output: `validate/2` is default-deny (`"resource"` + `"id"` only; the id
  must be a UUID; the resource key must be a bounded module string). An
  unresolvable resource is a fail-closed `:unknown_resource` (you cannot verify
  eligibility against a resource you cannot see — the NonPiiPredicates rule).
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Context
  alias Samen.Automation.NonPiiPredicates

  require Ash.Query

  @max_resource_bytes 200

  # ADR-047 §4.2: a compile-time constant — never derived from tenant data.
  @tool_schema %{
    name: "fetch_record",
    description:
      "Fetch one record of this organization by resource and id, projected to " <>
        "catalog-declared, condition-eligible fields. Personal (vault-routed) fields " <>
        "are always masked.",
    params: [
      %{
        name: "resource",
        type: "string",
        required: true,
        description: "the fully-qualified resource module name (as reported by search hits)"
      },
      %{name: "id", type: "string", required: true, description: "the record's UUID"}
    ]
  }

  @impl true
  def kind, do: :fetch_record

  @impl true
  def tool_schema, do: @tool_schema

  @impl true
  def effect, do: :read

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    resource = config["resource"] || config[:resource]
    id = config["id"] || config[:id]

    cond do
      # Default-deny: only the declared arg names may appear (untrusted model output).
      not (config |> Map.keys() |> Enum.all?(&(to_string(&1) in ["resource", "id"]))) ->
        {:error, :invalid_args}

      not is_binary(resource) or String.trim(resource) == "" or
          byte_size(resource) > @max_resource_bytes ->
        {:error, :invalid_resource}

      not match?({:ok, _}, Ecto.UUID.cast(id)) ->
        {:error, :invalid_id}

      true ->
        {:ok, %{"resource" => String.trim(resource), "id" => id}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    resource_key = config["resource"]
    id = config["id"]

    with {:ok, resource, eligible} <- resolve(resource_key),
         {:ok, record} <- read_one(resource, id, eligible, ctx.actor) do
      {:ok,
       %{
         kind: :fetch_record,
         resource: resource_key,
         resource_module: resource,
         records: [record],
         fields: eligible
       }}
    end
  end

  # Resolve the resource + its condition-eligible projection through the ONE oracle
  # (fail-closed: an unresolvable/unclassifiable resource is :unknown_resource).
  defp resolve(resource_key) do
    case NonPiiPredicates.eligible_names(resource_key) do
      {:ok, eligible_names} ->
        resource = resolve_module(resource_key)

        eligible =
          eligible_names
          |> MapSet.to_list()
          |> Enum.map(&existing_atom/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        if resource, do: {:ok, resource, eligible}, else: {:error, :unknown_resource}

      {:error, _where, _attr, _reason} ->
        {:error, :unknown_resource}
    end
  end

  defp resolve_module(resource_key) when is_binary(resource_key) do
    mod = String.to_existing_atom("Elixir." <> String.trim_leading(resource_key, "Elixir."))

    if Code.ensure_loaded?(mod) and function_exported?(mod, :spark_dsl_config, 0),
      do: mod,
      else: nil
  rescue
    ArgumentError -> nil
  end

  # The GOVERNED read: `scope: ctx.actor` — the owner actor's real policy envelope
  # binds (OrgScope FilterCheck ⇒ a foreign org's record does not exist). The
  # selection covers the eligible projection PLUS the resource's vault-routed pii
  # attributes: those read back `%Samen.Masked{}` and the renderer presents them
  # `••••` (present-but-masked on the AI plane — never plaintext, never omitted).
  defp read_one(resource, id, eligible, %Samen.Scope{} = scope) do
    select = Enum.uniq([:id | eligible] ++ pii_names(resource))

    resource
    |> Ash.Query.new()
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected(select)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, [record]} -> {:ok, record}
      {:ok, []} -> {:error, :record_not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :not_authorized}
      {:error, _} -> {:error, :tool_failed}
    end
  rescue
    # An action error never crashes the engine (ADR-039 §5.1) — and never leaks a
    # rich exception term (EG6): degrade to the bounded kind.
    _ -> {:error, :tool_failed}
  end

  defp read_one(_resource, _id, _eligible, _actor), do: {:error, :not_authorized}

  defp pii_names(resource) do
    resource |> Samen.Pii.Info.pii_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(name) when is_atom(name), do: name
end
