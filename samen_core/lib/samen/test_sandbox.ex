defmodule Samen.TestSandbox do
  @moduledoc """
  The one way a test turns the SQL sandbox into SHARED mode (ADR-053 P5). Sibling of `Samen.RedPath` /
  `Samen.Factory` / `Samen.MaskingCase`: test infra shipped in lib so every app's suite uses it.

  ## Why not `checkout/1` + `mode(repo, {:shared, self()})`

  That pair — in ~110 test modules — makes the TEST PROCESS the owner of the shared connection. ExUnit runs
  `on_exit` callbacks, and anything the test left running (an Oban/Task/GenServer doing an async insert), AFTER the
  test process has exited — and the moment it exits the shared connection's owner is gone, so every later DB call
  from those processes fails with `** (EXIT) shutdown: "owner #PID<…> exited"`. That was a CI flake that only
  showed up when the machine was slow enough for a late process to lose the race (never in the file alone).

  ## What this does

      setup do
        Samen.TestSandbox.shared!(MyApp.Repo)
        :ok
      end

  starts a DEDICATED owner (`Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: true)`), so every process the
  test spawns still sees the same connection, and registers an `on_exit` that stops that owner. ExUnit runs
  `on_exit` callbacks last-registered-first, and `shared!/1` registers in `setup`, so the owner outlives the test
  process AND every `on_exit` the test registered afterwards; stopping it rolls the sandbox back and the pool falls
  back to `:manual`. Nothing leaks into the next test.

  ## `auto!/1` — the rare test whose writes must COMMIT

  A test that needs committed rows (`pg_dump` sees only committed data) runs the pool in `:auto` mode: every process
  gets its own UNSANDBOXED connection and its writes are real. `:auto` has no owner whose exit ends it, so a raw
  `Sandbox.mode(repo, :auto)` lasts until something sets `:manual` again — a module that forgets leaves every later
  sync module on an unsandboxed pool. That happened (`jobs_starvation_isolation_test.exs`, issue #103: the next
  `TestSandboxTest` in the run failed all six setups, about 1 run in 40, depending on module order). `auto!/1`
  registers the switch back to `:manual`, so it cannot be forgotten. The test still deletes what it committed.

  `Samen.TestSandboxGuardTest` forbids a raw `Sandbox.mode(_, {:shared, _})` or `Sandbox.mode(_, :auto)` in any
  test file outside this module.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Own `repo` for this test in shared mode, and give the pool back (mode `:manual`) when the test exits.
  Returns the owner pid. Call it from `setup` / a test body, never from `setup_all`.
  """
  @spec shared!(module(), keyword()) :: pid()
  def shared!(repo, opts \\ []) do
    # `:on_exit` is a seam for the helper's own test (a recorder instead of ExUnit's registry)
    register = Keyword.get(opts, :on_exit, &ExUnit.Callbacks.on_exit/1)
    owner = Sandbox.start_owner!(repo, shared: true)
    register.(fn -> release(owner) end)
    owner
  end

  @doc """
  Run `repo`'s pool in `:auto` mode for this test — writes COMMIT — and put it back in `:manual` when the test exits.
  Call it from `setup` BEFORE registering any `on_exit` that cleans up committed rows: callbacks run
  last-registered-first, so the cleanup still has a connection when it runs.
  """
  @spec auto!(module(), keyword()) :: :ok
  def auto!(repo, opts \\ []) do
    # `:on_exit` is a seam for the helper's own test (a recorder instead of ExUnit's registry)
    register = Keyword.get(opts, :on_exit, &ExUnit.Callbacks.on_exit/1)
    :ok = Sandbox.mode(repo, :auto)
    register.(fn -> Sandbox.mode(repo, :manual) end)
    :ok
  end

  @doc "Stop a `shared!/1` owner (idempotent): rolls the sandbox back and restores `:manual` mode."
  @spec release(pid()) :: :ok
  def release(owner) do
    Sandbox.stop_owner(owner)
    :ok
  catch
    :exit, _ -> :ok
  end
end
