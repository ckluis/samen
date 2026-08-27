# Fixtures — opted-in agent-tool modules with a modeled tool_surfaces/0 declaration.
# Registered through the sanctioned host-extra seam only for the duration of the tests that
# need them (house discipline, matching tool_actor_identity_verifier_test.exs).
defmodule CleanSurfaceTool do
  @moduledoc false
  def kind, do: :clean_surface_probe
  def tool_schema, do: %{name: "clean_surface_probe", params: []}
  def effect, do: :read
  def tool_surfaces, do: [:tenant]
end

defmodule MalformedSurfaceTool do
  @moduledoc false
  # Names a surface that does not exist -> Samen.AI.ToolSurface.surfaces_for/1 normalizes
  # this WHOLE declaration to [] (fail-closed) -- silently uncallable everywhere.
  def kind, do: :malformed_surface_probe
  def tool_schema, do: %{name: "malformed_surface_probe", params: []}
  def effect, do: :read
  def tool_surfaces, do: [:not_a_real_surface]
end

defmodule EmptyDeclSurfaceTool do
  @moduledoc false
  # An explicit [] is honoured literally -- also on no surface, also a violation.
  def kind, do: :empty_decl_surface_probe
  def tool_schema, do: %{name: "empty_decl_surface_probe", params: []}
  def effect, do: :read
  def tool_surfaces, do: []
end

defmodule WriteOnCiEvalTool do
  @moduledoc false
  # Declares :ci_eval with effect: :write -- exactly the shape UXD-11's guarantee
  # ("a write tool can never open a real E3 approval from a CI eval run") forbids.
  def kind, do: :write_on_ci_eval_probe
  def tool_schema, do: %{name: "write_on_ci_eval_probe", params: []}
  def effect, do: :write
  def tool_surfaces, do: [:ci_eval]
end

defmodule ReadOnCiEvalTool do
  @moduledoc false
  # Negative control: a read-effect tool on :ci_eval is the shipped, legitimate shape.
  def kind, do: :read_on_ci_eval_probe
  def tool_schema, do: %{name: "read_on_ci_eval_probe", params: []}
  def effect, do: :read
  def tool_surfaces, do: [:ci_eval]
end

