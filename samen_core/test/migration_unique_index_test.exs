defmodule Samen.MigrationUniqueIndexTest do
  @moduledoc """
  `concurrent_unique_index/3` — the retrofit for an invariant a lookup assumes (one row per credential digest).

  Run for real against a scratch database through `Ecto.Migrator`, the way a host's deploy runs it: the unique index
  is built `CONCURRENTLY` on a populated table, a duplicate is then refused by the database (positive control: a
  distinct value is not), and a table that ALREADY holds a duplicate makes the migration fail loudly, naming the table
  and the column, deleting nothing, leaving no index and printing no value. The migration text lives under
  `System.tmp_dir!()`, removed on exit.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  @table "uq_key"
  @index "uq_key_token_digest_uidx"

  setup do
    base = Repo.config()
    db = "#{Keyword.fetch!(base, :database)}_scratch_uqidx_#{:rand.uniform(1_000_000)}"
    config = base |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 5) |> Keyword.put(:database, db)

    dir = Path.join(System.tmp_dir!(), "samen_uq_migrations_#{System.unique_integer([:positive])}")

    :ok = Samen.TestDb.reset!(config)

    # registered right after the create, so a failure below can never leave the scratch database behind
    on_exit(fn ->
      File.rm_rf!(dir)
      Samen.TestDb.drop!(config)
    end)

    start_supervised!({ScratchRepo, config})
    File.mkdir_p!(dir)

    ScratchRepo.query!("CREATE TABLE #{@table} (id serial PRIMARY KEY, token_digest text)", [])

    %{dir: dir}
  end

  defp write_migration!(dir, version, tag) do
    File.write!(Path.join(dir, "#{version}_unique_#{tag}.exs"), """
    defmodule Samen.MigrationUniqueIndexTest.Mig#{tag} do
      use Samen.Migration, phase: :expand
      @disable_ddl_transaction true
      @disable_migration_lock true

      def up, do: concurrent_unique_index(:#{@table}, :token_digest, name: "#{@index}")
      def down, do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    end
    """)
  end

  defp migrate!(dir, direction \\ :up) do
    prev = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(ScratchRepo, dir, direction, all: true, log: false, migration_lock: false)
    after
      Code.put_compiler_option(:ignore_module_conflict, prev || false)
    end
  end

  defp insert(digest), do: ScratchRepo.query(~s|INSERT INTO #{@table} (token_digest) VALUES ($1)|, [digest])

  defp index_state do
    ScratchRepo.query!(
      "SELECT i.indisunique, i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
      [@index]
    ).rows
  end

  @tag timeout: 120_000
  test "builds a unique index on a populated table: a duplicate digest is refused, a distinct one is not", %{dir: dir} do
    for d <- ["a", "b", "c"], do: {:ok, _} = insert(d)
    write_migration!(dir, 20_261_119_000_001, "Build")

    migrate!(dir)

    assert index_state() == [[true, true]]
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = insert("a")
    # positive control: the refusal is about the duplicate, not about inserting
    assert {:ok, _} = insert("d")
    # NULLs are not duplicates of each other (a column that allows NULL keeps allowing it)
    assert {:ok, _} = insert(nil)
    assert {:ok, _} = insert(nil)
  end

  @tag timeout: 120_000
  test "the migration is idempotent and reversible", %{dir: dir} do
    {:ok, _} = insert("a")
    write_migration!(dir, 20_261_119_000_002, "Idem")

    migrate!(dir)
    ScratchRepo.query!("DELETE FROM schema_migrations", [])
    migrate!(dir)
    assert index_state() == [[true, true]]

    migrate!(dir, :down)
    assert index_state() == []
    assert {:ok, _} = insert("a")
  end

  @tag timeout: 120_000
  test "RED: existing duplicates fail the migration loudly, delete nothing, build nothing, print no digest", %{dir: dir} do
    for d <- ["secret-digest-1", "secret-digest-1", "secret-digest-2", "secret-digest-2", "secret-digest-3"],
        do: {:ok, _} = insert(d)

    write_migration!(dir, 20_261_119_000_003, "Dup")

    err = assert_raise RuntimeError, fn -> migrate!(dir) end

    assert err.message =~ "cannot build the unique index #{@index}"
    assert err.message =~ "#{@table}.token_digest holds 2 value(s) that appear more than once (4 rows)"
    assert err.message =~ "No row was deleted and index #{@index} was not built"
    refute err.message =~ "secret-digest"

    assert ScratchRepo.query!("SELECT count(*) FROM #{@table}", []).rows == [[5]]
    assert index_state() == []

    # positive control: once a person resolves the duplicates the same migration builds
    ScratchRepo.query!("DELETE FROM #{@table} WHERE id IN (SELECT max(id) FROM #{@table} GROUP BY token_digest HAVING count(*) > 1)", [])
    migrate!(dir)
    assert index_state() == [[true, true]]
  end

  @tag timeout: 120_000
  test "RED: a duplicate that lands between the pre-count and the build raises the same value-free message" do
    for d <- ["race-digest-1", "race-digest-1"], do: {:ok, _} = insert(d)

    err =
      assert_raise RuntimeError, fn ->
        Samen.Migration.ExpandContract.__build_unique_index__!(ScratchRepo, @table, "token_digest", @index)
      end

    assert err.message =~ "cannot build the unique index #{@index}"
    assert err.message =~ "#{@table}.token_digest gained a duplicate value"
    assert err.message =~ "INVALID index"
    assert err.message =~ "No row was deleted"
    refute err.message =~ "race-digest"

    # the leftover is invalid, and the next run (the migration, once the duplicate is resolved) drops it and builds
    assert index_state() == [[true, false]]
    ScratchRepo.query!("DELETE FROM #{@table} WHERE id IN (SELECT max(id) FROM #{@table} GROUP BY token_digest HAVING count(*) > 1)", [])
    dir = Path.join(System.tmp_dir!(), "samen_uq_race_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    write_migration!(dir, 20_261_119_000_004, "Race")
    migrate!(dir)
    assert index_state() == [[true, true]]
  end

  test "POSITIVE CONTROL: the build helper builds a valid unique index when there is no duplicate" do
    {:ok, _} = insert("a")
    assert :ok = Samen.Migration.ExpandContract.__build_unique_index__!(ScratchRepo, @table, "token_digest", @index)
    assert index_state() == [[true, true]]
  end

  test "the DDL-transaction guard applies: a migration that did not disable it is refused" do
    defmodule TxEnabled do
      def __migration__, do: [disable_ddl_transaction: false]
    end

    assert_raise RuntimeError, ~r/REQUIRE `@disable_ddl_transaction true`/, fn ->
      Samen.Migration.ExpandContract.concurrent_unique_index(:t, :c, name: "x", caller: TxEnabled)
    end
  end
end
