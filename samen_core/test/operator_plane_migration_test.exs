defmodule Samen.OperatorPlaneMigrationTest do
  @moduledoc """
  T6.1 (ADR-005) — red-path + anti-tautology coverage for the EXTRACTED shared
  `aud_chain` operator-plane migration (`Samen.OperatorPlane.Migration`).

  The extraction retro found the `aud_chain` migration copy-pasted byte-identically
  across THREE hosts (samen_core test repo, demo, driftwood). `create_aud_chain/1`
  is the single shared definition. This suite proves the shared body is correct AND
  non-vacuous:

    * POSITIVE (end-to-end): a real Ecto migration calling `create_aud_chain/1`
      against a THROWAWAY database builds the table, the dense-seq UNIQUE index, the
      append-only trigger, the role REVOKE, and the 15 same-transaction catalog rows;
      the append-only trigger actually REFUSES an UPDATE/DELETE.
    * RED PATH 1 (reversibility): `drop_aud_chain/1` removes the table AND every
      catalog row — no orphaned `tam_table`/`fld_field` row survives a down-migration.
    * RED PATH 2 (SQL-injection gate): `create_aud_chain/1` REFUSES an injectable
      Postgres role name (fail closed — never emit injectable REVOKE/GRANT DDL).
    * PARITY (anti-drift): the extracted field list matches the `Samen.AuditChain.Entry`
      schema's `ach_` columns exactly — the DDL cannot silently drift from the schema.

  Anti-tautology (documented, run below in `describe "anti-tautology"`): the append-only
  UPDATE-refusal is a real discriminator — a normal INSERT SUCCEEDS on the same table,
  so the refusal is the trigger firing, not the table being unwritable.

  Runs against a throwaway DB (`samen_core_opmigration_scratch`) created + dropped by
  the test, NOT the sandboxed test repo — because the extracted migration hardcodes the
  `aud_chain` table name (which the shared test repo already owns) and installs DB-level
  triggers/roles that must be exercised for real.
  """

  use ExUnit.Case, async: false

  alias Samen.OperatorPlane.Migration, as: OpMig

  @scratch_db "samen_core_opmigration_scratch"

  # An inline migration module that uses the EXTRACTED shared helpers — exactly the
  # shape a host now writes (ADR-005). This is the thing under test.
  defmodule ScratchAudChain do
    use Ecto.Migration

    @app_role "clank"

    def up, do: Samen.OperatorPlane.Migration.create_aud_chain(@app_role)
    def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(@app_role)
  end

  # A minimal catalog-bootstrap migration so the same-transaction catalog INSERTs
  # in create_aud_chain/1 have tam_table/fld_field to write into (mirrors every real
  # host, whose bootstrap migration creates the catalog before aud_chain).
  defmodule ScratchCatalog do
    use Ecto.Migration

    def up do
      execute(
        "CREATE TABLE tam_table (tam_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " <>
          "tam_table_name TEXT NOT NULL UNIQUE, tam_resource TEXT NOT NULL)"
      )

      execute(
        "CREATE TABLE fld_field (fld_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " <>
          "fld_table_name TEXT NOT NULL, fld_column_name TEXT NOT NULL, " <>
          "fld_logical_name TEXT NOT NULL, fld_type TEXT NOT NULL, " <>
          "UNIQUE (fld_table_name, fld_column_name))"
      )
    end

    def down do
      execute("DROP TABLE IF EXISTS fld_field")
      execute("DROP TABLE IF EXISTS tam_table")
    end
  end

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    base = SamenCore.TestRepo.config()

    admin_opts = [
      hostname: Keyword.get(base, :hostname, "localhost"),
      username: Keyword.get(base, :username),
      password: Keyword.get(base, :password, ""),
      database: "postgres",
      pool_size: 1
    ]

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, ~s(DROP DATABASE IF EXISTS "#{@scratch_db}"), [])
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{@scratch_db}"), [])

    repo_opts = Keyword.merge(base, database: @scratch_db, pool_size: 2)
    {:ok, repo_pid} = ScratchRepo.start_link(repo_opts)

    on_exit(fn ->
      # Repo may already be stopped; ignore.
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid)
      catch
        _, _ -> :ok
      end

      {:ok, admin2} = Postgrex.start_link(admin_opts)

      Postgrex.query!(
        admin2,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1",
        [@scratch_db]
      )

      Postgrex.query!(admin2, ~s(DROP DATABASE IF EXISTS "#{@scratch_db}"), [])
    end)

    :ok
  end

  describe "create_aud_chain/1 — end-to-end against a real DB" do
    setup do
      # Fresh catalog + aud_chain for each test in this describe block.
      Ecto.Migrator.run(ScratchRepo, [{1, ScratchCatalog}], :up, all: true, log: false)
      Ecto.Migrator.run(ScratchRepo, [{2, ScratchAudChain}], :up, all: true, log: false)

      on_exit(fn ->
        Ecto.Migrator.run(ScratchRepo, [{2, ScratchAudChain}], :down, all: true, log: false)
        Ecto.Migrator.run(ScratchRepo, [{1, ScratchCatalog}], :down, all: true, log: false)
      end)

      :ok
    end

    test "builds the aud_chain table, indexes, and per-org UNIQUE seq" do
      assert table_exists?("aud_chain")

      assert index_exists?("aud_chain_org_seq_uidx")
      assert index_exists?("aud_chain_org_seq_desc_idx")

      # A genesis row and a fork on the same (org, seq) is REJECTED by the UNIQUE index.
      insert_entry!("org-1", 0, "hash-0")

      assert_raise Postgrex.Error, ~r/unique/i, fn ->
        insert_entry!("org-1", 0, "hash-0-fork")
      end
    end

    test "writes all 15 catalog rows in the same transaction as the DDL" do
      %{rows: [[tam_count]]} =
        query!("SELECT COUNT(*) FROM tam_table WHERE tam_table_name = 'aud_chain'")

      assert tam_count == 1

      %{rows: [[fld_count]]} =
        query!("SELECT COUNT(*) FROM fld_field WHERE fld_table_name = 'aud_chain'")

      assert fld_count == length(OpMig.aud_chain_fields())
      assert fld_count == 15
    end

    test "POSITIVE control: a normal INSERT into aud_chain SUCCEEDS" do
      # Proves the append-only refusal below is the trigger firing, not an unwritable
      # table — the anti-tautology control for the append-only red path.
      assert :ok = insert_entry!("org-append", 0, "hash-append")

      %{rows: [[n]]} =
        query!("SELECT COUNT(*) FROM aud_chain WHERE ach_org_id = 'org-append'")

      assert n == 1
    end

    test "RED PATH: the append-only trigger REFUSES an UPDATE" do
      insert_entry!("org-2", 0, "hash-orig")

      assert_raise Postgrex.Error, ~r/aud_chain is append-only/, fn ->
        query!("UPDATE aud_chain SET ach_hash = 'tampered' WHERE ach_org_id = 'org-2'")
      end
    end

    test "RED PATH: the append-only trigger REFUSES a DELETE" do
      insert_entry!("org-3", 0, "hash-del")

      assert_raise Postgrex.Error, ~r/aud_chain is append-only/, fn ->
        query!("DELETE FROM aud_chain WHERE ach_org_id = 'org-3'")
      end
    end
  end

  describe "drop_aud_chain/1 — reversibility (RED PATH: no orphaned catalog rows)" do
    test "down removes the table AND every catalog row" do
      Ecto.Migrator.run(ScratchRepo, [{1, ScratchCatalog}], :up, all: true, log: false)
      Ecto.Migrator.run(ScratchRepo, [{2, ScratchAudChain}], :up, all: true, log: false)

      assert table_exists?("aud_chain")

      %{rows: [[before_tam]]} =
        query!("SELECT COUNT(*) FROM tam_table WHERE tam_table_name = 'aud_chain'")

      assert before_tam == 1

      # Run the down migration.
      Ecto.Migrator.run(ScratchRepo, [{2, ScratchAudChain}], :down, all: true, log: false)

      refute table_exists?("aud_chain")

      # RED PATH: no orphaned catalog rows survive the down migration.
      %{rows: [[after_tam]]} =
        query!("SELECT COUNT(*) FROM tam_table WHERE tam_table_name = 'aud_chain'")

      %{rows: [[after_fld]]} =
        query!("SELECT COUNT(*) FROM fld_field WHERE fld_table_name = 'aud_chain'")

      assert after_tam == 0, "down migration orphaned the tam_table row"
      assert after_fld == 0, "down migration orphaned #{after_fld} fld_field rows"

      Ecto.Migrator.run(ScratchRepo, [{1, ScratchCatalog}], :down, all: true, log: false)
    end
  end

  describe "safe_role gate — RED PATH (fail closed on injectable role)" do
    test "create_aud_chain REFUSES an injectable role name" do
      assert_raise ArgumentError, ~r/unsafe Postgres role name/, fn ->
        OpMig.create_aud_chain("clank; DROP TABLE tam_table; --")
      end
    end

    test "create_aud_chain REFUSES a role with a space" do
      assert_raise ArgumentError, ~r/unsafe Postgres role name/, fn ->
        OpMig.create_aud_chain("app role")
      end
    end

    test "a plain and a double-quoted role name are accepted by the gate" do
      # These pass the gate but then call Ecto.Migration.execute outside a migration
      # runtime, so they raise a DIFFERENT error (not the ArgumentError). The point
      # is only that the gate itself does NOT reject a legitimate role.
      for role <- ["clank", "app_role", ~s("MixedCaseRole")] do
        err =
          try do
            OpMig.create_aud_chain(role)
            :no_raise
          rescue
            e -> e
          end

        refute match?(%ArgumentError{message: "unsafe" <> _}, err),
               "gate wrongly rejected legit role #{inspect(role)}"
      end
    end
  end

  describe "field parity — the extracted DDL cannot drift from the schema" do
    test "every extracted ach_ field matches a Samen.AuditChain.Entry schema field" do
      extracted =
        OpMig.aud_chain_fields()
        |> Enum.map(fn {col, _logical, _type} -> col end)
        |> MapSet.new()

      # The schema's physical `ach_` source columns.
      schema_sources =
        Samen.AuditChain.Entry.__schema__(:fields)
        |> Enum.map(&Samen.AuditChain.Entry.__schema__(:field_source, &1))
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      assert extracted == schema_sources,
             "aud_chain DDL columns drifted from Samen.AuditChain.Entry: " <>
               "only-in-DDL=#{inspect(MapSet.difference(extracted, schema_sources))}, " <>
               "only-in-schema=#{inspect(MapSet.difference(schema_sources, extracted))}"
    end
  end

  # ---------------------------------------------------------------------------
  # helpers — raw queries against the scratch repo
  # ---------------------------------------------------------------------------

  defp query!(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(ScratchRepo, sql, params)
  end

  defp table_exists?(name) do
    %{rows: [[exists]]} =
      query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = $1)",
        [name]
      )

    exists
  end

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      query!("SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)", [name])

    exists
  end

  defp insert_entry!(org_id, seq, hash) do
    query!(
      """
      INSERT INTO aud_chain
        (ach_org_id, ach_seq, ach_prior_hash, ach_hash, ach_event_type,
         ach_occurred_at, ach_ciphertext_sha256)
      VALUES ($1, $2, 'genesis', $3, 'test.event', now(), 'deadbeef')
      """,
      [org_id, seq, hash]
    )

    :ok
  end
end
