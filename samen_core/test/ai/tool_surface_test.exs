defmodule T183Probes do
  @moduledoc """
  Probe action modules for the fail-closed `tool_surfaces/0` reads. Each is a real
  `Samen.Automation.Action` shape (kind + tool_schema + effect) so the ONLY variable under test
  is its surface declaration.
  """

  defmodule Base do
    @moduledoc false
    defmacro __using__(_) do
      quote do
        @behaviour Samen.Automation.Action
        @impl true
        def kind, do: :t183_probe
        @impl true
        def validate(config, _resource_key), do: {:ok, config}
        @impl true
        def run(_config, _ctx), do: {:ok, %{}}
        @impl true
        def tool_schema, do: %{name: "t183_probe", description: "probe", params: []}
        @impl true
        def effect, do: :read
      end
    end
  end

  defmodule Declared do
    @moduledoc "Positive control: a well-formed declaration."
    use Base
    @impl true
    def tool_surfaces, do: [:tenant]
  end

  defmodule Undeclared do
    @moduledoc "Exports NO tool_surfaces/0 — the fail-closed default."
    use Base
  end

  defmodule Bogus do
    @moduledoc "Names a surface that does not exist — the whole declaration is refused."
    use Base
    @impl true
    def tool_surfaces, do: [:tenant, :not_a_real_surface]
  end

  defmodule ClaimsMcp do
    @moduledoc "Tries to claim the MCP registry, which no action may own."
    use Base
    @impl true
    def tool_surfaces, do: [:mcp]
  end

  defmodule NotAList do
    @moduledoc "Returns a non-list."
    use Base
    @impl true
    def tool_surfaces, do: :tenant
  end

  defmodule Raiser do
    @moduledoc "Raises from the callback."
    use Base
    @impl true
    def tool_surfaces, do: raise("boom")
  end

  defmodule EmptyList do
    @moduledoc "Declares the empty list — on no surface, honoured literally."
    use Base
    @impl true
    def tool_surfaces, do: []
  end
end

