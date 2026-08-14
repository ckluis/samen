defmodule Samen.AI.Agent.Tools do
  @moduledoc """
  The agent tool surface resolver (ADR-047 §5.1, batch A3) — the FOUR-WAY NARROWING
  INTERSECTION, the only path from an agent definition to a callable tool:

      callable_tools(agent, actor) =
            Samen.Automation.Action.registry()          # 1. the governed allowlist (ADR-039)
          ∩ {a | a.tool_schema() != :not_a_tool}        # 2. explicit per-action opt-in, default OFF
          ∩ agent.definition.tools                      # 3. the agent's own declared list
          ∩ {a | authorized?(a, actor)}                 # 4. the run actor's real policy envelope

  Arms 1–3 are resolved STATICALLY at run start (`resolve_definition/1` — a definition
  declaring an unregistered or non-opted-in kind refuses `{:error, :invalid_tools}`
  before anything persists) and RE-CHECKED per call (`resolve_call/2` — the model's
  chosen kind must be a member of the run's resolved set; anything else is an honest
  `:tool_refused`, recorded on the turn row and fed back bounded, never silently
  skipped and never executed). Arm 4 binds at EXECUTION: every tool runs through its
  governed action AS the run's owner actor (`Ash` reads under `scope: ctx.actor` —
  `Samen.Policy.OrgScope` FilterCheck and the resource's own policies apply), so a
  policy-refused call surfaces as a bounded honest error (`:record_not_found` /
  `:not_authorized`), also recorded — the chokepoint never elevates, substitutes, or
  synthesizes an actor (INV-2).

  ## A3 boundary (ADR-047 §8)

  Only `effect: :read` tools execute inline. A definition declaring an opted-in
  `effect: :write` tool refuses `{:error, :tools_not_supported}` until batch A4 ships
  the propose-then-approve seam (`Samen.Approvals.Gate`) — fail-honest, never a write
  executed without an approval path and never a declared tool silently dropped.

  ## The static-def membership set (ADR-047 §4.2)

  `static_defs/0` / `static_def?/1` enumerate the byte-exact `tool_schema/0` constants
  of every opted-in registry action — the membership set `Samen.AI.Chokepoint`'s
  `scrub_tools/1` refuses against, so a runtime-composed tool definition can never
  egress even if some caller assembles one.
  """

  alias Samen.Automation.Action

  @type resolved :: %{kind: String.t(), module: module(), schema: map(), effect: :read}

  @doc """
  Resolve an agent definition's declared `tools:` list through intersection arms 1–3
  (registry ∩ opt-in ∩ declared), refusing fail-closed BEFORE any run persists:

    * `{:ok, resolved}` — every declared kind is a registered, opted-in READ tool;
    * `{:error, :invalid_tools}` — a declared kind is unregistered (arm 1) or not
      opted in (arm 2): the definition is misconfigured, refused honestly;
    * `{:error, :tools_not_supported}` — a declared tool is `effect: :write`
      (the A3 boundary; A4 ships the approval seam).
  """
  @spec resolve_definition(%{required(:tools) => [String.t()]}) ::
          {:ok, [resolved()]} | {:error, :invalid_tools | :tools_not_supported}
  def resolve_definition(%{tools: []}), do: {:ok, []}

  def resolve_definition(%{tools: kinds}) when is_list(kinds) do
    kinds
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn kind, {:ok, acc} ->
      case resolve_kind(kind) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def resolve_definition(_definition), do: {:error, :invalid_tools}

  defp resolve_kind(kind) when is_binary(kind) do
    with mod when not is_nil(mod) <- Action.module_for(kind),
         schema when is_map(schema) <- Action.tool_schema_for(mod) do
      case Action.effect_for(mod) do
        :read -> {:ok, %{kind: kind, module: mod, schema: schema, effect: :read}}
        :write -> {:error, :tools_not_supported}
      end
    else
      _ -> {:error, :invalid_tools}
    end
  end

  defp resolve_kind(_kind), do: {:error, :invalid_tools}

  @doc "The EG2 tool DEFINITIONS of a resolved set — what rides `%MaskedPayload{}.tools`."
  @spec defs([resolved()]) :: [map()]
  def defs(resolved) when is_list(resolved), do: Enum.map(resolved, & &1.schema)

  @doc """
  Resolve ONE model-chosen tool call against the run's RESOLVED set (the per-call
  re-check of intersection arms 1–3; sabotage 249's target). The model's kind is
  untrusted output: membership in `resolved` — never a direct registry lookup — is
  what admits it. Anything else is `{:error, :tool_refused}` (recorded honestly).
  """
  @spec resolve_call([resolved()], term()) :: {:ok, resolved()} | {:error, :tool_refused}
  def resolve_call(resolved, kind) when is_list(resolved) and is_binary(kind) do
    case Enum.find(resolved, fn entry -> entry.kind == kind end) do
      %{effect: :read} = entry -> {:ok, entry}
      _ -> {:error, :tool_refused}
    end
  end

  def resolve_call(_resolved, _kind), do: {:error, :tool_refused}

  @doc """
  Every opted-in registry action's byte-exact static `tool_schema/0` constant — the
  chokepoint's tool-def membership set (ADR-047 §4.2).
  """
  @spec static_defs() :: [map()]
  def static_defs do
    Action.registry()
    |> Map.values()
    |> Enum.map(&Action.tool_schema_for/1)
    |> Enum.reject(&(&1 == :not_a_tool))
  end

  @doc "Is `def` byte-identical to a registered opted-in action's static schema?"
  @spec static_def?(term()) :: boolean()
  def static_def?(def), do: def in static_defs()

  @doc "Is `kind` a registered Automation.Action kind at all? (bounded persist gate)"
  @spec registry_kind?(term()) :: boolean()
  def registry_kind?(kind) when is_binary(kind), do: Action.module_for(kind) != nil
  def registry_kind?(_), do: false
end
