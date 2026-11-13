defmodule Samen.AuditChainConcurrencyTest do
  @moduledoc """
  ARCH-7 (eval 2026-11-13): concurrent appends to ONE org's chain must all land, densely and in
  order — with NO caller-supplied transaction.

  `tip_locked/2` used `SELECT ... FOR UPDATE` on the max-seq row, but `append/2` opened no
  transaction of its own, so in autocommit the row lock was released the moment the SELECT
  returned; and a fresh chain has no row to lock at all. Callers such as
  `Samen.Replay.Player.audit_viewed/…` and `Samen.Audit.ImpersonationEmit` call `Writer.write`
  with no surrounding transaction, so two concurrent writers read the same tip and the loser hit the
  `(org_id, seq)` unique index AFTER its `aud_event` row had already landed.

  These tests run real concurrent processes on REAL connections (no sandbox: a sandbox serialises
  everything onto one connection and cannot race). The chain is append-only by trigger and the app role
  cannot delete from it, and `AuditChainTest.seal_all` assumes the shared `public.aud_chain` holds only
  its own orgs — so the race runs in a THROWAWAY schema (own `aud_chain` table, index and trigger,
  created by the real `create_aud_chain/1`) that is dropped afterwards. Nothing is committed to `public`.
  """
  use ExUnit.Case, async: false

  alias Samen.AuditChain

  @writers 12
  @schema "aud_conc_" <> System.get_env("SAMEN_TEST_DB_SUFFIX", "x")

  defmodule Repo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  defmodule Mig do
    use Ecto.Migration
    def up, do: Samen.OperatorPlane.Migration.create_aud_chain(Samen.OperatorPlane.Migration.app_role!(:samen_core, SamenCore.TestRepo))
    def down, do: :ok
  end

  setup_all do
    base = Application.fetch_env!(:samen_core, SamenCore.TestRepo) |> Keyword.drop([:pool, :pool_size, :queue_target, :queue_interval])

    opts =
      base ++
        [
          name: Repo,
          pool_size: @writers + 4,
          log: false,
          after_connect: {Postgrex, :query!, ["SET search_path TO #{@schema}, public", []]}
        ]

    admin = fn sql ->
      {:ok, conn} = Postgrex.start_link(Keyword.take(base, [:username, :password, :hostname, :database]))
      Postgrex.query!(conn, sql, [])
      GenServer.stop(conn)
    end

    admin.("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
    admin.("CREATE SCHEMA #{@schema}")
    on_exit(fn -> admin.("DROP SCHEMA IF EXISTS #{@schema} CASCADE") end)

    start_supervised!(%{id: Repo, start: {Repo, :start_link, [opts]}})
    Ecto.Migrator.run(Repo, [{20_260_707_020_000, Mig}], :up, all: true, log: false)
    :ok
  end

  setup do
    {:ok, org: "org-conc-#{System.unique_integer([:positive])}-#{System.os_time(:microsecond)}"}
  end

  defp lost(results) do
    bad = Enum.reject(results, &match?({:ok, _}, &1))
    kinds = bad |> Enum.map(fn {:raised, e} -> inspect(e.__struct__); other -> inspect(other, limit: 3) end)
    "#{length(bad)}/#{length(results)} lost: #{inspect(Enum.uniq(kinds))}"
  end

  defp concurrently(n, fun) do
    1..n
    |> Enum.map(fn i ->
      Task.async(fn ->
        try do
          fun.(i)
        rescue
          e -> {:raised, e}
        end
      end)
    end)
    |> Task.await_many(30_000)
  end

  test "concurrent bare AuditChain.append on a FRESH chain: every append lands, seq dense", %{org: org} do
    results =
      concurrently(@writers, fn i ->
        AuditChain.append(%{org_id: org, event_type: "reveal", subject_id: "s-#{i}", actor_id: "a"}, repo: Repo)
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1)), lost(results)

    seqs = results |> Enum.map(fn {:ok, e} -> e.seq end) |> Enum.sort()
    assert seqs == Enum.to_list(0..(@writers - 1))
    assert {:ok, %{entries: @writers}} = AuditChain.verify_chain(org, repo: Repo)
  end

  test "concurrent bare appends onto an EXISTING chain also all land", %{org: org} do
    {:ok, _} = AuditChain.append(%{org_id: org, event_type: "reveal", subject_id: "seed", actor_id: "a"}, repo: Repo)

    results =
      concurrently(@writers, fn i ->
        AuditChain.append(%{org_id: org, event_type: "reveal", subject_id: "s-#{i}", actor_id: "a"}, repo: Repo)
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1)), lost(results)
    assert {:ok, %{entries: n}} = AuditChain.verify_chain(org, repo: Repo)
    assert n == @writers + 1
  end

  test "different orgs do not serialize on each other (the lock is per org)" do
    orgs = for i <- 1..4, do: "org-conc-iso-#{i}-#{System.os_time(:microsecond)}"

    results =
      concurrently(8, fn i ->
        org = Enum.at(orgs, rem(i, 4))
        AuditChain.append(%{org_id: org, event_type: "reveal", subject_id: "x-#{i}", actor_id: "a"}, repo: Repo)
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    for org <- orgs, do: assert({:ok, %{entries: 2}} = AuditChain.verify_chain(org, repo: Repo))
  end
end