defmodule Mix.Tasks.Samen.Verify.ToolSurfaceTest do
  @moduledoc """
  T183b (UXD-11/UXD-12) — anti-tautology proof for `mix samen.verify.tool_surface`: the four
  `Samen.AI.ToolSurface` invariants UXD-12 named cannot rot silently, and the `:ci_eval`
  read-only shape UXD-11 depends on is a checked gate, not an unchecked assumption.

  Four layers, the house verifier discipline (mirrors
  `tool_actor_identity_verifier_test.exs`):
    1. **every opted-in tool lands on a surface** — a malformed/empty declaration flips;
       the shipped set is clean.
    2. **the `:mcp` registry agrees with its own source** — clean on the shipped tree
       (no config seam exists to fake `Samen.AI.Mcp.tool_names/0`; the sabotage patch
       targets this function directly, see `scripts/sabotages/300-*.patch`).
    3. **`surfaces/0` is exactly the four** — the `SAMEN_TOOL_SURFACE_INJECT_SURFACES` seam
       proves a changed closed set flips the check WITHOUT mutating the shipped module.
    4. **`:ci_eval` owns read-effect tools only** — a modeled `effect: :write` tool on
       `:ci_eval` flips; the shipped 2-tool set and a modeled `effect: :read` tool stay clean.
    5. **exit-code layer** — `System.cmd/3` in a child OS process, the only way to observe
       `:erlang.halt(1)` without killing the test VM.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.ToolSurface, as: V
  alias Samen.Automation.Action

  @project_dir Path.expand("../../", __DIR__)
  @inject_env "SAMEN_TOOL_SURFACE_INJECT_SURFACES"

  setup do
    previous = Application.get_env(:samen_core, Action, [])
    on_exit(fn -> Application.put_env(:samen_core, Action, previous) end)
    %{previous: previous}
  end

  defp register(extra, %{previous: previous}) do
    Application.put_env(:samen_core, Action, Keyword.put(previous, :extra, extra))
    Samen.AI.Agent.Tools.refresh()
  end

  # ==========================================================================
  # (1) every_tool_on_a_surface_violations/0
  # ==========================================================================

  describe "every_tool_on_a_surface_violations/0 — clean shipped set" do
    test "the shipped opted-in tools all land on at least one surface" do
      assert V.every_tool_on_a_surface_violations() == []
    end
  end

  describe "every_tool_on_a_surface_violations/0 — each defect flips" do
    test "a malformed tool_surfaces/0 declaration is a violation (sabotage-refutable)", ctx do
      register(%{"malformed_surface_probe" => MalformedSurfaceTool}, ctx)

      assert Enum.any?(
               V.every_tool_on_a_surface_violations(),
               &(&1 =~ "malformed_surface_probe")
             )
    end

    test "an explicit empty tool_surfaces/0 declaration is a violation", ctx do
      register(%{"empty_decl_surface_probe" => EmptyDeclSurfaceTool}, ctx)

      assert Enum.any?(
               V.every_tool_on_a_surface_violations(),
               &(&1 =~ "empty_decl_surface_probe")
             )
    end

    test "a well-formed tool_surfaces/0 declaration is NOT flagged (not blanket-failing)",
         ctx do
      register(%{"clean_surface_probe" => CleanSurfaceTool}, ctx)

      refute Enum.any?(
               V.every_tool_on_a_surface_violations(),
               &(&1 =~ "clean_surface_probe")
             )
    end
  end

  # ==========================================================================
  # (2) mcp_registry_agreement_violations/0
  # ==========================================================================

  describe "mcp_registry_agreement_violations/0" do
    test "Mcp.tool_names/0 and ToolSurface.names(:mcp) agree on the shipped tree" do
      assert V.mcp_registry_agreement_violations() == []
    end
  end

  # ==========================================================================
  # (3) exactly_four_surfaces_violations/0
  # ==========================================================================

  describe "exactly_four_surfaces_violations/0" do
    test "the shipped surfaces/0 is exactly the four" do
      assert V.exactly_four_surfaces_violations() == []
    end

    test "a changed closed set is a violation (injection seam, no module mutated)" do
      System.put_env(@inject_env, "mcp,operator,tenant")
      on_exit(fn -> System.delete_env(@inject_env) end)

      assert Enum.any?(V.exactly_four_surfaces_violations(), &(&1 =~ "expected exactly"))
    end

    test "a widened closed set is also a violation" do
      System.put_env(@inject_env, "mcp,operator,tenant,ci_eval,rogue")
      on_exit(fn -> System.delete_env(@inject_env) end)

      assert Enum.any?(V.exactly_four_surfaces_violations(), &(&1 =~ "expected exactly"))
    end
  end

  # ==========================================================================
  # (4) ci_eval_read_only_violations/0 -- UXD-11's structural half
  # ==========================================================================

  describe "ci_eval_read_only_violations/0 — clean shipped set" do
    test "the shipped :ci_eval tools (fetch_record, search_records) are both read-effect" do
      assert V.ci_eval_read_only_violations() == []
    end
  end

  describe "ci_eval_read_only_violations/0 — each defect flips" do
    test "an effect: :write tool on :ci_eval is a violation (UXD-11, sabotage-refutable)",
         ctx do
      register(%{"write_on_ci_eval_probe" => WriteOnCiEvalTool}, ctx)

      assert Enum.any?(
               V.ci_eval_read_only_violations(),
               &(&1 =~ "write_on_ci_eval_probe")
             )
    end

    test "an effect: :read tool on :ci_eval is NOT flagged (not blanket-failing)", ctx do
      register(%{"read_on_ci_eval_probe" => ReadOnCiEvalTool}, ctx)

      refute Enum.any?(
               V.ci_eval_read_only_violations(),
               &(&1 =~ "read_on_ci_eval_probe")
             )
    end
  end

  # ==========================================================================
  # Exit-code layer — the true :erlang.halt code (house discipline)
  # ==========================================================================

  describe "exit-code layer (System.cmd/3)" do
    @tag :exit_code
    test "the real tree exits 0" do
      {output, code} =
        System.cmd("mix", ["samen.verify.tool_surface"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert code == 0, "expected the shipped tree to pass; output:\n#{output}"
      assert output =~ "OK — no violations"
    end

    @tag :exit_code
    test "RED PATH: the injected-surfaces seam flips the gate to exit 1" do
      {output, code} =
        System.cmd("mix", ["samen.verify.tool_surface"],
          cd: @project_dir,
          env: [
            {"MIX_ENV", "test"},
            {"SAMEN_TOOL_SURFACE_INJECT_SURFACES", "mcp,operator,tenant"}
          ],
          stderr_to_stdout: true
        )

      assert code == 1, "expected exit 1 on the injected surface change; output:\n#{output}"
      assert output =~ "expected exactly"
    end

    @tag :exit_code
    test "the injected-surfaces seam does NOT flip on the real four (anti-tautology)" do
      {output, code} =
        System.cmd("mix", ["samen.verify.tool_surface"],
          cd: @project_dir,
          env: [
            {"MIX_ENV", "test"},
            {"SAMEN_TOOL_SURFACE_INJECT_SURFACES", "mcp,operator,tenant,ci_eval"}
          ],
          stderr_to_stdout: true
        )

      assert code == 0,
             "expected the real four (reordered-safe) NOT to flip the gate; output:\n#{output}"
    end
  end
end
