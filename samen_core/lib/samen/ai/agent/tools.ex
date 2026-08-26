defmodule Samen.AI.Agent.Tools do
  @moduledoc """
  The agent tool surface resolver (ADR-047 §5.1, batch A3; §5.1a at T183) — the FIVE-WAY
  NARROWING INTERSECTION, the only path from an agent definition to a callable tool:

      callable_tools(agent, actor) =
            Samen.Automation.Action.registry()          # 1. the governed allowlist (ADR-039)
          ∩ {a | a.tool_schema() != :not_a_tool}        # 2. explicit per-action opt-in, default OFF
          ∩ {a | agent_surface() in a.tool_surfaces()}  # 5. the SURFACE scope (T183), default OFF
          ∩ agent.definition.tools                      # 3. the agent's own declared list
          ∩ {a | authorized?(a, actor)}                 # 4. the run actor's real policy envelope

  Arms 1, 2 and 5 are no longer read here one at a time: they ARE membership in
  `Samen.AI.ToolSurface.registry/1` for the run's surface, which is the single abstraction both
  this path and `Samen.AI.Mcp` now resolve through (T183). A name registered for a DIFFERENT
  surface is refused BY NAME — `{:error, :tool_off_surface}`, a bounded `@error_kinds` member —
  rather than being reported as unregistered, so cross-surface invocation fails honestly instead
  of looking like a typo. The surface itself is host application config
  (`Samen.AI.ToolSurface.agent_surface/0`), never a caller opt and never an identity parameter.

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

  ## The effect classes (ADR-047 §5.3; A3 → A4)

  The intersection narrows IDENTICALLY for both effect classes — a write tool still has
  to pass registry ∩ opt-in ∩ declared ∩ actor-policy, and nothing here widens. What the
  `effect` field decides is what the LOOP does with an admitted call:

    * `effect: :read` — executes inline in the turn (A3);
    * `effect: :write` — **never executes here**. `Samen.AI.Agent` routes it to
      `Samen.AI.Agent.WriteProposal`, which opens an E3 approval and parks the run
      `:awaiting_approval`; a DISTINCT human's approve is the only thing that can execute
      it, and it then executes with the APPROVER's actor (ADR-043 §6.2, unamended:
      "AI writes do not exist"). A3's interim `{:error, :tools_not_supported}` refusal is
      therefore gone from `resolve_definition/1` — replaced by a real door, not a wider
      one. `effect/0` still DEFAULTS to `:write` (fail-closed): an action that forgets to
      declare is approval-gated, never inline-executed.

  ## The static-def membership set (ADR-047 §4.2)

  `static_defs/0` / `static_def?/1` enumerate the byte-exact `tool_schema/0` constants
  of every opted-in registry action — the membership set `Samen.AI.Chokepoint`'s
  `scrub_tools/1` refuses against, so a runtime-composed tool definition can never
  egress even if some caller assembles one.
  """

  alias Samen.AI.ToolSurface
  alias Samen.Automation.Action

  @static_defs_key {__MODULE__, :static_defs}

  @type resolved :: %{kind: String.t(), module: module(), schema: map(), effect: :read | :write}

  @doc """
  Resolve an agent definition's declared `tools:` list through intersection arms 1–3
  (registry ∩ opt-in ∩ declared), refusing fail-closed BEFORE any run persists:

    * `{:ok, resolved}` — every declared kind is a registered, opted-in tool, each
      entry carrying its declared `effect` (`:read` executes inline; `:write` proposes);
    * `{:error, :invalid_tools}` — a declared kind is unregistered (arm 1) or not
      opted in (arm 2): the definition is misconfigured, refused honestly.
  """
  @spec resolve_definition(%{required(:tools) => [String.t()]}) ::
          {:ok, [resolved()]} | {:error, :invalid_tools | :tool_off_surface}
  def resolve_definition(definition),
    do: resolve_definition(definition, ToolSurface.agent_surface())

  @doc """
  `resolve_definition/1` against an EXPLICIT surface (T183). The arity-1 head is preserved and
  simply supplies `Samen.AI.ToolSurface.agent_surface/0`, so no existing call site changed.
  """
  @spec resolve_definition(%{required(:tools) => [String.t()]}, term()) ::
          {:ok, [resolved()]} | {:error, :invalid_tools | :tool_off_surface}
  def resolve_definition(%{tools: []}, _surface), do: {:ok, []}

  def resolve_definition(%{tools: kinds}, surface) when is_list(kinds) do
    kinds
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn kind, {:ok, acc} ->
      case resolve_kind(kind, surface) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def resolve_definition(_definition, _surface), do: {:error, :invalid_tools}

  # Arms 1 + 2 + 5 in ONE membership question (T183): `ToolSurface.registry/1` IS
  # registry ∩ opt-in ∩ surface. A name owned by another surface is refused BY NAME; a name
  # owned by no surface at all — unregistered, or registered but not opted in — is the
  # pre-T183 `:invalid_tools`, unchanged. A misconfigured `agent_surface/0` owns no registry,
  # so every tool is off it: fail-closed, never a fallback to a wider surface.
  defp resolve_kind(kind, surface) when is_binary(kind) do
    case ToolSurface.resolve(surface, kind) do
      {:ok, mod} when is_atom(mod) and mod != :mcp -> resolved_entry(kind, mod)
      {:error, {:tool_off_surface, _name, _surface}} -> {:error, :tool_off_surface}
      {:error, {:unknown_surface, _surface}} -> {:error, :tool_off_surface}
      _ -> {:error, :invalid_tools}
    end
  end

  defp resolve_kind(_kind, _surface), do: {:error, :invalid_tools}

  defp resolved_entry(kind, mod) do
    case Action.tool_schema_for(mod) do
      :not_a_tool ->
        {:error, :invalid_tools}

      schema ->
        # `effect_for/1` is fail-closed (:write unless the module returns the literal
        # :read), so an unloadable/raising/undeclared action lands on the approval path,
        # never the inline one.
        {:ok, %{kind: kind, module: mod, schema: schema, effect: Action.effect_for(mod)}}
    end
  end

  @doc "The EG2 tool DEFINITIONS of a resolved set — what rides `%MaskedPayload{}.tools`."
  @spec defs([resolved()]) :: [map()]
  def defs(resolved) when is_list(resolved), do: Enum.map(resolved, & &1.schema)

  @doc """
  Resolve ONE model-chosen tool call against the run's RESOLVED set (the per-call
  re-check of intersection arms 1–3; sabotage 249's target). The model's kind is
  untrusted output: membership in `resolved` — never a direct registry lookup — is
  what admits it. Anything else is `{:error, :tool_refused}` (recorded honestly).

  Admitting an `effect: :write` entry here is NOT permission to execute it: the caller
  (`Samen.AI.Agent`) branches on `entry.effect`, and the write branch only ever opens an
  approval. This function is also the re-check the APPROVED execution runs before firing
  (`Samen.AI.Agent.execute_approved/3`), so a tool de-declared or de-opted-in between
  proposal and approval refuses instead of executing on a stale admission.
  """
  @spec resolve_call([resolved()], term()) ::
          {:ok, resolved()} | {:error, :tool_refused | :tool_off_surface}
  def resolve_call(resolved, kind) when is_list(resolved) and is_binary(kind) do
    case Enum.find(resolved, fn entry -> entry.kind == kind end) do
      %{effect: effect} = entry when effect in [:read, :write] -> {:ok, entry}
      _ -> {:error, refusal_kind(kind)}
    end
  end

  def resolve_call(_resolved, _kind), do: {:error, :tool_refused}

  # T183: distinguish the two refusals the model can provoke. A kind the agent simply did not
  # DECLARE (arm 3) is `:tool_refused`, exactly as before. A kind belonging to another SURFACE
  # — an MCP tool name arriving in a tenant agent turn — is `:tool_off_surface`: still a
  # refusal, but a named one, so the turn row says why instead of implying "no such tool".
  defp refusal_kind(kind) do
    case ToolSurface.resolve(ToolSurface.agent_surface(), kind) do
      {:error, {:tool_off_surface, _name, _surface}} -> :tool_off_surface
      _ -> :tool_refused
    end
  end

  @doc """
  Every opted-in registry action's byte-exact static `tool_schema/0` constant — the
  chokepoint's tool-def membership set (ADR-047 §4.2).

  ## Memoised, with BYTE-EXACT semantics unchanged (A4 fold, A3 verifier residual)

  `Samen.AI.Chokepoint.scrub_tools/1` calls `static_def?/1` for EVERY tool def on EVERY
  seal, and this function walked the whole registry calling `Action.tool_schema_for/1`
  (a `Code.ensure_loaded?/1` per module) each time — per-turn work on the provider hot
  path. The result is now cached in `:persistent_term` **keyed on the registry map
  itself**, which is what keeps the semantics byte-identical rather than merely
  equivalent:

    * a `tool_schema/0` return is, by the §4.2 static-schema rule, a compile-time
      constant of its module — so for a given registry the computed list is a pure
      function of that registry, and the cache returns the SAME term (`===`), not a
      re-derived look-alike;
    * the cache key is the full `Action.registry()` map, so the host-extra seam
      (`config :samen_core, Samen.Automation.Action, extra: …`) invalidates it
      automatically — registering, changing, or removing a host action recomputes on the
      very next call. There is no `reset/0` to forget to call, and no window in which the
      membership set disagrees with the registry;
    * a module recompiled in place (dev/test reload) that changes its schema without
      changing the registry map is the ONE case the cache would hold stale — which is
      why `refresh/0` exists and why nothing in `lib/` depends on it.

  Membership itself (`static_def?/1`) is deliberately left as `def in static_defs()`:
  the scrub chokepoint depends on byte-exact list membership (`Enum.member?/2`'s `===`),
  and swapping in a set would change the comparison semantics for the sake of a
  micro-optimisation on an already-short list.
  """
  @spec static_defs() :: [map()]
  def static_defs do
    registry = Action.registry()

    case :persistent_term.get(@static_defs_key, :miss) do
      {^registry, defs} ->
        defs

      _ ->
        defs = compute_static_defs(registry)
        :persistent_term.put(@static_defs_key, {registry, defs})
        defs
    end
  end

  @doc """
  Drop the memoised static-def set (the next `static_defs/0` recomputes). Only needed
  when a tool action module is RECOMPILED IN PLACE without the registry map changing —
  never on the shipped path, where the registry-keyed cache invalidates itself.
  """
  @spec refresh() :: :ok
  def refresh do
    _ = :persistent_term.erase(@static_defs_key)
    :ok
  end

  defp compute_static_defs(registry) do
    registry
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
