defmodule Samen.MigrationExpandContractTest do
  @moduledoc """
  T2.4: expand/contract migration tooling.

  Covers, with red paths + anti-tautology discrimination:

    * (a) additive expand helpers: `add_nullable_column` emits a reversible pair;
      `null: false` is rejected as non-additive.
    * (b) the DDL timeout posture: `expand_setup`/`contract_setup` emit
      `SET LOCAL lock_timeout='5s'` / `statement_timeout='15s'`; a live blocking-lock
      migration aborts fast at ~5s (RED PATH + anti-tautology: without the timeout it
      would hang).
    * (c) the carve-outs: `concurrent_index`/`chunked_backfill` REQUIRE
      `@disable_ddl_transaction true` and refuse otherwise; catalog_sync refuses
      UNDER it — proving the paired-migration composition (T1.2).
    * (d) `contract_ready?`: refuses before the bake window (RED PATH), runs after
      (anti-tautology: the same key with a long window is refused, with a short window
      is ready — the window is load-bearing, not the query).
    * the down/0 CI check catches an expand with a broken down (RED PATH via the
      `downcheck_broken` fixture) and passes the good fixture.
    * the OPT-IN `--min-expand` floor (`Mix.Tasks.Samen.Verify.Migrations.
      min_expand_violations/2`): floor declared and count 0 → violation naming
      `--min-expand`; floor declared and count meets it → no violation; no floor
      declared and count 0 → no violation (the opt-in property itself).
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Migration.ExpandContract
  alias Samen.Migration.Meta

  @good_migrations Path.expand("fixtures/downcheck_good", __DIR__)
  @broken_migrations Path.expand("fixtures/downcheck_broken", __DIR__)
  @layered_migrations Path.expand("fixtures/downcheck_layered", __DIR__)
  @none_migrations Path.expand("fixtures/downcheck_none", __DIR__)
  @carveout_migrations Path.expand("fixtures/carveouts", __DIR__)

  # ---------------------------------------------------------------------------
  # (a) Additive expand helpers
  # ---------------------------------------------------------------------------

  describe "add_nullable_column" do
    test "rejects null: false as non-additive (contract-phase op)" do
      assert_raise ArgumentError, ~r/not additive/, fn ->
        ExpandContract.add_nullable_column(:some_table, :some_col, :text, null: false)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (b) DDL timeout posture — emitted-SQL assertion (guards value drift)
  # ---------------------------------------------------------------------------

  describe "DDL timeout posture (emitted SQL)" do
    test "the posture emits exactly lock 5s / statement 15s (doc §runs 2b)" do
      {lock_sql, stmt_sql} = ExpandContract.__timeout_sql__()
      assert lock_sql == "SET LOCAL lock_timeout = '5s'"
      assert stmt_sql == "SET LOCAL statement_timeout = '15s'"
    end

    test "bake window conversion math is consistent" do
      {amount, unit} = Meta.bake_window()
      per = %{second: 1, minute: 60, hour: 3600, day: 86_400}
      assert Meta.bake_window_seconds() == amount * Map.fetch!(per, unit)
    end
  end

  # ---------------------------------------------------------------------------
  # (b') Raw diagnostic connections connect synchronously (flake F regression, T105)
  # ---------------------------------------------------------------------------

  describe "raw diagnostic connections are synchronously established (flake F, T105)" do
    test "start opts carry sync_connect, so the first query never races the async connect" do
      opts = raw_conn_opts()

      # Posture guard (RED-on-revert): remove `sync_connect: true` from the raw-conn opts
      # builder and this assertion is red. The class of raw-connection tests (vault/catalog/
      # prefixes/no-plaintext/agent-authoring/operator-plane migration) shared one race —
      # start_link connects asynchronously, so an immediate query could be dropped from the
      # checkout queue under suite load ("connection not available … dropped from queue").
      assert Keyword.get(opts, :sync_connect) == true,
             "raw diagnostic conns must block start_link until connected (flake F, T105)"

      # Behavioral proof (not a tautology): with sync_connect the connection is ready the
      # instant start_link returns, so a query under a HOSTILE 1ms checkout window still
      # serves. Reverting the fix (async connect) drops this checkout — the exact failure
      # observed at verify_vault_declared_parity_test:235 / this file's lock-abort test.
      {:ok, conn} = Postgrex.start_link(opts)

      try do
        assert %Postgrex.Result{rows: [[1]]} =
                 Postgrex.query!(conn, "SELECT 1", [], queue_target: 1, queue_interval: 1)
      after
        GenServer.stop(conn)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (b) Live blocking-lock: aborts fast at ~5s (RED PATH + anti-tautology)
  # ---------------------------------------------------------------------------

  describe "lock_timeout live abort" do
    test "a migration-style DDL under lock_timeout=5s aborts at ~5s instead of hanging" do
      # Two real (non-sandbox) Postgrex connections against a throwaway table so a
      # held lock is truly held (the sandbox wraps everything in one rolled-back tx,
      # which would deadlock a two-connection lock scenario).
      {a, b} = start_raw_conns()

      try do
        Postgrex.query!(a, "DROP TABLE IF EXISTS lock_probe", [])
        Postgrex.query!(a, "CREATE TABLE lock_probe (id int)", [])

        # Connection B holds an ACCESS EXCLUSIVE lock inside an open tx for 20s.
        holder = spawn_lock_holder(b, "lock_probe", 20_000)
        Process.sleep(300)

        # Connection A tries the same DDL WITH THE REAL POSTURE — the exact SQL the
        # expand/contract helpers emit (ExpandContract.__timeout_sql__/0), not a
        # hardcoded literal. This ties the test to the shipped 5s value so the
        # anti-tautology probe (sabotage @lock_timeout) actually breaks this test.
        {lock_sql, stmt_sql} = ExpandContract.__timeout_sql__()

        {elapsed_us, result} =
          :timer.tc(fn ->
            try do
              Postgrex.transaction(
                a,
                fn conn ->
                  Postgrex.query!(conn, lock_sql, [])
                  Postgrex.query!(conn, stmt_sql, [])
                  Postgrex.query!(conn, "ALTER TABLE lock_probe ADD COLUMN c text", [])
                end,
                timeout: 30_000
              )
            rescue
              e -> {:aborted, e}
            end
          end)

        elapsed_s = elapsed_us / 1_000_000

        assert match?({:aborted, _}, result),
               "expected the ALTER to abort under lock_timeout, got #{inspect(result)}"

        {:aborted, err} = result
        assert Exception.message(err) =~ ~r/lock timeout/i

        # ~5s: comfortably below the 20s hold. Proves fast-abort, not hang. If the
        # lock_timeout were disabled/large, this would block ~20s and fail here.
        assert elapsed_s < 12.0,
               "aborted in #{Float.round(elapsed_s, 2)}s — expected ~5s (fast abort), not a hang"

        # Above 3s: proves the lock WAS genuinely held (else the ALTER would have
        # succeeded instantly and the test would be vacuous).
        assert elapsed_s > 3.0,
               "aborted in #{Float.round(elapsed_s, 2)}s — suspiciously fast; the lock may not " <>
                 "have been held (test would be vacuous)"

        Process.exit(holder, :kill)
      after
        safe_query(a, "DROP TABLE IF EXISTS lock_probe")
        stop_raw_conns({a, b})
      end
    end

    test "ANTI-TAUTOLOGY: WITHOUT lock_timeout the same DDL blocks past 5s" do
      # The discriminating pair: hold the lock for 8s and set NO lock_timeout — the
      # ALTER must NOT complete by the 5.5s mark (it waits for the lock). This proves
      # the 5s abort above is caused by the timeout, not by the lock releasing early.
      {a, b} = start_raw_conns()

      try do
        Postgrex.query!(a, "DROP TABLE IF EXISTS lock_probe2", [])
        Postgrex.query!(a, "CREATE TABLE lock_probe2 (id int)", [])

        holder = spawn_lock_holder(b, "lock_probe2", 8_000)
        Process.sleep(300)

        alter_task =
          Task.async(fn ->
            :timer.tc(fn ->
              try do
                Postgrex.query!(a, "ALTER TABLE lock_probe2 ADD COLUMN c text", [], timeout: 30_000)
                :ok
              rescue
                e -> {:error, e}
              end
            end)
          end)

        # At 5.5s the holder still holds (8s hold); the un-timed ALTER must NOT be done.
        Process.sleep(5_500)

        refute Task.yield(alter_task, 0),
               "without lock_timeout the ALTER completed before 5.5s — the lock was not held, " <>
                 "so the 5s-abort test above would be vacuous"

        # Let it finish once the holder releases at ~8s.
        {elapsed_us, res} = Task.await(alter_task, 20_000)
        assert res == :ok, "expected the ALTER to eventually succeed once the lock released"

        assert elapsed_us / 1_000_000 > 5.0,
               "the un-timed ALTER completed too fast; the lock was not genuinely held"

        Process.exit(holder, :kill)
      after
        safe_query(a, "DROP TABLE IF EXISTS lock_probe2")
        stop_raw_conns({a, b})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (c) Carve-out guards: concurrent_index / chunked_backfill require disabled tx
  # ---------------------------------------------------------------------------

  describe "carve-out DDL-transaction guards" do
    defmodule TxEnabledMig do
      def __migration__, do: [disable_ddl_transaction: false]
    end

    defmodule TxDisabledMig do
      def __migration__, do: [disable_ddl_transaction: true]
    end

    test "concurrent_index refuses when the DDL transaction is NOT disabled" do
      assert_raise RuntimeError, ~r/REQUIRE `@disable_ddl_transaction true`/, fn ->
        ExpandContract.concurrent_index(:t, [:c], caller: TxEnabledMig)
      end
    end

    test "chunked_backfill refuses when the DDL transaction is NOT disabled" do
      assert_raise RuntimeError, ~r/REQUIRE `@disable_ddl_transaction true`/, fn ->
        ExpandContract.chunked_backfill(Repo, :t, "c = 1", column: :c, caller: TxEnabledMig)
      end
    end

    test "catalog_sync REFUSES under @disable_ddl_transaction true (T1.2 composition)" do
      # The other half of the paired-migration pattern: a concurrent-index migration
      # (disabled tx) cannot carry catalog rows. This is Gate-0 fix #4, re-asserted
      # here to document the composition explicitly.
      assert_raise RuntimeError, ~r/REFUSES to run under @disable_ddl_transaction true/, fn ->
        Samen.Migration.__guard_ddl_transaction__!(TxDisabledMig)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (d) contract_ready? — bake window gate (RED PATH + anti-tautology)
  # ---------------------------------------------------------------------------

  describe "contract_ready? bake-window gate" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      :ok
    end

    test "refuses when no expand row exists (fail-closed)" do
      key = "ck-none-#{System.unique_integer([:positive])}"
      assert {:not_ready, {:no_expand_row, ^key}} = ExpandContract.contract_ready?(Repo, key)
    end

    test "RED PATH: refuses immediately after expand (window not elapsed)" do
      key = seed_expand()
      # 1-day window (default): a just-written expand row cannot be ready.
      assert {:not_ready, {:baking, elapsed, window}} =
               ExpandContract.contract_ready?(Repo, key, bake_window: {1, :day})

      assert elapsed >= 0
      assert window == 86_400
    end

    test "ready once the window has elapsed" do
      key = seed_expand()
      # Backdate the expand row 10 seconds, use a 5s window → ready.
      backdate_expand(key, 10)
      assert {:ready, elapsed} = ExpandContract.contract_ready?(Repo, key, bake_window: {5, :second})
      assert elapsed >= 5
    end

    test "ANTI-TAUTOLOGY: the SAME baked row is refused under a longer window, ready under a shorter one" do
      # Discriminating pair on the SAME row and SAME query — only the WINDOW differs.
      # If the gate were vacuous (always ready), the long-window refusal would not
      # happen. If it always refused, the short-window ready would not happen.
      key = seed_expand()
      backdate_expand(key, 30)

      assert {:ready, _} = ExpandContract.contract_ready?(Repo, key, bake_window: {10, :second})

      assert {:not_ready, {:baking, _, _}} =
               ExpandContract.contract_ready?(Repo, key, bake_window: {1, :hour})
    end
  end

  # ---------------------------------------------------------------------------
  # down/0 CI check (RED PATH: broken-down expand fixture)
  # ---------------------------------------------------------------------------

  describe "down/0 CI check (Samen.Migration.DownCheck)" do
    test "GREEN: exercises a well-formed expand's down/0 in a scratch DB" do
      {repo, config} = start_scratch_repo("dc_good")

      try do
        assert {:ok, checked} = Samen.Migration.DownCheck.run(repo, @good_migrations, log: false)
        # The expand migration (v20260102000000) was exercised; the un-phased base was not.
        assert 20_260_102_000_000 in checked
        refute 20_260_101_000_000 in checked
      after
        stop_scratch_repo(repo, config)
      end
    end

    test "RED PATH: flags an expand whose down/0 is broken/irreversible" do
      {repo, config} = start_scratch_repo("dc_broken")

      try do
        assert {:error, violations} =
                 Samen.Migration.DownCheck.run(repo, @broken_migrations, log: false)

        assert Enum.any?(violations, &(&1 =~ ~r/down\/0 FAILED|not a clean round trip/))
        assert Enum.any?(violations, &(&1 =~ "expand_broken_down"))
      after
        stop_scratch_repo(repo, config)
      end
    end

    test "expand discovery reads the declared phase from source; skips un-phased" do
      good = Samen.Migration.DownCheck.expand_migrations(@good_migrations)
      assert length(good) == 1
      assert hd(good).phase == :expand
      assert hd(good).name =~ "expand_add_color"

      # The base (un-phased) migration is not discovered as an expand.
      base_file =
        Path.join(@good_migrations, "20260101000000_create_base.exs")

      assert Samen.Migration.DownCheck.phase_of_file(base_file) == nil
    end

    # REGRESSION (T3.1): a NON-expand migration layered on TOP of an expand (a
    # scope-mount migration with a later version, as AddIdentityScope did to the demo's
    # expand) must not defeat the down-check. The old `:down, step: 1` peeled the newer
    # non-expand migration; the `:down, to: version - 1` fix rolls down THROUGH the
    # expand regardless. This fixture reproduces the exact scenario that broke demo/ci.sh.
    test "GREEN: exercises an expand's down/0 with a NON-expand migration layered on top" do
      {repo, config} = start_scratch_repo("dc_layered")

      try do
        assert {:ok, checked} =
                 Samen.Migration.DownCheck.run(repo, @layered_migrations, log: false)

        # Only the expand (v…0102…) is exercised; the base and the layered-on-top
        # widget2 migration are un-phased and are NOT reported as checked expands.
        assert 20_260_102_000_000 in checked
        refute 20_260_101_000_000 in checked
        refute 20_260_103_000_000 in checked
      after
        stop_scratch_repo(repo, config)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # `--min-expand` floor (OPT-IN, per-gate) — pure, source-level, no scratch DB
  # ---------------------------------------------------------------------------

  describe "--min-expand floor (Mix.Tasks.Samen.Verify.Migrations.min_expand_violations/2)" do
    test "RED PATH: floor declared and discovered count is 0 -> violation naming --min-expand" do
      violations =
        Mix.Tasks.Samen.Verify.Migrations.min_expand_violations(@none_migrations, min_expand: 1)

      assert [violation] = violations
      assert violation =~ "--min-expand"
      assert violation =~ "observed 0"
      assert violation =~ "floor 1"
    end

    test "GREEN: floor declared and discovered count meets it -> no violation" do
      assert Mix.Tasks.Samen.Verify.Migrations.min_expand_violations(@good_migrations,
               min_expand: 1
             ) == []
    end

    test "GREEN (opt-in property): no floor declared and count is 0 -> no violation" do
      # This is the assertion an over-eager repo-wide fix breaks: absent the flag,
      # a zero-expand app must stay green — today's behaviour, byte-for-byte.
      assert Mix.Tasks.Samen.Verify.Migrations.min_expand_violations(@none_migrations, []) == []
    end
  end

  # ---------------------------------------------------------------------------
  # (c) Carve-outs run live: CONCURRENTLY build survives + chunked backfill fills
  # ---------------------------------------------------------------------------

  describe "carve-outs run outside the DDL transaction (live)" do
    @tag timeout: 120_000
    test "concurrent_index builds and chunked_backfill fills every row" do
      {repo, config} = start_scratch_repo("carveout")

      try do
        # `ignore_module_conflict` because the migrator recompiles fixtures per run.
        prev = Code.get_compiler_option(:ignore_module_conflict)
        Code.put_compiler_option(:ignore_module_conflict, true)

        try do
          # `migration_lock: false`: the Postgres advisory migration lock holds a
          # connection open for the whole run; a CREATE INDEX CONCURRENTLY build (its
          # own connection, outside any tx) can contend with it on a small scratch
          # pool and hang. Disabling the lock is safe here — a single test process is
          # the only migrator.
          Ecto.Migrator.run(repo, @carveout_migrations, :up,
            all: true,
            log: false,
            migration_lock: false
          )
        after
          Code.put_compiler_option(:ignore_module_conflict, prev || false)
        end

        # The CONCURRENTLY index survived the build (it exists).
        %{rows: idx_rows} =
          repo.query!(
            "SELECT indexname FROM pg_indexes WHERE tablename = 'cov_widget' " <>
              "AND indexname = 'cov_widget_name_cidx'",
            []
          )

        assert idx_rows == [["cov_widget_name_cidx"]]

        # The chunked backfill (chunk_size 10 over 25 rows → 3 chunks) filled every row.
        %{rows: [[unfilled]]} =
          repo.query!("SELECT count(*) FROM cov_widget WHERE cov_backfilled IS NULL", [])

        assert unfilled == 0

        %{rows: [[matched]]} =
          repo.query!("SELECT count(*) FROM cov_widget WHERE cov_backfilled = cov_name", [])

        assert matched == 25
      after
        stop_scratch_repo(repo, config)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_expand do
    key = "ck-#{System.unique_integer([:positive])}"

    Repo.query!(
      "INSERT INTO #{Meta.table()} (smm_change_key, smm_phase, smm_expanded_at, smm_migration) " <>
        "VALUES ($1, 'expand', now(), 'TestExpand')",
      [key]
    )

    key
  end

  defp backdate_expand(key, seconds) do
    Repo.query!(
      "UPDATE #{Meta.table()} SET smm_expanded_at = now() - ($2 || ' seconds')::interval " <>
        "WHERE smm_change_key = $1",
      [key, to_string(seconds)]
    )
  end

  # --- raw (non-sandbox) Postgrex connections for the live-lock test ---

  # Raw (non-sandbox) Postgrex connection opts. `sync_connect: true` blocks start_link
  # until the socket is established so the first query never races the async connect under
  # accumulated suite load (flake F, T105) — the sanctioned structural fix, not a margin.
  defp raw_conn_opts do
    base = Repo.config()

    [
      hostname: Keyword.get(base, :hostname, "localhost"),
      username: Keyword.get(base, :username),
      password: Keyword.get(base, :password, ""),
      database: Keyword.fetch!(base, :database),
      pool_size: 1,
      sync_connect: true
    ]
  end

  defp start_raw_conns do
    {:ok, a} = Postgrex.start_link(raw_conn_opts())
    {:ok, b} = Postgrex.start_link(raw_conn_opts())
    {a, b}
  end

  defp stop_raw_conns({a, b}) do
    GenServer.stop(a)
    GenServer.stop(b)
  end

  defp spawn_lock_holder(conn, table, hold_ms) do
    parent = self()

    holder =
      spawn(fn ->
        Postgrex.transaction(
          conn,
          fn c ->
            Postgrex.query!(c, "LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE", [])
            send(parent, :locked)
            Process.sleep(hold_ms)
          end,
          timeout: hold_ms + 10_000
        )
      end)

    # Wait until the lock is actually acquired before returning.
    receive do
      :locked -> :ok
    after
      5_000 -> raise "lock holder failed to acquire lock in 5s"
    end

    holder
  end

  defp safe_query(conn, sql) do
    try do
      Postgrex.query!(conn, sql, [])
    rescue
      _ -> :ok
    end
  end

  # --- scratch Ecto repo for the DownCheck tests ---

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  defp start_scratch_repo(suffix) do
    base = Repo.config()
    db = "#{Keyword.fetch!(base, :database)}_#{suffix}_#{:rand.uniform(1_000_000)}"

    config =
      base
      |> Keyword.delete(:pool)
      # A larger pool: the migrator holds an advisory-lock connection AND a
      # CONCURRENTLY build needs its own connection outside that transaction.
      |> Keyword.put(:pool_size, 5)
      |> Keyword.put(:database, db)

    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok = Ecto.Adapters.Postgres.storage_up(config)

    {:ok, _} = ScratchRepo.start_link(config)
    {ScratchRepo, config}
  end

  defp stop_scratch_repo(repo, config) do
    Supervisor.stop(repo)
    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok
  end
end
