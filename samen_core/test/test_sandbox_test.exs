defmodule Samen.TestSandboxTest do
  @moduledoc """
  ADR-053 P5 — `Samen.TestSandbox.shared!/1` gives a test a shared sandbox connection whose owner OUTLIVES the test
  process. The raw `checkout/1` + `mode(repo, {:shared, self()})` pair made the test process the owner, so an
  `on_exit` callback or a late async process failed with `** (EXIT) shutdown: "owner … exited"`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SamenCore.TestRepo

  # One query from a process that never checked out. -> :ok (the pool is shared, or :auto) | :no_connection
  # (OwnershipError, pool is :manual) | :owner_exited (the shared owner is gone: the flake)
  defp stranger do
    {pid, ref} =
      spawn_monitor(fn ->
        try do
          TestRepo.query!("select 1")
          exit({:shutdown, :ok})
        rescue
          DBConnection.OwnershipError -> exit({:shutdown, :no_connection})
        end
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:shutdown, tag}} when is_atom(tag) -> tag
      {:DOWN, ^ref, :process, ^pid, {{:shutdown, msg}, _}} when is_binary(msg) -> :owner_exited
    after
      5_000 -> :timeout
    end
  end

  # Runs `fun` with the pool in :auto (writes commit), then puts it back in :manual — `auto!/2`'s own callback, run
  # here instead of at test exit.
  defp with_auto(fun) do
    Samen.TestSandbox.auto!(TestRepo, on_exit: &send(self(), {:restore, &1}))

    receive do
      {:restore, restore} ->
        try do
          fun.()
        after
          restore.()
        end
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # every test starts from a pool in :manual mode: an earlier test that left it otherwise fails the NEXT test. Sync
  # modules run one at a time, so "earlier" can be any sync module since the last reset, not just the one before.
  setup do
    assert eventually(fn -> stranger() == :no_connection end),
           "the pool is not in :manual mode when this test starts: an earlier sync test left it shared (an owner " <>
             "still alive) or in :auto (a raw `Sandbox.mode(repo, :auto)` never switched back, issue #103)"

    :ok
  end

  test "shared!/1: a process the test spawns sees the test's connection and data (positive control)" do
    Samen.TestSandbox.shared!(TestRepo)
    TestRepo.query!("create temp table p5_probe (n int)")
    TestRepo.query!("insert into p5_probe values (1)")

    assert Task.async(fn -> TestRepo.query!("select count(*) from p5_probe").rows end)
           |> Task.await() == [[1]]

    assert stranger() == :ok
  end

  test "the owner outlives the test process: an on_exit callback registered later still reaches the database" do
    Samen.TestSandbox.shared!(TestRepo)

    on_exit(fn ->
      # runs AFTER the test process exited, BEFORE the owner is stopped (callbacks run last-registered-first); a
      # raise here fails this test
      assert TestRepo.query!("select 1").rows == [[1]]
    end)

    assert stranger() == :ok
  end

  test "the raw pair this helper replaces: the SAME on_exit query dies with 'owner exited' (why the helper exists)" do
    :ok = Sandbox.checkout(TestRepo)
    Sandbox.mode(TestRepo, {:shared, self()})

    on_exit(fn ->
      reached =
        try do
          TestRepo.query!("select 1")
          :reached
        catch
          :exit, {{:shutdown, "owner " <> _}, _} -> :owner_exited
        end

      assert reached == :owner_exited
    end)
  end

  test "shared!/2 registers its own release - running it hands the pool back in :manual mode" do
    recorder = fn callback -> send(self(), {:registered, callback}) end
    owner = Samen.TestSandbox.shared!(TestRepo, on_exit: recorder)

    assert_received {:registered, callback}
    assert is_function(callback, 0)
    assert stranger() == :ok

    callback.()
    assert eventually(fn -> stranger() == :no_connection end)
    refute Process.alive?(owner)
  end

  test "release/1 returns the pool to :manual and is idempotent" do
    owner = Samen.TestSandbox.shared!(TestRepo)
    assert stranger() == :ok

    assert Samen.TestSandbox.release(owner) == :ok

    assert eventually(fn -> stranger() == :no_connection end),
           "the pool is still shared after the owner was released"

    assert Samen.TestSandbox.release(owner) == :ok
  end

  test "auto!/2 lets any process reach the database, and its registered callback hands the pool back in :manual" do
    recorder = fn callback -> send(self(), {:registered, callback}) end
    assert Samen.TestSandbox.auto!(TestRepo, on_exit: recorder) == :ok

    assert_received {:registered, callback}
    assert is_function(callback, 0)
    assert stranger() == :ok

    callback.()
    assert stranger() == :no_connection
  end

  test "auto!/1's writes commit: a row inserted under it is still there after the pool is back in :manual" do
    with_auto(fn ->
      TestRepo.query!("create table p5_auto_probe (n int)")
      TestRepo.query!("insert into p5_auto_probe values (1)")
    end)

    try do
      # a sandboxed owner (its own transaction, rolled back) sees the committed row
      owner = Samen.TestSandbox.shared!(TestRepo)
      rows = TestRepo.query!("select n from p5_auto_probe").rows
      Samen.TestSandbox.release(owner)
      assert rows == [[1]]
    after
      with_auto(fn -> TestRepo.query!("drop table if exists p5_auto_probe") end)
    end
  end

  test "a released owner's data is rolled back" do
    owner = Samen.TestSandbox.shared!(TestRepo)
    TestRepo.query!("create temp table p5_gone (n int)")
    Samen.TestSandbox.release(owner)

    assert eventually(fn -> stranger() == :no_connection end)
    Samen.TestSandbox.shared!(TestRepo)
    assert_raise Postgrex.Error, ~r/p5_gone/, fn -> TestRepo.query!("select * from p5_gone") end
  end
end
