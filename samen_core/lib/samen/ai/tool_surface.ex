defmodule Samen.AI.ToolSurface do
  @moduledoc """
  **The one surface-scoped tool registry** (T183; ADR-043 §7/§9 + ADR-047 §5.1a, PROPOSED).

  Before this module samen had **two hand-rolled tool registries with no shared abstraction**:
  `Samen.Automation.Action.registry/0` (the agent loop's allowlist, ADR-039 §5.2 + ADR-047 §5.1)
  and `Samen.AI.Mcp`'s hardcoded four-name set (`mcp.ex`, ADR-043 §9). Neither could represent a
  **surface** at all, so "this tool belongs to the MCP window, not to the tenant agent loop" was
  not a thing either could say — and a tool from the other registry was merely *absent*
  (`{:error, {:unknown_tool, name}}`), never *refused*.

  ## The four surfaces are a CLOSED set (`surfaces/0`)

    * `:mcp` — the D4 MCP server's external read/propose window (ADR-043 §9).
    * `:operator` — the operator plane. **Owns no tools, by construction.** ADR-047 §7.3 is
      categorical for this plane, and the honest structural expression of "the operator plane
      runs nothing on a tenant's behalf" is an EMPTY registry, not a filtered one.
    * `:tenant` — the ADR-047 agent loop, executing as the run owner on the tenant plane. The
      default `agent_surface/0`.
    * `:ci_eval` — the deterministic, keyless CI eval / red-team lane (ADR-043 §10 / D8,
      `test/ai_eval/`). Read-effect tools only: a `effect: :write` tool invoked from an eval
      would open a REAL E3 approval, which is a side effect a CI lane must not have.

  ## Refusal is NAMED, not absence (the whole point)

      resolve(surface, name)
        {:ok, owner}                                   # on this surface
        {:error, {:tool_off_surface, name, surface}}   # registered — on a DIFFERENT surface
        {:error, {:unknown_tool, name}}                # registered nowhere
        {:error, {:unknown_surface, surface}}          # not one of the four

  `{:tool_off_surface, …}` is the "governed-by-construction" refusal the repo's
  `Samen.Files.ChokepointGuard` precedent sets the bar for. Its `name` is bounded by
  construction — it is only ever emitted for a name this module's OWN registries contain, so no
  arbitrary model- or client-supplied string reaches a log through that tuple.

  ## Membership is declared by the tool, never by a third hardcoded list

  A third list would just be the bug this module removes, one registry later. Instead:

    * the `:mcp` registry is read from `Samen.AI.Mcp.tool_names/0` — the MCP module keeps owning
      its own protocol-native tools (JSON-Schema in, JSON-RPC out), it just no longer decides
      *cross-surface* questions;
    * the `:tenant` / `:ci_eval` / `:operator` registries are derived from each registered
      action's own optional `c:Samen.Automation.Action.tool_surfaces/0` — the same explicit,
      reviewed, per-module opt-in shape as `tool_schema/0` and `effect/0`.

  **`:mcp` is not declarable from an action** (`action_surfaces/0`). MCP tools and governed
  Automation actions have different execution contracts; an abstraction that pretended otherwise
  would let `resolve/2` admit a name `Samen.AI.Mcp` cannot dispatch. The abstraction shared here
  is the *surface / registry / refusal* contract, not the execution contract.

  ## Fail-closed at every edge

    * `surfaces_for/1` separates *did not declare* from *declared wrong*. **Absent** — a
      pre-T183 action that exports no `tool_surfaces/0` — is `[:tenant]`:
      the narrowest lane, and precisely the one lane it already ran on before this module
      existed, so an upgrade widens nothing and every OTHER surface stays opt-in.
      **Malformed** — unloadable, raising, a non-list, or a list naming ONE member outside
      `action_surfaces/0` — is `[]`, invocable nowhere: a partial or typo'd declaration is
      refused whole, never partly honoured (narrowing only). An explicit `[]` is honoured
      literally, also as nowhere.
    * an action must ALSO be an opted-in tool (`tool_schema/0`) to reach any registry, so
      declaring a surface can never turn a non-tool action into a tool.
    * `agent_surface/0` is **host application config only** — never a per-run opt, never a
      caller argument, and never derived from `ctx[:actor]` (T185's rule: a surface is a
      deployment lane, NOT an identity). A misconfigured value resolves to a sentinel that is
      in no registry, so a typo DISABLES every tool rather than widening one.
  """

  alias Samen.Automation.Action

  @surfaces [:mcp, :operator, :tenant, :ci_eval]
  @action_surfaces [:tenant, :ci_eval, :operator]
  # The lane an opted-in action that predates `tool_surfaces/0` already ran on: the ADR-047
  # agent loop, as the run owner, on the tenant plane. NOT a widening — every other surface,
  # `:ci_eval` and `:mcp` included, still requires an explicit declaration.
  @default_surfaces [:tenant]
  @invalid_surface :__invalid_surface__

  @type surface :: :mcp | :operator | :tenant | :ci_eval
  @type owner :: :mcp | module()

  @doc "The CLOSED set of surfaces. Exactly four (ADR-047 §5.1a)."
  @spec surfaces() :: [surface()]
  def surfaces, do: @surfaces

  @doc """
  The surfaces an `Samen.Automation.Action` may declare. `:mcp` is deliberately absent — that
  registry is owned by `Samen.AI.Mcp`, which is the only module able to dispatch it.
  """
  @spec action_surfaces() :: [surface()]
  def action_surfaces, do: @action_surfaces

  @doc "Is `term` one of the four declared surfaces?"
  @spec surface?(term()) :: boolean()
  def surface?(term), do: term in @surfaces

  @doc """
  The surface the ADR-047 agent loop runs on — `:tenant` unless the HOST configures otherwise:

      config :samen_core, Samen.AI.ToolSurface, agent_surface: :ci_eval

  Host config only, identically in `Samen.AI.Agent.run/4` and in the durable worker, so the
  scope cannot vanish across a batch boundary the way a per-run opt can. A configured value
  outside `surfaces/0` returns `:#{@invalid_surface}` — a sentinel in no registry, so every
  tool refuses (fail-closed) instead of falling back to a wider default.
  """
  @spec agent_surface() :: surface() | :__invalid_surface__
  def agent_surface do
    case Application.get_env(:samen_core, __MODULE__, []) do
      config when is_list(config) ->
        case List.keyfind(config, :agent_surface, 0) do
          nil -> :tenant
          {:agent_surface, s} when s in @surfaces -> s
          _ -> @invalid_surface
        end

      _ ->
        @invalid_surface
    end
  end

  @doc """
  The registry a surface OWNS: `%{tool_name => owner}`, where `owner` is `:mcp` for a
  protocol-native MCP tool or the action module for a governed Automation tool. An unknown
  surface owns nothing (`%{}`).
  """
  @spec registry(term()) :: %{optional(String.t()) => owner()}
  def registry(:mcp), do: Map.new(Samen.AI.Mcp.tool_names(), fn name -> {name, :mcp} end)

  def registry(surface) when surface in @action_surfaces do
    Action.registry()
    |> Enum.filter(fn {_kind, mod} ->
      Action.tool_schema_for(mod) != :not_a_tool and surface in surfaces_for(mod)
    end)
    |> Map.new()
  end

  def registry(_other), do: %{}

  @doc "The sorted tool names a surface owns."
  @spec names(term()) :: [String.t()]
  def names(surface), do: surface |> registry() |> Map.keys() |> Enum.sort()

  @doc "Every surface that owns `name` (`[]` when it is registered nowhere)."
  @spec surfaces_of(term()) :: [surface()]
  def surfaces_of(name) when is_binary(name),
    do: Enum.filter(@surfaces, fn s -> Map.has_key?(registry(s), name) end)

  def surfaces_of(_name), do: []

  @doc "Is `name` on `surface`?"
  @spec on_surface?(term(), term()) :: boolean()
  def on_surface?(surface, name) when is_binary(name), do: Map.has_key?(registry(surface), name)
  def on_surface?(_surface, _name), do: false

  @doc """
  Resolve `name` ON `surface` — the ONE gate both the agent loop and the MCP server invoke
  through. A tool registered for another surface is REFUSED BY NAME
  (`{:error, {:tool_off_surface, name, surface}}`), never reported as merely unknown.
  """
  @spec resolve(term(), term()) ::
          {:ok, owner()}
          | {:error,
             {:tool_off_surface, String.t(), surface()}
             | {:unknown_tool, String.t() | nil}
             | {:unknown_surface, atom()}}
  def resolve(surface, name) do
    cond do
      surface not in @surfaces ->
        {:error, {:unknown_surface, bounded_surface(surface)}}

      not is_binary(name) ->
        # Never echo a non-binary caller/model term into an error tuple.
        {:error, {:unknown_tool, nil}}

      true ->
        case Map.fetch(registry(surface), name) do
          {:ok, owner} -> {:ok, owner}
          :error -> off_surface_or_unknown(surface, name)
        end
    end
  end

  defp off_surface_or_unknown(surface, name) do
    case surfaces_of(name) do
      [] -> {:error, {:unknown_tool, name}}
      _owned_elsewhere -> {:error, {:tool_off_surface, name, surface}}
    end
  end

  defp bounded_surface(surface) when is_atom(surface), do: surface
  defp bounded_surface(_surface), do: @invalid_surface

  @doc """
  The surfaces an action module is on. `#{inspect(@default_surfaces)}` when it declares
  nothing (the pre-T183 lane, preserved); `[]` when its declaration is MALFORMED or when it
  cannot be loaded at all — see the moduledoc's fail-closed list.
  """
  @spec surfaces_for(module() | nil) :: [surface()]
  def surfaces_for(mod) when is_atom(mod) and not is_nil(mod) do
    cond do
      not Code.ensure_loaded?(mod) -> []
      function_exported?(mod, :tool_surfaces, 0) -> normalize(mod.tool_surfaces())
      true -> @default_surfaces
    end
  rescue
    _ -> []
  end

  def surfaces_for(_mod), do: []

  defp normalize([]), do: []

  defp normalize(declared) when is_list(declared) do
    if Enum.all?(declared, fn s -> s in @action_surfaces end) do
      declared |> Enum.uniq() |> Enum.sort()
    else
      []
    end
  end

  defp normalize(_declared), do: []
end
