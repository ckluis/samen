defmodule Mix.Tasks.Samen.Verify.ToolSurface do
  @shortdoc "T183b (UXD-11/UXD-12): assert the Samen.AI.ToolSurface invariants can't rot silently."

  @moduledoc """
  `mix samen.verify.tool_surface` — the rung-1 handback T23 emitted for T183
  (`Samen.AI.ToolSurface`, ADR-043 §7/§9 + ADR-047 §5.1a PROPOSED).

  T183 shipped the one surface-scoped tool registry (`:mcp` / `:operator` / `:tenant` /
  `:ci_eval`) with NO verifier tier asserting its invariants — they were proven once, in
  `test/ai/tool_surface_test.exs`, and could rot silently after that (UXD-12,
  `_orch/nodes/T23/work/plan.md` §"§1.3 de-escalation"). This tier is the mechanical fix,
  fully specified by the shipped module. It mirrors the house verifier shape (`run/1` →
  `Samen.Verifier.halt_if_violations/2`; each `*_violations/0` callable without halting, for
  the anti-tautology sabotage test), and is wired into the ROOT `ci.sh` beside
  `mix samen.verify.tool_actor_identity` — the nearest neighbour, since both scan
  `Samen.Automation.Action.tool_kinds/0` AND the MCP tool catalogue.

  ## What it asserts

    * **(1) EVERY OPTED-IN TOOL LANDS ON AT LEAST ONE SURFACE.** For every kind in
      `Samen.Automation.Action.tool_kinds/0`, `Samen.AI.ToolSurface.surfaces_for/1` must
      return a non-empty list. A MALFORMED `tool_surfaces/0` fails CLOSED to `[]`
      (`tool_surface.ex`'s `normalize/1`), which makes the tool silently uncallable
      EVERYWHERE rather than loudly wrong — this check turns that silent failure into a
      named, gate-failing violation instead of a tool nobody notices went dark.
    * **(2) THE `:mcp` REGISTRY AGREES WITH ITS OWN SOURCE.** `Samen.AI.Mcp.tool_names/0`
      (the source of truth `ToolSurface.registry(:mcp)` reads) and
      `Samen.AI.ToolSurface.names(:mcp)` (the derived registry) must be the SAME sorted set.
      `ToolSurface` never hand-rolls a second MCP list; this pins that it can't drift into
      doing so.
    * **(3) THE FOUR SURFACES ARE EXACTLY THE FOUR THE BACKLOG NAMES.**
      `Samen.AI.ToolSurface.surfaces/0` must equal `[:mcp, :operator, :tenant, :ci_eval]` —
      not three, not five, and not silently reordered into a different closed set.
    * **(4) THE `:ci_eval` SURFACE OWNS READ-EFFECT TOOLS ONLY (UXD-11's structural half).**
      T183's moduledoc states the `:ci_eval` lane exists so a CI eval run can never open a
      real E3 approval — which only holds if nothing `effect: :write` ever lands on that
      surface. UXD-11 found the lane real in code but UNWIRED (no config set
      `agent_surface: :ci_eval`, so the guarantee was proven only against an explicit
      surface argument in tests, never against a running tier). That wiring has since
      landed (A08a/A08b, `_orch/nodes/A08a/work/ci-eval-disposition.md` — INVOKER):
      `samen_core/test/ai_eval/ai_plane_redteam_test.exs`'s permanent D8 EG2 tier now sets
      `agent_surface: :ci_eval` around its `EG2ReaderAgent`/`EG2NoToolsAgent` runs, so a
      real `Samen.AI.Agent` tool call is dispatched through this surface on every `mix
      test test/ai_eval/` / `ci.sh` run, not merely asserted against an explicit surface
      argument in a unit test. This tier's job is unchanged — making the one thing that
      must stay true for that wiring to be safe — every tool the surface OWNS is `effect:
      :read` — a checked, sabotage-refutable invariant instead of an unchecked assumption.
      An `effect: :write` action declaring `:ci_eval` now fails THIS gate before it can
      ever reach the wired eval tier.

  ## Diagnostics

      FAIL: samen.verify.tool_surface found 1 violation(s):
        • "rogue_tool": tool_kinds/0 lists it as an opted-in tool but
          Samen.AI.ToolSurface.surfaces_for/1 returns [] (on no surface, unreachable
          anywhere) — a malformed or dropped tool_surfaces/0 declaration.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `:erlang.halt/1`).
  """

  use Mix.Task

  alias Samen.AI.{Mcp, ToolSurface}
  alias Samen.Automation.Action

  @task_name "samen.verify.tool_surface"

  @expected_surfaces [:mcp, :operator, :tenant, :ci_eval]

  # Test seam (red-path exit-code proof, same discipline as
  # `samen.verify.tool_actor_identity`'s `SAMEN_TOOL_ACTOR_IDENTITY_INJECT_PARAM`): when
  # set, the surfaces/0 check is run against this literal instead of the real function,
  # proving the exit code flips WITHOUT mutating any shipped module. Absent in every
  # non-test invocation.
  @inject_env "SAMEN_TOOL_SURFACE_INJECT_SURFACES"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Samen.Verifier.halt_if_violations(@task_name, violations())
  end

  @doc """
  Compute the violations (list of human-readable strings), without halting — the
  test-callable seam, mirroring `tool_actor_identity`'s shape.
  """
  @spec violations() :: [String.t()]
  def violations do
    every_tool_on_a_surface_violations() ++
      mcp_registry_agreement_violations() ++
      exactly_four_surfaces_violations() ++
      ci_eval_read_only_violations()
  end

  # --- (1) every opted-in tool lands on at least one surface ------------------------------

  @doc "Violations for opted-in tool kinds that land on NO surface (public for tests)."
  @spec every_tool_on_a_surface_violations() :: [String.t()]
  def every_tool_on_a_surface_violations do
    for kind <- Action.tool_kinds(),
        mod = Action.module_for(kind),
        ToolSurface.surfaces_for(mod) == [] do
      "#{inspect(kind)}: tool_kinds/0 lists it as an opted-in tool but " <>
        "Samen.AI.ToolSurface.surfaces_for/1 returns [] (on no surface, unreachable " <>
        "anywhere) — a malformed or dropped tool_surfaces/0 declaration."
    end
  end

  # --- (2) the :mcp registry agrees with its own source ------------------------------------

  @doc "Violation(s) when Mcp.tool_names/0 and ToolSurface.names(:mcp) disagree (public for tests)."
  @spec mcp_registry_agreement_violations() :: [String.t()]
  def mcp_registry_agreement_violations do
    mcp_source = Mcp.tool_names() |> Enum.sort()
    derived = ToolSurface.names(:mcp)

    if mcp_source == derived do
      []
    else
      [
        "Samen.AI.Mcp.tool_names/0 (#{inspect(mcp_source)}) and " <>
          "Samen.AI.ToolSurface.names(:mcp) (#{inspect(derived)}) disagree — the :mcp " <>
          "registry must be read straight from its own source, never hand-rolled."
      ]
    end
  end

  # --- (3) the four surfaces are exactly the four ------------------------------------------

  @doc "Violation(s) when surfaces/0 is not exactly the four named surfaces (public for tests)."
  @spec exactly_four_surfaces_violations() :: [String.t()]
  def exactly_four_surfaces_violations do
    actual = injected_surfaces() || ToolSurface.surfaces()

    if actual == @expected_surfaces do
      []
    else
      [
        "Samen.AI.ToolSurface.surfaces/0 is #{inspect(actual)}, expected exactly " <>
          "#{inspect(@expected_surfaces)} — the closed surface set changed."
      ]
    end
  end

  defp injected_surfaces do
    case System.get_env(@inject_env) do
      nil ->
        nil

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.to_atom/1)
    end
  end

  # --- (4) :ci_eval owns read-effect tools only (UXD-11's structural half) ----------------

  @doc "Violations for any effect: :write action registered on :ci_eval (public for tests)."
  @spec ci_eval_read_only_violations() :: [String.t()]
  def ci_eval_read_only_violations do
    for {kind, mod} <- ToolSurface.registry(:ci_eval),
        mod != :mcp,
        Action.effect_for(mod) == :write do
      "#{inspect(kind)}: registered on the :ci_eval surface with effect: :write — a " <>
        "write tool on the CI eval lane could open a REAL E3 approval from a CI run " <>
        "(UXD-11; the :ci_eval surface's moduledoc guarantee)."
    end
  end
end
