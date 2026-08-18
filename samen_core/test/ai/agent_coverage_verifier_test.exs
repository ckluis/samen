defmodule Mix.Tasks.Samen.Verify.AgentCoverageTest do
  @moduledoc """
  ADR-047 batch **A7** — the anti-tautology proof for `mix samen.verify.agent_coverage`
  (§9#6). Two layers, the house verifier discipline:

    1. **unit layer** — `violations/1` + the source predicates called directly; the
       positive control (a rogue `tool_schema/0` module that calls `Samen.AI.Agent.start`)
       MUST flip the F-4 raw-spawn AST lock, and a clean tool MUST NOT.
    2. **exit-code layer** — `System.cmd/3` in a child OS process, the only way to observe
       `:erlang.halt(1)` without killing the test VM: the real tree exits 0; a scratch tree
       carrying a rogue re-entering tool exits 1 and names the F-4 violation.

  The single most load-bearing A7 assertion is the F-4 lock: a tool that re-enters the loop
  (`Samen.AI.Agent.start/run`) reopens the raw-spawn recursion escape A6 proved unreachable,
  and this gate must catch it. The positive control here is that anti-tautology proof.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.AgentCoverage, as: V

  @project_dir Path.expand("../../", __DIR__)
  @repo_root Path.expand("../../..", __DIR__)

  @rogue_tool """
  defmodule RogueReentrantTool do
    @behaviour Samen.Automation.Action
    def kind, do: :rogue_reentrant
    def tool_schema, do: %{name: "rogue_reentrant", params: []}
    def effect, do: :read
    def validate(c, _), do: {:ok, c}

    def run(_config, ctx) do
      # THE ESCAPE: a tool re-entering the agent loop (the raw-spawn recursion class).
      Samen.AI.Agent.start(SomeAgent, ctx.actor, "recurse", [])
    end
  end
  """

  @clean_agent """
  defmodule ScratchAgent do
    use Samen.AI.Agent, name: "scratch.agent", goal_prompt: "hi", tools: []
  end
  """

  # ==========================================================================
  # Unit layer — the F-4 raw-spawn AST lock (the crown jewel), non-vacuous
  # ==========================================================================

  describe "(1) F-4 raw-spawn AST lock — source predicates" do
    test "a rogue tool that BOTH exports tool_schema/0 AND calls Agent.start is flagged" do
      assert V.source_defines_tool_schema?(@rogue_tool)
      assert V.source_reenters_loop?(@rogue_tool)
    end

    test "a real read tool exports tool_schema/0 but does NOT re-enter the loop (green)" do
      clean = File.read!(Path.join(@project_dir, "lib/samen/automation/actions/fetch_record.ex"))
      assert V.source_defines_tool_schema?(clean)
      refute V.source_reenters_loop?(clean)
    end

    test "the loop kernel is not a tool, so the F-4 lock never fires on it" do
      kernel = File.read!(Path.join(@project_dir, "lib/samen/ai/agent.ex"))
      # The kernel DEFINES run/start (local defs), it does not CALL a qualified
      # `Samen.AI.Agent.start/run`, and it exports no `tool_schema/0` — so it is never a
      # scanned tool and the lock cannot false-fire on the loop itself.
      refute V.source_defines_tool_schema?(kernel)
    end

    test "spawn_lock_violations flips on a rogue path and is green on a clean path (refutable)" do
      tmp = Path.join(System.tmp_dir!(), "agcov_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      rogue = Path.join(tmp, "rogue_tool.ex")
      clean = Path.join(tmp, "clean_tool.ex")
      File.write!(rogue, @rogue_tool)

      File.write!(clean, """
      defmodule CleanTool do
        def tool_schema, do: %{name: "clean", params: []}
        def run(c, _ctx), do: {:ok, c}
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [msg] = V.spawn_lock_violations([rogue], tmp)
      assert msg =~ "raw-spawn recursion escape"
      assert V.spawn_lock_violations([clean], tmp) == []
    end

    test "a bare local run(...) inside a tool is NOT the loop kernel's Agent.run (no false flag)" do
      refute V.source_reenters_loop?("""
      defmodule LocalRunTool do
        def tool_schema, do: %{name: "x"}
        def run(c, _), do: run(c)
        defp run(c), do: {:ok, c}
      end
      """)
    end
  end

  # ==========================================================================
  # Unit layer — the whole gate is green on the real shipped tree
  # ==========================================================================

  describe "the shipped tree passes the coverage gate" do
    test "violations/1 is empty on the real umbrella tree" do
      assert V.violations(root: @repo_root) == []
    end

    test "agent-tools ⊆ registry: a declared bogus tool flips; opted-in tools stay green" do
      bogus = ~s(defmodule X do\n  use Samen.AI.Agent, name: "x", goal_prompt: "g", tools: ["no_such_tool"]\nend\n)
      good = ~s(defmodule Y do\n  use Samen.AI.Agent, name: "y", goal_prompt: "g", tools: ["fetch_record"]\nend\n)

      assert V.agent_declared_tools(bogus) == ["no_such_tool"]
      assert V.agent_declared_tools(good) == ["fetch_record"]

      tmp = Path.join(System.tmp_dir!(), "agcov_tools_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      bogus_path = Path.join(tmp, "bogus_agent.ex")
      good_path = Path.join(tmp, "good_agent.ex")
      File.write!(bogus_path, bogus)
      File.write!(good_path, good)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [msg] = V.agent_tools_subset_violations([{bogus_path, "X"}])
      assert msg =~ "opted-in registry action"
      assert V.agent_tools_subset_violations([{good_path, "Y"}]) == []
    end

    test "NON-VACUITY is real: the scan discovers driftwood's shipped agent" do
      # If discovery found nothing the floor would fire; prove it genuinely walks the tree.
      agent = Path.join(@repo_root, "driftwood/lib/driftwood/support/triage_agent.ex")
      assert File.regular?(agent)
      # The floor is satisfied ⇒ no NON-VACUITY violation in the green result above.
      refute Enum.any?(V.violations(root: @repo_root), &String.contains?(&1, "NON-VACUITY"))
    end
  end

  # ==========================================================================
  # Exit-code layer — the true :erlang.halt code (house discipline)
  # ==========================================================================

  describe "exit-code layer (System.cmd/3)" do
    @tag :exit_code
    test "the real tree exits 0" do
      {output, code} =
        System.cmd("mix", ["samen.verify.agent_coverage"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert code == 0, "expected the shipped tree to pass; output:\n#{output}"
      assert output =~ "OK — no violations"
    end

    @tag :exit_code
    test "a scratch tree with a rogue re-entering tool exits 1 and names the F-4 violation" do
      tmp = Path.join(System.tmp_dir!(), "agcov_root_#{System.unique_integer([:positive])}")
      # A vertical shape the scan walks (driftwood/lib), with an agent (floor) + the rogue tool.
      lib = Path.join(tmp, "driftwood/lib/scratch")
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, "rogue_tool.ex"), @rogue_tool)
      File.write!(Path.join(lib, "scratch_agent.ex"), @clean_agent)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {output, code} =
        System.cmd("mix", ["samen.verify.agent_coverage", "--root", tmp],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert code == 1, "expected a rogue re-entering tool to FAIL the gate; output:\n#{output}"
      assert output =~ "raw-spawn recursion escape"
    end
  end
end
