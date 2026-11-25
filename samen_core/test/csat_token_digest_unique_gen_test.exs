defmodule Samen.CsatTokenDigestUniqueGenTest do
  @moduledoc """
  `mix samen.gen.csat_token_digest_unique` — the retrofit for an app generated BEFORE the CSAT survey-token digest was unique
  (its first migration made a plain `<table>_digest_idx`). Same engine as `mix samen.gen.api_key_digest_unique`
  (`Mix.Tasks.Samen.Gen.ApiKeyDigestUnique.run_kind/2`), different tables and one more duty: the plain index the unique one
  makes redundant is dropped, and `down` brings it back.

  Proven for real: the generated migration is run through `Ecto.Migrator` against a scratch database holding the table as the
  OLD first migration made it. It refuses existing duplicates without printing a digest, builds the unique index once they are
  resolved, replaces the plain one, and then the database refuses a duplicate (positive control: a distinct digest inserts);
  `down` restores the plain index and removes the unique one. Migration text and scratch databases live under
  `System.tmp_dir!()` / Postgres, removed on exit.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Gen.ApiKeyDigestUnique, as: Engine
  alias Mix.Tasks.Samen.Gen.CsatTokenDigestUnique, as: Task
  alias SamenCore.TestRepo, as: Repo

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  defmodule FixtureDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Samen.CsatTokenDigestUniqueGenTest.FixtureSurvey
      resource Samen.CsatTokenDigestUniqueGenTest.FixtureKey
    end
  end

  defmodule FixtureSurvey do
    use Ash.Resource, domain: FixtureDomain, data_layer: AshPostgres.DataLayer

    postgres do
      table "zzc_csat_survey_token"
      repo SamenCore.TestRepo
    end

    attributes do
      uuid_primary_key :id
      # the shape of a real Samen resource: logical `:token_digest`, only the STORED column carries the prefix
      attribute :token_digest, :string, source: :zzc_token_digest
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
      attribute :token_digest, :string, source: :zzk_token_digest
    end
  end

  @table "zzc_csat_survey_token"
  @column "zzc_token_digest"
  @unique "zzc_csat_survey_token_token_digest_uidx"
  @plain "zzc_csat_survey_token_digest_idx"

  setup do
    dir = Path.join(System.tmp_dir!(), "samen_csat_gen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp quiet(fun), do: ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, fun.()}) end) && receive(do: ({:result, r} -> r))

  describe "the generator" do
    test "writes one migration of literal SQL that builds each unique index, then drops the plain one it replaces", %{dir: dir} do
      keys = [{"b_csat_survey_token", "b_token_digest"}, {"a_csat_survey_token", "a_token_digest"}]
      path = quiet(fn -> Engine.generate(ScratchRepo, keys, dir, "20261120100000", :csat) end)

      assert path == Path.join(dir, "20261120100000_csat_token_digest_unique.exs")
      src = File.read!(path)
      assert src =~ "defmodule #{inspect(ScratchRepo)}.Migrations.CsatTokenDigestUnique20261120100000 do"
      assert src =~ ~s|concurrent_unique_index(:a_csat_survey_token, :a_token_digest, name: "a_csat_survey_token_token_digest_uidx")|
      assert src =~ ~s|concurrent_unique_index(:b_csat_survey_token, :b_token_digest, name: "b_csat_survey_token_token_digest_uidx")|
      assert src =~ ~s|execute("DROP INDEX CONCURRENTLY IF EXISTS a_csat_survey_token_digest_idx")|
      assert src =~ ~s|concurrent_index(:a_csat_survey_token, [:a_token_digest], name: "a_csat_survey_token_digest_idx")|
      assert src =~ "@disable_ddl_transaction true"
      assert src =~ "@disable_migration_lock true"
      assert [{mod, _}] = Code.compile_string(src)
      assert function_exported?(mod, :up, 0)
      assert function_exported?(mod, :down, 0)
      :code.purge(mod)
      :code.delete(mod)
    end

    test "the mix task runs the csat kind: its file, module and drop of the plain index; the API-key task keeps its own", %{dir: dir} do
      assert Mix.Task.task_name(Task) == "samen.gen.csat_token_digest_unique"

      args = ["--out", dir, "--timestamp", "20261120100000", "--key", "#{@table}:#{@column}"]
      path = quiet(fn -> Task.run(args) end)
      assert Path.basename(path) == "20261120100000_csat_token_digest_unique.exs"
      assert File.read!(path) =~ "Migrations.CsatTokenDigestUnique20261120100000"
      assert File.read!(path) =~ "DROP INDEX CONCURRENTLY IF EXISTS #{@plain}"

      assert_raise Mix.Error, ~r/mix samen.gen.csat_token_digest_unique: --key expects table:column/, fn ->
        quiet(fn -> Task.run(["--out", dir, "--key", "oops"]) end)
      end

      # the API-key task keeps its name, its file and its module name
      path = quiet(fn -> Engine.generate(ScratchRepo, [{"x_api_key", "x_token_digest"}], dir, "20261120100000") end)
      assert Path.basename(path) == "20261120100000_api_key_digest_unique.exs"
      assert File.read!(path) =~ "Migrations.ApiKeyDigestUnique20261120100000"
      refute File.read!(path) =~ "DROP INDEX CONCURRENTLY IF EXISTS x_api_key_digest_idx"
    end

    test "a re-run writes nothing (the index is already in the migrations)", %{dir: dir} do
      keys = [{@table, @column}]
      assert quiet(fn -> Engine.generate(ScratchRepo, keys, dir, "20261120100000", :csat) end)
      assert quiet(fn -> Engine.generate(ScratchRepo, keys, dir, "20261120100001", :csat) end) == nil
      assert length(Path.wildcard(Path.join(dir, "*.exs"))) == 1
    end

    test "a first migration that already creates the unique index (the current template) is skipped; another table is not", %{dir: dir} do
      File.write!(
        Path.join(dir, "20260101000000_mount.exs"),
        ~s|create(unique_index(:#{@table}, [:#{@column}], name: "#{@plain}"))\n|
      )

      assert quiet(fn -> Engine.generate(ScratchRepo, [{@table, @column}], dir, "20261120100000", :csat) end) == nil

      path =
        quiet(fn ->
          Engine.generate(ScratchRepo, [{@table, @column}, {"other_csat_survey_token", "other_token_digest"}], dir, "20261120100001", :csat)
        end)

      src = File.read!(path)
      assert src =~ "other_csat_survey_token"
      refute src =~ @table
    end

    test "the no-repo error names the task that was run, not the API-key task" do
      app = :samen_core
      prev = Application.get_env(app, :ecto_repos)
      Application.put_env(app, :ecto_repos, [])
      on_exit(fn -> Application.put_env(app, :ecto_repos, prev) end)

      assert_raise Mix.Error, ~r/^mix samen\.gen\.csat_token_digest_unique: no :ecto_repos configured/, fn -> quiet(fn -> Task.run([]) end) end

      assert_raise Mix.Error, ~r/^mix samen\.gen\.api_key_digest_unique: no :ecto_repos configured/, fn ->
        quiet(fn -> Mix.Tasks.Samen.Gen.ApiKeyDigestUnique.run([]) end)
      end
    end

    test "the skip logic recognises BOTH index names: the fresh app's template name and the retrofit's _uidx; a plain index is not a unique one", %{dir: dir} do
      File.write!(Path.join(dir, "20260101000000_fresh.exs"), ~s|create(unique_index(:a_csat_survey_token, [:a_token_digest], name: "a_csat_survey_token_digest_idx"))\n|)
      File.write!(Path.join(dir, "20260101000001_retro.exs"), ~s|concurrent_unique_index(:b_csat_survey_token, :b_token_digest, name: "b_csat_survey_token_token_digest_uidx")\n|)
      File.write!(Path.join(dir, "20260101000002_plain.exs"), ~s|create(index(:c_csat_survey_token, [:c_token_digest], name: "c_csat_survey_token_digest_idx"))\n|)

      keys = [{"a_csat_survey_token", "a_token_digest"}, {"b_csat_survey_token", "b_token_digest"}, {"c_csat_survey_token", "c_token_digest"}]
      path = quiet(fn -> Engine.generate(ScratchRepo, keys, dir, "20261120100000", :csat) end)
      src = File.read!(path)
      refute src =~ "a_csat_survey_token"
      refute src =~ "b_csat_survey_token"
      assert src =~ "c_csat_survey_token"
    end

    test "discovers a CSAT survey table and its digest column from a domain; API-key tables belong to the other kind" do
      # the STORED column, not the logical `:token_digest`
      assert Engine.discover([FixtureDomain], :csat) == [{@table, @column}]
      assert Engine.discover([FixtureDomain]) == [{"zzk_api_key", "zzk_token_digest"}]
      assert Engine.discover([], :csat) == []
    end
  end

  describe "the generated migration, run for real" do
    setup %{dir: dir} do
      base = Repo.config()
      db = "#{Keyword.fetch!(base, :database)}_scratch_csatgen_#{:rand.uniform(1_000_000)}"
      config = base |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 5) |> Keyword.put(:database, db)

      :ok = Samen.TestDb.reset!(config)
      on_exit(fn -> Samen.TestDb.drop!(config) end)
      start_supervised!({ScratchRepo, config})
      ScratchRepo.query!("CREATE TABLE #{@table} (id serial PRIMARY KEY, #{@column} text NOT NULL)", [])
      # the table as the OLD first migration made it: a plain, non-unique digest index
      ScratchRepo.query!("CREATE INDEX #{@plain} ON #{@table} (#{@column})", [])

      path = quiet(fn -> Engine.generate(ScratchRepo, [{@table, @column}], dir, "20261120100009", :csat) end)
      %{path: path}
    end

    defp migrate!(dir, direction \\ :up, opts \\ []) do
      prev = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      try do
        Ecto.Migrator.run(ScratchRepo, dir, direction, [all: true, log: false, migration_lock: false] ++ opts)
      after
        Code.put_compiler_option(:ignore_module_conflict, prev || false)
      end
    end

    defp insert(digest), do: ScratchRepo.query("INSERT INTO #{@table} (#{@column}) VALUES ($1)", [digest])

    defp index_state(name) do
      ScratchRepo.query!(
        "SELECT i.indisunique, i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
        [name]
      ).rows
    end

    @tag timeout: 120_000
    test "RED: existing duplicates fail it without printing a digest; once resolved it builds, replaces the plain index and the database refuses a duplicate; down restores",
         %{dir: dir} do
      for d <- ["old-secret-1", "old-secret-1", "old-secret-2"], do: {:ok, _} = insert(d)

      # PRE-STATE: the old schema accepts duplicates (the very gap this closes)
      assert index_state(@unique) == []
      assert index_state(@plain) == [[false, true]]

      err = assert_raise RuntimeError, fn -> migrate!(dir) end
      assert err.message =~ "cannot build the unique index #{@unique}"
      refute err.message =~ "old-secret"
      assert index_state(@unique) == []
      # nothing was dropped or deleted by the refusal
      assert index_state(@plain) == [[false, true]]
      assert ScratchRepo.query!("SELECT count(*) FROM #{@table}", []).rows == [[3]]

      ScratchRepo.query!("DELETE FROM #{@table} WHERE id = (SELECT max(id) FROM #{@table} WHERE #{@column} = 'old-secret-1')", [])
      migrate!(dir)

      assert index_state(@unique) == [[true, true]]
      assert index_state(@plain) == []
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = insert("old-secret-1")
      assert {:ok, _} = insert("a-distinct-digest")

      # reversible: the plain lookup index is back, the unique one is gone
      migrate!(dir, :down, all: false, step: 1)
      assert index_state(@unique) == []
      assert index_state(@plain) == [[false, true]]
    end
  end
end
