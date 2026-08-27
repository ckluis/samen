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
  # T187 — the F-4 lock closes the `apply/3` indirection gap (findings/042,
  # ADR-047 §10a row 19/row 24). Before this fix, a tool re-entering the loop via
  # `apply(Samen.AI.Agent, :start, [...])` was invisible to BOTH the AST branch and the
  # regex fallback — `spawn_lock_violations/2` reported it clean. Every shape below is a
  # distinct evasion of a naive "match the literal `Agent.start(...)` call text" scan.
  # ==========================================================================

  describe "(1b) F-4 raw-spawn AST lock — apply/3 indirection (T187)" do
    @rogue_apply_tool """
    defmodule RogueApplyTool do
      @behaviour Samen.Automation.Action
      def kind, do: :rogue_apply
      def tool_schema, do: %{name: "rogue_apply", params: []}
      def effect, do: :read
      def validate(c, _), do: {:ok, c}

      def run(_config, ctx) do
        apply(Samen.AI.Agent, :start, [SomeAgent, ctx.actor, "recurse", []])
      end
    end
    """

    test "RED FIXTURE — apply(Samen.AI.Agent, :start, [...]) is flagged (was invisible pre-T187)" do
      assert V.source_defines_tool_schema?(@rogue_apply_tool)
      assert V.source_reenters_loop?(@rogue_apply_tool)
    end

    test "spawn_lock_violations/2 flips on the apply/3 fixture path (refutable, matches the F-4 message)" do
      tmp = Path.join(System.tmp_dir!(), "agcov_apply_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      rogue = Path.join(tmp, "rogue_apply_tool.ex")
      File.write!(rogue, @rogue_apply_tool)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [msg] = V.spawn_lock_violations([rogue], tmp)
      assert msg =~ "raw-spawn recursion escape"
    end

    test "apply/3 with a non-literal args expression still flags (target is what matters, not arg shape)" do
      assert V.source_reenters_loop?("""
      defmodule RogueApplyVarArgs do
        def tool_schema, do: %{name: "x"}

        def run(_config, ctx) do
          args = [SomeAgent, ctx.actor, "recurse", []]
          apply(Samen.AI.Agent, :start, args)
        end
      end
      """)

      assert V.source_reenters_loop?("""
      defmodule RogueApplyCallArgs do
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: apply(Samen.AI.Agent, :run, build_args(ctx))
      end
      """)
    end

    test "Kernel.apply/3 (fully-qualified) is flagged the same as bare apply/3" do
      assert V.source_reenters_loop?("""
      defmodule RogueKernelApply do
        def tool_schema, do: %{name: "x"}
        def run(_config, _ctx), do: Kernel.apply(Samen.AI.Agent, :run, [])
      end
      """)
    end

    test ":erlang.apply/3 (the BEAM-primitive spelling) is flagged" do
      assert V.source_reenters_loop?("""
      defmodule RogueErlangApply do
        def tool_schema, do: %{name: "x"}
        def run(_config, _ctx), do: :erlang.apply(Samen.AI.Agent, :start, [])
      end
      """)
    end

    test "the pipe-operator spelling (Agent |> apply(:start, args)) is flagged" do
      assert V.source_reenters_loop?("""
      defmodule RoguePipeApply do
        def tool_schema, do: %{name: "x"}
        def run(_config, _ctx), do: Samen.AI.Agent |> apply(:start, [])
      end
      """)
    end

    test "an aliased Agent via apply/3 is flagged, same heuristic as the direct-call aliased case" do
      assert V.source_reenters_loop?("""
      defmodule RogueAliasedApply do
        alias Samen.AI.Agent
        def tool_schema, do: %{name: "x"}
        def run(_config, _ctx), do: apply(Agent, :run, [])
      end
      """)
    end

    test "a bare module-atom-literal target is flagged (no __aliases__ AST node for this syntax)" do
      assert V.source_reenters_loop?("""
      defmodule RogueAtomLiteralApply do
        def tool_schema, do: %{name: "x"}
        def run(_config, _ctx), do: apply(:"Elixir.Samen.AI.Agent", :start, [])
      end
      """)
    end

    test "an unrelated apply/3 call is NOT flagged (anti-tautology negative control)" do
      refute V.source_reenters_loop?("""
      defmodule CleanApplyUser do
        def tool_schema, do: %{name: "x"}
        def run(c, _ctx), do: {:ok, apply(Enum, :map, [c.items, fn x -> x end])}
      end
      """)
    end

    # ========================================================================
    # UXD-05 (T13-verdict-attempt1.json / V13's strongest_attack) — a RENAMED alias
    # (`alias Samen.AI.Agent, as: A`) evaded BOTH the direct-call form and the apply/3
    # form: `agent_kernel_alias?/1`'s `List.last(parts) == :Agent` heuristic saw only
    # `[:A]` and never matched. Pre-existing, not introduced by T187 — distinct from the
    # "(1b)" `apply(Agent, :run, [])` case above, which uses the DEFAULT (un-renamed)
    # `alias Samen.AI.Agent` and was already caught. Reproduced against `HEAD~1`
    # (`work/repro.md`, cited from `_orch/verify/T13-verdict-attempt1.json`) before this
    # fix; both forms below MUST flag now that `agent_kernel_alias?/2` resolves the
    # file's own `alias ..., as:` renames.
    # ========================================================================

    test "RED FIXTURE (UXD-05) — a renamed alias evades the DIRECT-CALL form" do
      assert V.source_reenters_loop?("""
      defmodule RogueAliasRenameDirect do
        alias Samen.AI.Agent, as: A
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: A.start(SomeAgent, ctx.actor, "recurse", [])
      end
      """)
    end

    test "RED FIXTURE (UXD-05) — a renamed alias evades the apply/3 form" do
      assert V.source_reenters_loop?("""
      defmodule RogueAliasRenameApply do
        alias Samen.AI.Agent, as: A
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: apply(A, :start, [SomeAgent, ctx.actor, "recurse", []])
      end
      """)
    end

    test "spawn_lock_violations/2 flips on the renamed-alias fixture path (refutable)" do
      tmp = Path.join(System.tmp_dir!(), "agcov_alias_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      rogue = Path.join(tmp, "rogue_alias_rename.ex")

      File.write!(rogue, """
      defmodule RogueAliasRenameBoth do
        alias Samen.AI.Agent, as: A
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx) do
          A.start(SomeAgent, ctx.actor, "recurse", [])
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [msg] = V.spawn_lock_violations([rogue], tmp)
      assert msg =~ "raw-spawn recursion escape"
    end

    test "a renamed alias to an UNRELATED module is NOT flagged (anti-overreach)" do
      refute V.source_reenters_loop?("""
      defmodule CleanRenamedAlias do
        alias Enum, as: A
        def tool_schema, do: %{name: "x"}
        def run(c, _ctx), do: A.map(c.items, fn x -> x end)
      end
      """)
    end

    # ========================================================================
    # UXD-05 attempt-2 (T11-verdict.json, V13's REFUTATION of attempt 1's `29f7786`) — a
    # CHAINED / nested alias rename (a rename OF a rename: `alias Samen.AI.Agent, as: A`
    # then `alias A, as: B`) evaded BOTH call forms even after attempt 1's single-hop fix:
    # `collect_renamed_agent_aliases/1` only ever compared an alias declaration's OWN
    # right-hand side against the literal kernel name, so `B`'s RHS (`[:A]`) was never
    # literally the kernel and `B` never entered the renamed set. Reproduced against
    # attempt 1's tree (`29f7786`, `work/repro.md`) before this fix: both forms below
    # returned `source_reenters_loop? = false`. Fixed by resolving renames to a FIXED
    # POINT (`resolve_renamed_aliases/2`) instead of one literal-only pass.
    # ========================================================================

    test "RED FIXTURE (UXD-05, attempt 2) — a CHAINED renamed alias evades the DIRECT-CALL form" do
      assert V.source_reenters_loop?("""
      defmodule RogueChainedAliasDirect do
        alias Samen.AI.Agent, as: A
        alias A, as: B
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: B.start(SomeAgent, ctx.actor, "recurse", [])
      end
      """)
    end

    test "RED FIXTURE (UXD-05, attempt 2) — a CHAINED renamed alias evades the apply/3 form" do
      assert V.source_reenters_loop?("""
      defmodule RogueChainedAliasApply do
        alias Samen.AI.Agent, as: A
        alias A, as: B
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: apply(B, :start, [SomeAgent, ctx.actor, "recurse", []])
      end
      """)
    end

    test "a THREE-hop chain (arbitrary depth, not just a single re-alias) still resolves" do
      assert V.source_reenters_loop?("""
      defmodule RogueTripleChainedAlias do
        alias Samen.AI.Agent, as: A
        alias A, as: B
        alias B, as: C
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: C.run(SomeAgent, ctx.actor, "recurse", [])
      end
      """)
    end

    test "spawn_lock_violations/2 flips on the chained-alias fixture path (refutable)" do
      tmp = Path.join(System.tmp_dir!(), "agcov_chain_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      rogue = Path.join(tmp, "rogue_chained_alias.ex")

      File.write!(rogue, """
      defmodule RogueChainedAliasBoth do
        alias Samen.AI.Agent, as: A
        alias A, as: B
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx) do
          B.start(SomeAgent, ctx.actor, "recurse", [])
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [msg] = V.spawn_lock_violations([rogue], tmp)
      assert msg =~ "raw-spawn recursion escape"
    end

    test "a chained alias to an UNRELATED module is NOT flagged (anti-overreach, chain form)" do
      refute V.source_reenters_loop?("""
      defmodule CleanChainedAlias do
        alias Enum, as: A
        alias A, as: B
        def tool_schema, do: %{name: "x"}
        def run(c, _ctx), do: B.map(c.items, fn x -> x end)
      end
      """)
    end

    test "an alias CYCLE that never bottoms out at the kernel is NOT flagged and does not hang" do
      # Guards the resolver's termination argument: a head is substituted at most once
      # along any path (`visited`), so a cycle cannot loop (see `resolves_to_kernel?/3`).
      task =
        Task.async(fn ->
          V.source_reenters_loop?("""
          defmodule CleanAliasCycle do
            alias Foo, as: X
            alias X, as: Y
            alias Y, as: X
            def tool_schema, do: %{name: "x"}
            def run(_c, ctx), do: X.start(ctx, [])
          end
          """)
        end)

      refute Task.await(task, 2_000)
    end

    # UXD-05 attempt-3 (T11-verdict.json's `strongest_attack`, the REFUTATION of attempt 2's
    # `39ebc4d`) — a PARENT-NAMESPACE rename evaded both attempt 1's single-hop fix and
    # attempt 2's alias-of-alias chain fix: `alias Samen.AI, as: A` renames a PREFIX segment,
    # not the kernel module, so neither the literal-suffix test nor the single-segment chain
    # hop ever fired and `A.Agent.start(...)` was invisible in all five call shapes.
    # Fixed by replacing shape-by-shape matching with Elixir's own resolution rule: an
    # ALIAS ENVIRONMENT (`alias_env/1`) plus head-segment substitution
    # (`resolves_to_kernel?/3`). The tests below pin the whole class, not just this instance.

    test "RED FIXTURE (UXD-05, attempt 3) — a PARENT-namespace rename evades the DIRECT-CALL form" do
      assert V.source_reenters_loop?("""
             defmodule RogueParentRenameDirect do
               alias Samen.AI, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.Agent.start(ctx.actor, [])
             end
             """)
    end

    test "RED FIXTURE (UXD-05, attempt 3) — a PARENT-namespace rename evades the apply/3 form" do
      assert V.source_reenters_loop?("""
             defmodule RogueParentRenameApply do
               alias Samen.AI, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: apply(A.Agent, :start, [ctx.actor, []])
             end
             """)
    end

    test "RED FIXTURE (UXD-05, attempt 3) — a PARENT rename carrying a further as: chain" do
      assert V.source_reenters_loop?("""
             defmodule RogueParentRenameChained do
               alias Samen.AI, as: A
               alias A.Agent, as: B
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: B.start(ctx.actor, [])
             end
             """)
    end

    test "a PARENT rename resolves in the pipe, Kernel.apply and :erlang.apply shapes too" do
      for call <- [
            "A.Agent |> apply(:start, [ctx.actor, []])",
            "Kernel.apply(A.Agent, :start, [ctx.actor, []])",
            ":erlang.apply(A.Agent, :run, [ctx.actor, []])"
          ] do
        assert V.source_reenters_loop?("""
               defmodule RogueParentRenameShape do
                 alias Samen.AI, as: A
                 def tool_schema, do: %{name: "x"}
                 def run(_config, ctx), do: #{call}
               end
               """),
               "the parent-namespace rename evaded the call shape #{call}"
      end
    end

    test "a ROOT-segment rename resolves — the renamed segment may sit at ANY prefix depth" do
      assert V.source_reenters_loop?("""
             defmodule RogueRootRename do
               alias Samen, as: S
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: S.AI.Agent.start(ctx.actor, [])
             end
             """)
    end

    test "a PARENT rename resolves regardless of declaration order" do
      # The environment stores right-hand sides UNEXPANDED and expands on lookup, so a
      # rename written ABOVE the alias it renames resolves identically.
      assert V.source_reenters_loop?("""
             defmodule RogueParentRenameReversed do
               alias A.Agent, as: B
               alias Samen.AI, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: B.start(ctx.actor, [])
             end
             """)
    end

    test "an alias declared INSIDE a function body is resolved, not only a module-top alias" do
      assert V.source_reenters_loop?("""
             defmodule RogueScopedAlias do
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx) do
                 alias Samen.AI, as: A
                 A.Agent.start(ctx.actor, [])
               end
             end
             """)
    end

    test "the brace form alias Samen.AI.{Agent, …} resolves, including on a renamed prefix" do
      assert V.source_reenters_loop?("""
             defmodule RogueBraceOnRenamedPrefix do
               alias Samen.AI, as: A
               alias A.{Agent, Tool}
               alias Agent, as: Z
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: Z.start(ctx.actor, [])
             end
             """)
    end

    test "a shadowed alias name counts if EITHER declaration reaches the kernel" do
      assert V.source_reenters_loop?("""
             defmodule RogueShadowedAlias do
               alias Enum, as: A
               alias Samen.AI.Agent, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.start(ctx.actor, [])
             end
             """)
    end

    test "a __MODULE__-relative prefix falls back to its literal suffix" do
      # `__MODULE__` cannot be resolved statically; the reference is re-tested on the
      # segments after it, i.e. exactly as conservatively as a bare `Agent`.
      assert V.source_reenters_loop?("""
             defmodule RogueModuleRelative do
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: __MODULE__.Agent.start(ctx.actor, [])
             end
             """)
    end

    test "an UNQUALIFIED start/… after import Samen.AI.Agent is flagged" do
      # `import` binds function names, not module names — no qualified-call clause can see it.
      assert V.source_reenters_loop?("""
             defmodule RogueImportedKernel do
               import Samen.AI.Agent
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: start(ctx.actor, [])
             end
             """)
    end

    test "a module's own `def start/2` is NOT mistaken for an imported-kernel call" do
      # def/defp HEADS are stripped before the unqualified scan; only call sites count.
      refute V.source_reenters_loop?("""
             defmodule CleanOwnStartDefinition do
               import Samen.AI.Agent
               def tool_schema, do: %{name: "x"}
               def start(_actor, _opts), do: :ok
             end
             """)
    end

    test "a PARENT rename of an UNRELATED namespace is NOT flagged (anti-overreach)" do
      refute V.source_reenters_loop?("""
             defmodule CleanUnrelatedParentRename do
               alias MyApp.Workers, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.Agent.start(ctx.actor, [])
             end
             """)
    end

    test "spawn_lock_violations/2 flips on the parent-rename fixture path (refutable)" do
      tmp = Path.join(System.tmp_dir!(), "agcov_parent_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      rogue = Path.join(tmp, "rogue_parent_rename.ex")

      File.write!(rogue, """
      defmodule RogueParentRenameOnDisk do
        alias Samen.AI, as: A
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx), do: A.Agent.start(ctx.actor, [])
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [msg] = V.spawn_lock_violations([rogue], tmp)
      assert msg =~ "raw-spawn recursion escape"
    end

    test "a SELF-GROWING alias (alias A.B, as: A) terminates and is NOT flagged" do
      # Value-based cycle detection would loop forever here ([:A] -> [:A,:B] -> [:A,:B,:B]
      # …, never repeating). Head-based `visited` bounds it at one substitution per name.
      task =
        Task.async(fn ->
          V.source_reenters_loop?("""
          defmodule SelfGrowingAlias do
            alias A.B, as: A
            def tool_schema, do: %{name: "x"}
            def run(_c, ctx), do: A.start(ctx, [])
          end
          """)
        end)

      refute Task.await(task, 2_000)
    end

    test "a mutual PREFIX cycle terminates and is NOT flagged" do
      task =
        Task.async(fn ->
          V.source_reenters_loop?("""
          defmodule MutualPrefixCycle do
            alias A.X, as: B
            alias B.Y, as: A
            def tool_schema, do: %{name: "x"}
            def run(_c, ctx), do: A.Agent.start(ctx, [])
          end
          """)
        end)

      refute Task.await(task, 2_000)
    end

    # ========================================================================
    # UXD-05 attempt-4 (`_orch/verify/T11-verdict-attempt3.json`, V11's REFUTATION of
    # attempt 3's `33723d8`). Attempt 3 modelled the `alias` KEYWORD, not Elixir's alias
    # ENVIRONMENT: `alias_env/1`'s prewalk matched only `{:alias, _, args}`, so
    # `require Samen.AI.Agent, as: A` — Elixir's OTHER alias-creating form — bound nothing
    # and `A.start(...)` was invisible; and `alias_bindings/1`'s `as:` clause demanded a
    # `{:__aliases__, _, parts}` target, so an ATOM target evaded too. Proved AT THE GATE,
    # not merely at the predicate: `V.spawn_lock_violations/2` over three
    # `tool_schema/0`-exporting fixture files returned 0 violations for the require-as file
    # and 0 for the atom-alias file, against 1 for a byte-identical plain-`alias` control.
    # Closed by `require_bindings/1` and the atom clause of `alias_bindings/1`.
    # ========================================================================

    test "RED FIXTURE (UXD-05, attempt 4) — `require ..., as:` renaming the KERNEL evades the DIRECT-CALL form" do
      assert V.source_reenters_loop?("""
             defmodule RogueRequireAsDirect do
               require Samen.AI.Agent, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.start(SomeAgent, ctx.actor, "recurse", [])
             end
             """)
    end

    test "RED FIXTURE (UXD-05, attempt 4) — `require ..., as:` evades the apply/3 form" do
      assert V.source_reenters_loop?("""
             defmodule RogueRequireAsApply do
               require Samen.AI.Agent, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: apply(A, :start, [SomeAgent, ctx.actor, "recurse", []])
             end
             """)
    end

    test "RED FIXTURE (UXD-05, attempt 4) — `require ..., as:` renaming a PREFIX segment" do
      assert V.source_reenters_loop?("""
             defmodule RogueRequireAsPrefix do
               require Samen.AI, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.Agent.start(SomeAgent, ctx.actor, "recurse", [])
             end
             """)
    end

    test "RED FIXTURE (UXD-05, attempt 4) — a require-as binding SEEDS a further alias chain" do
      assert V.source_reenters_loop?("""
             defmodule RogueRequireThenAlias do
               require Samen.AI, as: A
               alias A.Agent, as: B
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: B.start(SomeAgent, ctx.actor, "recurse", [])
             end
             """)
    end

    test "RED FIXTURE (UXD-05, attempt 4) — an ATOM alias target (`alias :\"Elixir...\", as: A`)" do
      assert V.source_reenters_loop?("""
             defmodule RogueAtomAliasTarget do
               alias :"Elixir.Samen.AI.Agent", as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.start(SomeAgent, ctx.actor, "recurse", [])
             end
             """)
    end

    test "spawn_lock_violations/2 flips on the require-as and atom-alias fixture paths (refutable, gate level)" do
      tmp = Path.join(System.tmp_dir!(), "agcov_a4_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      fixtures = %{
        "rogue_require_as.ex" => "require Samen.AI.Agent, as: A",
        "rogue_atom_alias.ex" => "alias :\"Elixir.Samen.AI.Agent\", as: A"
      }

      for {file, binding} <- fixtures do
        path = Path.join(tmp, file)

        File.write!(path, """
        defmodule Rogue#{System.unique_integer([:positive])} do
          #{binding}
          def tool_schema, do: %{name: "x"}
          def run(_config, ctx), do: A.start(ctx.agent, ctx.actor, "recurse", [])
        end
        """)

        assert [msg] = V.spawn_lock_violations([path], tmp), "#{file} passed the F-4 lock"
        assert msg =~ "raw-spawn recursion escape"
      end
    end

    test "ANTI-OVERREACH — a require-as to an UNRELATED module is NOT flagged" do
      refute V.source_reenters_loop?("""
             defmodule BenignRequireAs do
               require Enum, as: A
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: A.start(ctx, [])
             end
             """)
    end

    test "ANTI-OVERREACH — a bare `require` with NO as: binds nothing (require does not alias)" do
      # `require Samen.AI.Agent` creates no alias in Elixir, so it must not seed the
      # environment. If it did, the unrelated `Registry.start(...)` below could not be
      # distinguished from a real rename and this scan would flag ordinary `require`s.
      refute V.source_reenters_loop?("""
             defmodule BenignBareRequire do
               require Logger
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: Registry.start(ctx, [])
             end
             """)
    end

    test "KNOWN RESIDUAL (module-attribute indirection) — `@k Samen.AI.Agent` then `@k.start` is NOT caught" do
      # Residual 4 of the tier moduledoc, STATED and TESTED rather than silent. A module
      # attribute is not an alias — it never enters `alias_env/1`, and the call target is
      # an `{:@, _, _}` node. Both live forms V11 proved (direct call and apply/3) are
      # recorded here. If a later change CLOSES this, this test goes red and the moduledoc
      # residual must be retired in the same commit — that is the point of pinning it.
      refute V.source_reenters_loop?("""
             defmodule RogueAttrDirect do
               @k Samen.AI.Agent
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: @k.start(SomeAgent, ctx.actor, "recurse", [])
             end
             """)

      refute V.source_reenters_loop?("""
             defmodule RogueAttrApply do
               @k Samen.AI.Agent
               def tool_schema, do: %{name: "x"}
               def run(_config, ctx), do: apply(@k, :start, [SomeAgent, ctx.actor, "recurse", []])
             end
             """)
    end

    test "KNOWN RESIDUAL (documented, not closed) — Module.concat/2 + apply/3 dynamic construction is NOT caught" do
      # Deliberately proving the residual the moduledoc and work/limits.md name: a target
      # built at runtime carries no __aliases__ AST node and no atom literal to match — a
      # DISTINCT vulnerability class from an alias rename, explicitly out of scope here.
      refute V.source_reenters_loop?("""
      defmodule RogueDynamicConcat do
        def tool_schema, do: %{name: "x"}
        def run(_config, ctx) do
          mod = Module.concat(Samen.AI, Agent)
          apply(mod, :start, [ctx.actor, []])
        end
      end
      """)
    end

    test "KNOWN RESIDUAL — the disclosure itself is pinned in the tier source" do
      # The behavioural test above passes whether or not the limit is DOCUMENTED, so on its
      # own it pins nothing about the documentation (T11-verdict.json proved exactly that by
      # deleting the moduledoc paragraph and watching the behavioural test stay green). This
      # test reads the tier's own source and fails if any residual disclosure disappears —
      # a silent bypass is worse than a documented limit, so the documentation is the
      # deliverable and it is now refutable.
      source =
        Path.expand("../../lib/mix/tasks/samen.verify.agent_coverage.ex", __DIR__)
        |> File.read!()

      for fragment <- [
            "**KNOWN RESIDUALS — DOCUMENTED, NOT CLOSED.**",
            "`mod = Module.concat(Samen.AI, Agent);",
            "**The unparsable-source fallback.**",
            "**Indirection through another module or a macro.**",
            # UXD-05 attempt 4. V11's refutation of attempt 3 was not "an evasion exists"
            # but "that class is UNDISCLOSED": the pin can only protect a residual that was
            # written down, so every class this run knows about now has a fragment here.
            "**MODULE-ATTRIBUTE INDIRECTION**",
            "`@k Samen.AI.Agent` followed by `@k.start(...)`",
            "`require Samen.AI.Agent, as: A` (and the prefix form `require Samen.AI, as: A`)",
            "an ATOM alias target, `alias :\"Elixir.Samen.AI.Agent\", as: A`"
          ] do
        assert String.contains?(source, fragment),
               "the agent_coverage tier source no longer discloses #{inspect(fragment)}. " <>
                 "A documented residual of the F-4 raw-spawn lock may not disappear " <>
                 "silently (UXD-05, attempt 3)."
      end
    end

    test "the regex fallback (genuinely unparsable source) also catches apply/3 and Kernel.apply/3" do
      # Deliberately syntactically broken (unbalanced parens/end) so Code.string_to_quoted/2
      # errors and source_reenters_loop?/1 must take the regex-fallback branch, not the AST one.
      broken_bare_apply = """
      defmodule Broken1 do
        def tool_schema, do: %{name: "x"
        def run(_c, ctx) do
          apply(Samen.AI.Agent, :start, [ctx.actor]
        end
      """

      assert {:error, _} = Code.string_to_quoted(broken_bare_apply)
      assert V.source_reenters_loop?(broken_bare_apply)

      broken_kernel_apply = """
      defmodule Broken2 do
        def tool_schema, do: %{name: "x"
        def run(_c, ctx) do
          Kernel.apply(Agent, :run, [ctx.actor]
        end
      """

      assert {:error, _} = Code.string_to_quoted(broken_kernel_apply)
      assert V.source_reenters_loop?(broken_kernel_apply)
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
