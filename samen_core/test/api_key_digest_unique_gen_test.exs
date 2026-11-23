defmodule Samen.ApiKeyDigestUniqueGenTest do
  @moduledoc """
  `mix samen.gen.api_key_digest_unique` — the retrofit for an app generated BEFORE the API-key token digest was unique.

  Proven for real: the generated migration is run through `Ecto.Migrator` against a scratch database holding the table as the
  OLD first migration made it (a plain, non-unique digest column). It refuses existing duplicates without printing a digest,
  builds the unique index once they are resolved, and then the database refuses a duplicate (positive control: a distinct
  digest inserts). A re-run writes nothing (the index is in the migrations), and so does a first migration that already
  creates the unique index. Migration text and scratch databases live under `System.tmp_dir!()` / Postgres, removed on exit.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Gen.ApiKeyDigestUnique, as: Task
  alias SamenCore.TestRepo, as: Repo

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  defmodule FixtureDomain do
    use Ash.Domain, validate_config_inclusion?: false
    resources do
      resource Samen.ApiKeyDigestUniqueGenTest.FixtureKey
    end
  end

  defmodule FixtureKey do
    use Ash.Resource, domain: FixtureDomain, data_layer: AshPostgres.DataLayer

    postgres do
      table "zzk_api_key"
      repo SamenCore.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :zzk_token_digest, :string
    end
  end

  @table "zzk_api_key"
  @column "zzk_token_digest"
  @index "zzk_api_key_token_digest_uidx"

  setup do
    dir = Path.join(System.tmp_dir!(), "samen_akd_gen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp quiet(fun), do: ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, fun.()}) end) && receive(do: ({:result, r} -> r))

  describe "the generator" do
    test "writes one migration of literal SQL for the keys, with a unique module name", %{dir: dir} do
      path = quiet(fn -> Task.generate(ScratchRepo, [{"b_api_key", "b_token_digest"}, {"a_api_key", "a_token_digest"}], dir, "20261120100000") end)

      assert path == Path.join(dir, "20261120100000_api_key_digest_unique.exs")
      src = File.read!(path)
      assert src =~ "defmodule #{inspect(ScratchRepo)}.Migrations.ApiKeyDigestUnique20261120100000 do"
      assert src =~ ~s|concurrent_unique_index(:a_api_key, :a_token_digest, name: "a_api_key_token_digest_uidx")|
      assert src =~ ~s|concurrent_unique_index(:b_api_key, :b_token_digest, name: "b_api_key_token_digest_uidx")|
      assert src =~ ~s|DROP INDEX CONCURRENTLY IF EXISTS b_api_key_token_digest_uidx|
      assert src =~ "@disable_ddl_transaction true"
      assert src =~ "@disable_migration_lock true"
      # parses and compiles
      assert [{mod, _}] = Code.compile_string(src)
      assert function_exported?(mod, :up, 0)
      :code.purge(mod)
      :code.delete(mod)
    end

    test "a re-run writes nothing (the index is already in the migrations)", %{dir: dir} do
      keys = [{@table, @column}]
      assert quiet(fn -> Task.generate(ScratchRepo, keys, dir, "20261120100000") end)
      assert quiet(fn -> Task.generate(ScratchRepo, keys, dir, "20261120100001") end) == nil
      assert length(Path.wildcard(Path.join(dir, "*.exs"))) == 1
    end

    test "a first migration that already creates the unique index is skipped; another table is not", %{dir: dir} do
      File.write!(Path.join(dir, "20260101000000_mount.exs"), "create(unique_index(:#{@table}, [:#{@column}]))\n")
      assert quiet(fn -> Task.generate(ScratchRepo, [{@table, @column}], dir, "20261120100000") end) == nil

      path = quiet(fn -> Task.generate(ScratchRepo, [{@table, @column}, {"other_api_key", "other_token_digest"}], dir, "20261120100001") end)
      src = File.read!(path)
      assert src =~ "other_api_key"
      refute src =~ @table
    end

    test "discovers an API-key table and its digest column from a domain; ignores other tables" do
      assert Task.discover([FixtureDomain]) == [{@table, @column}]
      assert Task.discover([]) == []
    end
  end

  describe "the generated migration, run for real" do
    setup %{dir: dir} do
      base = Repo.config()
      db = "#{Keyword.fetch!(base, :database)}_akdgen_#{:rand.uniform(1_000_000)}"
      config = base |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 5) |> Keyword.put(:database, db)

      :ok = Samen.TestDb.reset!(config)
      on_exit(fn -> Samen.TestDb.drop!(config) end)
      repo = start_supervised!({ScratchRepo, config})
      ScratchRepo.query!("CREATE TABLE #{@table} (id serial PRIMARY KEY, #{@column} text NOT NULL)", [])
      ScratchRepo.query!("CREATE INDEX #{@table}_#{@column}_index ON #{@table} (#{@column})", [])
      _ = repo

      path = quiet(fn -> Task.generate(ScratchRepo, [{@table, @column}], dir, "20261120100009") end)
      %{path: path}
    end

    defp migrate!(dir) do
      prev = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      try do
        Ecto.Migrator.run(ScratchRepo, dir, :up, all: true, log: false, migration_lock: false)
      after
        Code.put_compiler_option(:ignore_module_conflict, prev || false)
      end
    end

    defp insert(digest), do: ScratchRepo.query("INSERT INTO #{@table} (#{@column}) VALUES ($1)", [digest])

    defp index_state do
      ScratchRepo.query!(
        "SELECT i.indisunique, i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
        [@index]
      ).rows
    end

    @tag timeout: 120_000
    test "RED: existing duplicates fail it without printing a digest; once resolved it builds and the database refuses a duplicate",
         %{dir: dir} do
      for d <- ["old-secret-1", "old-secret-1", "old-secret-2"], do: {:ok, _} = insert(d)

      # PRE-STATE: the old schema accepts duplicates (the very gap this closes)
      assert index_state() == []

      err = assert_raise RuntimeError, fn -> migrate!(dir) end
      assert err.message =~ "cannot build the unique index #{@index}"
      refute err.message =~ "old-secret"
      assert index_state() == []
      assert ScratchRepo.query!("SELECT count(*) FROM #{@table}", []).rows == [[3]]

      ScratchRepo.query!("DELETE FROM #{@table} WHERE id = (SELECT max(id) FROM #{@table} WHERE #{@column} = 'old-secret-1')", [])
      migrate!(dir)

      assert index_state() == [[true, true]]
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = insert("old-secret-1")
      assert {:ok, _} = insert("a-distinct-digest")
    end
  end
end