defmodule Samen.AI.ToolSurfaceTest do
  @moduledoc """
  RP-T183 — **surface-scoped tool registries** (ADR-043 §7/§9; ADR-047 §5.1a, PROPOSED).

  The property under test is the one the item exists for: a tool registered for ONE surface is
  **REFUSED — by name — when invoked on another**, not merely absent from that surface's list.
  Before T183 samen had two hand-rolled registries (`Samen.Automation.Action.registry/0` and
  `Samen.AI.Mcp`'s hardcoded four) with no shared abstraction and no way to express a surface at
  all; the only cross-surface answer either could give was `{:unknown_tool, name}`.

  Every red below pairs with a positive control (anti-tautology, per `CLAUDE.md`): the same call
  on the surface that DOES own the tool must succeed, and a name registered nowhere must still
  come back `{:unknown_tool, …}` — so the refusal is discriminating rather than blanket.
  """

  use ExUnit.Case, async: false

  alias Samen.AI.Agent
  alias Samen.AI.Agent.Tools
  alias Samen.AI.Mcp
  alias Samen.AI.ToolSurface
  alias Samen.Automation.Action

  @mcp_tools ~w(action_proposals browse drafts search)
  @tenant_tools ~w(assign_record_owner fetch_record search_records)
  @eval_tools ~w(fetch_record search_records)

  setup do
    on_exit(fn ->
      Application.delete_env(:samen_core, ToolSurface)
      Application.delete_env(:samen_core, Action)
      Tools.refresh()
    end)

    :ok
  end

  describe "the closed set of surfaces" do
    test "there are EXACTLY four surfaces, and `:mcp` is not one an action may declare" do
      assert ToolSurface.surfaces() == [:mcp, :operator, :tenant, :ci_eval]
      assert ToolSurface.action_surfaces() == [:tenant, :ci_eval, :operator]
      refute :mcp in ToolSurface.action_surfaces()

      for s <- ToolSurface.surfaces(), do: assert(ToolSurface.surface?(s))
      refute ToolSurface.surface?(:fifth_surface)
    end

    test "each surface owns its OWN registry, and the operator plane owns nothing" do
      assert ToolSurface.names(:mcp) == @mcp_tools
      assert ToolSurface.names(:mcp) == Enum.sort(Mcp.tool_names())
      assert ToolSurface.names(:tenant) == @tenant_tools
      assert ToolSurface.names(:ci_eval) == @eval_tools
      # ADR-047 §7.3 is categorical for the operator plane: no tool runs there, by construction.
      assert ToolSurface.names(:operator) == []
      # ...and an unknown surface owns nothing either (fail-closed, never a wider default).
      assert ToolSurface.names(:no_such_surface) == %{} |> Map.keys()
    end
  end

  describe "REFUSED, not merely absent — the T183 done-criterion" do
    test "RED (MCP surface): a TENANT tool invoked on the MCP server is refused BY NAME, never reported as unknown" do
      # The exact call an external MCP client can make. Pre-T183 this was
      # {:error, {:unknown_tool, "search_records"}} — indistinguishable from a typo.
      for kind <- @tenant_tools do
        assert Mcp.call_tool(nil, kind, %{}, []) == {:error, {:tool_off_surface, kind, :mcp}}
        assert ToolSurface.resolve(:mcp, kind) == {:error, {:tool_off_surface, kind, :mcp}}
      end

      # POSITIVE CONTROL 1 — the refusal DISCRIMINATES: a name registered on no surface at all
      # is still the honest {:unknown_tool, …}, unchanged from before T183.
      assert Mcp.call_tool(nil, "drop_all_tables", %{}, []) ==
               {:error, {:unknown_tool, "drop_all_tables"}}

      # POSITIVE CONTROL 2 — the gate is not blanket-refusing: an MCP-owned tool passes the
      # surface gate and reaches its OWN fail-honest error (`:no_org` from the nil scope),
      # which is only reachable from inside the tool body.
      assert Mcp.call_tool(nil, "search", %{}, []) == {:error, :no_org}
      assert ToolSurface.resolve(:mcp, "browse") == {:ok, :mcp}
      assert length(Mcp.tools()) == 4
    end

    test "RED (tenant plane): an agent declaring an MCP tool is refused `:tool_off_surface`, not `:invalid_tools`" do
      for kind <- @mcp_tools do
        assert Tools.resolve_definition(%{tools: [kind]}, :tenant) == {:error, :tool_off_surface}
        assert ToolSurface.resolve(:tenant, kind) == {:error, {:tool_off_surface, kind, :tenant}}
      end

      # POSITIVE CONTROL 1 — arms 1 and 2 are UNCHANGED: an unregistered kind, and a registered
      # kind that never opted in (`notify` exports no tool_schema/0), are both still
      # :invalid_tools. The new refusal did not swallow the old ones.
      assert Tools.resolve_definition(%{tools: ["no_such_tool"]}, :tenant) ==
               {:error, :invalid_tools}

      assert Tools.resolve_definition(%{tools: ["notify"]}, :tenant) == {:error, :invalid_tools}

      # POSITIVE CONTROL 2 — the tools that DO belong to this surface still resolve.
      assert {:ok, resolved} =
               Tools.resolve_definition(%{tools: @tenant_tools}, :tenant)

      assert Enum.map(resolved, & &1.kind) == @tenant_tools
    end

    test "RED (CI eval lane): the WRITE tool is off-surface in the eval lane, while its read siblings are on it" do
      # A write tool admitted in the eval lane would open a REAL E3 approval — a side effect
      # the keyless deterministic lane must be structurally incapable of causing.
      assert Tools.resolve_definition(%{tools: ["assign_record_owner"]}, :ci_eval) ==
               {:error, :tool_off_surface}

      assert ToolSurface.resolve(:ci_eval, "assign_record_owner") ==
               {:error, {:tool_off_surface, "assign_record_owner", :ci_eval}}

      # POSITIVE CONTROL 1 — the same tool on the surface that OWNS it resolves, still :write.
      assert {:ok, [%{kind: "assign_record_owner", effect: :write}]} =
               Tools.resolve_definition(%{tools: ["assign_record_owner"]}, :tenant)

      # POSITIVE CONTROL 2 — the eval lane is not empty: its read tools resolve.
      assert {:ok, [%{effect: :read}, %{effect: :read}]} =
               Tools.resolve_definition(%{tools: @eval_tools}, :ci_eval)
    end

    test "RED (operator plane): every shipped tool, from either registry, is refused by name there" do
      names = @mcp_tools ++ @tenant_tools
      # Non-vacuity: this loop must actually check something.
      assert length(names) == 7

      for name <- names do
        assert ToolSurface.resolve(:operator, name) ==
                 {:error, {:tool_off_surface, name, :operator}}

        refute ToolSurface.on_surface?(:operator, name)
        assert ToolSurface.surfaces_of(name) != []
      end

      # POSITIVE CONTROL — a name registered nowhere is unknown, not off-surface.
      assert ToolSurface.resolve(:operator, "drop_all_tables") ==
               {:error, {:unknown_tool, "drop_all_tables"}}

      assert ToolSurface.surfaces_of("drop_all_tables") == []
    end

    test "RED (per call, model-provoked): an off-surface kind from the model is `:tool_off_surface`, an undeclared on-surface kind is still `:tool_refused`" do
      assert {:ok, resolved} = Tools.resolve_definition(%{tools: ["fetch_record"]}, :tenant)

      # The model emits an MCP tool name mid-run. Named refusal, not "no such tool".
      assert Tools.resolve_call(resolved, "browse") == {:error, :tool_off_surface}

      # POSITIVE CONTROL 1 — arm 3 is UNCHANGED (sabotage 249's property): a registered,
      # opted-in, ON-SURFACE tool the agent did not declare is still plain :tool_refused.
      assert Tools.resolve_call(resolved, "search_records") == {:error, :tool_refused}
      # POSITIVE CONTROL 2 — and a name from nowhere is also still :tool_refused.
      assert Tools.resolve_call(resolved, "drop_all_tables") == {:error, :tool_refused}
      # POSITIVE CONTROL 3 — the declared tool still resolves.
      assert {:ok, %{kind: "fetch_record"}} = Tools.resolve_call(resolved, "fetch_record")
    end

    test "the refusal is RECORDED honestly: `:tool_off_surface` is a bounded @error_kinds member, never the silent `:unknown`" do
      assert Agent.safe_error_kind(:tool_off_surface) == :tool_off_surface
      # Non-vacuity: the degrade path this asserts against is real.
      assert Agent.safe_error_kind(:not_an_error_kind) == :unknown
    end
  end

  describe "fail-closed by construction" do
    test "a MALFORMED surface declaration is refused WHOLE — raising, non-list, bogus member, `:mcp`, or unloadable all land on NO surface" do
      alias T183Probes.{Bogus, ClaimsMcp, Declared, EmptyList, NotAList, Raiser, Undeclared}

      # POSITIVE CONTROL 1 — a well-formed declaration is honoured...
      assert ToolSurface.surfaces_for(Declared) == [:tenant]
      # ...and an action that declares NOTHING keeps the one lane it already ran on. This is
      # the pre-T183 behaviour preserved, not a widening: `:ci_eval` and `:mcp` are still off.
      assert ToolSurface.surfaces_for(Undeclared) == [:tenant]
      refute :ci_eval in ToolSurface.surfaces_for(Undeclared)

      for mod <- [Bogus, ClaimsMcp, NotAList, Raiser, EmptyList] do
        assert ToolSurface.surfaces_for(mod) == [], "expected #{inspect(mod)} on no surface"
      end

      # `Bogus` is the narrowing-only proof: it declared a VALID surface alongside an invalid
      # one and gets neither — a partial declaration is never partly honoured.
      assert :tenant in Bogus.tool_surfaces()
      assert ToolSurface.surfaces_for(Bogus) == []

      assert ToolSurface.surfaces_for(nil) == []
      assert ToolSurface.surfaces_for("not a module") == []
      assert ToolSurface.surfaces_for(:no_such_module_at_all) == []
    end

    test "a HOST-registered tool reaches ONE surface by default and is refused by name on the other three" do
      Application.put_env(:samen_core, Action, extra: %{"t183_host" => T183Probes.Undeclared})
      Tools.refresh()

      # It IS in the governed registry and it IS an opted-in tool (arms 1 + 2 pass)...
      assert Action.module_for("t183_host") == T183Probes.Undeclared
      assert "t183_host" in Action.tool_kinds()

      # ...and it lands on the tenant lane ONLY — never the eval lane, never MCP, never the
      # operator plane — each of which refuses it BY NAME rather than reporting it unknown.
      assert ToolSurface.surfaces_of("t183_host") == [:tenant]

      assert {:ok, [%{kind: "t183_host", effect: :read}]} =
               Tools.resolve_definition(%{tools: ["t183_host"]}, :tenant)

      for s <- [:mcp, :ci_eval, :operator] do
        refute ToolSurface.on_surface?(s, "t183_host")

        assert ToolSurface.resolve(s, "t183_host") ==
                 {:error, {:tool_off_surface, "t183_host", s}}
      end

      assert Mcp.call_tool(nil, "t183_host", %{}, []) ==
               {:error, {:tool_off_surface, "t183_host", :mcp}}

      assert Tools.resolve_definition(%{tools: ["t183_host"]}, :ci_eval) ==
               {:error, :tool_off_surface}

      # POSITIVE CONTROL — a MALFORMED declaration on the same host slot removes it from every
      # surface, including the default one: declaring wrong is stricter than not declaring.
      Application.put_env(:samen_core, Action, extra: %{"t183_host" => T183Probes.Bogus})
      Tools.refresh()

      assert ToolSurface.surfaces_of("t183_host") == []

      assert Tools.resolve_definition(%{tools: ["t183_host"]}, :tenant) ==
               {:error, :invalid_tools}
    end

    test "`agent_surface/0` is HOST CONFIG ONLY, and a misconfigured surface DISABLES every tool instead of widening one" do
      # Default, unconfigured.
      assert ToolSurface.agent_surface() == :tenant

      assert {:ok, [%{kind: "fetch_record"}]} =
               Tools.resolve_definition(%{tools: ["fetch_record"]})

      # The host moves the loop onto the eval lane: the write tool becomes unreachable through
      # the ARITY-1 head the whole loop actually calls (run/4 and the durable worker alike).
      Application.put_env(:samen_core, ToolSurface, agent_surface: :ci_eval)
      assert ToolSurface.agent_surface() == :ci_eval

      assert Tools.resolve_definition(%{tools: ["assign_record_owner"]}) ==
               {:error, :tool_off_surface}

      assert {:ok, [%{kind: "fetch_record"}]} =
               Tools.resolve_definition(%{tools: ["fetch_record"]})

      # A TYPO must not fall back to a wider surface — it must close everything.
      Application.put_env(:samen_core, ToolSurface, agent_surface: :tennant)
      assert ToolSurface.agent_surface() == :__invalid_surface__
      assert ToolSurface.names(:__invalid_surface__) == []

      for kind <- @tenant_tools do
        assert Tools.resolve_definition(%{tools: [kind]}) == {:error, :tool_off_surface}
      end
    end
  end
end
