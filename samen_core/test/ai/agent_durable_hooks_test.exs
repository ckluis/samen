defmodule UXD08HookProbe do
  @moduledoc """
  Cross-process scratch for the UXD-08/UXD-09 durable-hooks pin (the T181Probe
  `:persistent_term` convention, `agent_hooks_test.exs` — the durable path may execute
  inside Oban's queue producer/consumer, not necessarily the test process).
  """

  @key {:uxd08, :calls}

  def reset, do: :persistent_term.put(@key, [])
  def note(tag), do: :persistent_term.put(@key, :persistent_term.get(@key, []) ++ [tag])
  def calls, do: :persistent_term.get(@key, [])
end

defmodule UXD08Hooks do
  @moduledoc """
  Probe hooks for the durable-mode pin. `Halter` halts at `:session_start` — the ONE
  point `Samen.AI.Agent.Hook`'s doc names as firing "once, before the run's FIRST turn
  (both `run/4` and the worker)", which is exactly why it is the right seam to prove a
  per-run `:hooks` opt reaches (or silently does not reach) the durable path.
  """

  defmodule Halter do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:session_start, _ctx) do
      UXD08HookProbe.note(:per_run_halt)
      {:halt, :policy_stop}
    end

    def call(_point, _ctx), do: :ok
  end

  defmodule HostRecorder do
    @moduledoc """
    A host-configured hook that only notes itself and defers (`:ok`) — proves host
    config still fires in durable mode ALONGSIDE a per-run hook, and fires first
    (`Hooks.resolve/1`'s documented ordering).
    """
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(point, _ctx) do
      UXD08HookProbe.note({:host, point})
      :ok
    end
  end
end

defmodule UXD08Agents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "uxd08.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentDurableHooksTest do
  @moduledoc """
  UXD-08/UXD-09 — binding verdict:
  `/Users/clank/Desktop/projects/samen-oss-burndown/_orch/verify/T21-verdict.json`.

  `Samen.AI.Agent.start/4` silently ignored the per-run `:hooks` opt: `resolve_hooks/1`
  ran inside `run/4`'s `with`-block and nowhere in `start/4`'s, so a caller handing
  policy hooks to a DURABLE run got `{:ok, run}` back and no policy at all — while
  host-configured hooks (read straight from `Application.get_env/3` by the worker)
  survived the same worker boundary untouched. All 28 of T181's tests drove `run/4`
  only, so this divergence regressed unobserved (UXD-09).

  This file:

    * reproduces the drop and proves the fix, in ONE test, by CONTRAST: the identical
      `:session_start` halter passed to `start/4` must stop the DURABLE run before its
      first turn, exactly as it stops a `run/4` call with the SAME hook (both asserted
      here — the contrast is the finding, not either half alone);
    * drains the durable run through the REAL Oban entrypoint (`Oban.drain_queue/1`
      over the `:automation` queue, the same helper `agent_durability_test.exs` uses —
      NOT `execute_batch/1` called directly), so a regression in the Oban wiring itself,
      not just the hook-resolution helper, would also be caught;
    * pins a SECOND, independent property (the further test UXD-09 requires): a
      host-configured hook still fires in durable mode, and still fires AHEAD of the
      per-run hook — the fix must not trade the UXD-08 divergence for a new one where
      per-run hooks shadow host policy.

  Anti-tautology: `Scripted.remaining()` staying non-empty after a halt is the positive
  proof that the halt actually pre-empted the provider call, not an incidental status
  match.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias Samen.AI.Agent
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Provider.Scripted
  alias SamenCore.TestRepo
  alias UXD08Agents.Durable

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    Breaker.reset()
    UXD08HookProbe.reset()

    on_exit(fn ->
      Scripted.reset()
      Breaker.reset()
      UXD08HookProbe.reset()
    end)

    :ok
  end

  defp new_scope do
    org_id = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  # Merge agent-group config for one test, restoring the previous group on exit (the
  # agent_durability_test.exs convention).
  defp put_agent_config(kv) do
    previous = Application.get_env(:samen_core, Samen.AI.Agent, [])
    Application.put_env(:samen_core, Samen.AI.Agent, Keyword.merge(previous, kv))
    on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)
  end

  # The worker resolves its provider from host config — the A2 cross-process seam.
  defp scripted_worker_config, do: put_agent_config(provider: scripted_provider())

  defp drain_agent_queues do
    Oban.drain_queue(queue: :automation_timers, with_recursion: true)
    Oban.drain_queue(queue: :automation, with_recursion: true)
  end

  defp reload(run), do: Ash.get!(Run, run.id, authorize?: false)

  test "the SAME per-run :hooks opt halts run/4 AND the durable worker (UXD-08's fix, contrasted against the drop it fixes)" do
    scripted_worker_config()

    # -- contrast half: run/4, the mode T181's 28 tests already pin --
    s1 = new_scope()
    script([{:final, "should never be reached"}])

    assert {:error, :hook_halted, run4_run} =
             run_scripted(Durable, s1, "goal", hooks: [UXD08Hooks.Halter])

    assert run4_run.state == :failed
    assert run4_run.error_kind == "hook_halted"
    assert Scripted.remaining() != [], "run/4: the scripted turn must be UNCONSUMED"

    UXD08HookProbe.reset()

    # -- the durable half: the SAME hook, passed the SAME way, to start/4 --
    s2 = new_scope()
    script([{:final, "should never be reached either"}])

    assert {:ok, run} = Agent.start(Durable, s2, "goal", hooks: [UXD08Hooks.Halter])

    drain_agent_queues()

    run = reload(run)

    assert run.state == :failed,
           "the durable run must halt exactly like run/4 did — a :succeeded run here " <>
             "means the per-run :hooks opt never reached the worker (UXD-08's silent drop, " <>
             "reproduced on the parent commit)"

    assert run.error_kind == "hook_halted"
    assert :per_run_halt in UXD08HookProbe.calls()
    assert Scripted.remaining() != [], "durable mode: the scripted turn must be UNCONSUMED"
  end

  test "PIN (UXD-09): durable mode consults a host-configured hook AND the per-run hook, host first — the fix does not break host config" do
    scripted_worker_config()
    put_agent_config(hooks: [UXD08Hooks.HostRecorder])

    s = new_scope()
    script([{:final, "should never be reached"}])

    assert {:ok, run} = Agent.start(Durable, s, "goal", hooks: [UXD08Hooks.Halter])

    drain_agent_queues()

    run = reload(run)
    assert run.state == :failed
    assert run.error_kind == "hook_halted"

    # Host config fired FIRST (Hooks.resolve/1's documented ordering), then the per-run
    # hook decided — so BOTH survived the durable worker boundary, in the documented
    # order, never the per-run hook shadowing or pre-empting host policy.
    assert UXD08HookProbe.calls() == [{:host, :session_start}, :per_run_halt]
  end

  test "PIN: the per-run :hooks opt is persisted on the row (arn_hooks) before any worker ever executes it" do
    s = new_scope()

    assert {:ok, run} = Agent.start(Durable, s, "goal", hooks: [UXD08Hooks.Halter])

    # Read straight back — no drain, no worker, no provider call. This is the
    # row-durability mechanism itself (`create_run!`'s new `hooks:` field, UXD-08's
    # fix), independent of whether a worker ever consumes it.
    assert reload(run).hooks == [Atom.to_string(UXD08Hooks.Halter)]

    # A run started with NO per-run hooks stores the empty default — never a stray
    # leftover from a previous test's config (this run's own control).
    assert {:ok, bare_run} = Agent.start(Durable, new_scope(), "goal")
    assert reload(bare_run).hooks == []
  end
end
