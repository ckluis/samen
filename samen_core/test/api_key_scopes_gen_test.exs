defmodule Samen.ApiKeyScopesGenTest do
  @moduledoc """
  `mix samen.gen.api_key_scopes` — the data step that gives every existing API key with empty scopes the authority its minter role
  already granted (owner, admin, member: all read and write; viewer: all read), before scopes are enforced and an empty set authorizes
  nothing.

  Proven for real: the generated migration is run through `Ecto.Migrator` against a scratch database holding a key table as the old
  schema made it. Keys with scopes already, and keys with no known minter role, are left alone (controls); a second run changes
  nothing. Migration text and scratch databases live under `System.tmp_dir!()` / Postgres, removed on exit.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Gen.ApiKeyScopes, as: Task
  alias SamenCore.TestRepo, as: Repo

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  defmodule FixtureDomain do
    use Ash.Domain, validate_config_inclusion?: false
    resources do
      resource Samen.ApiKeyScopesGenTest.FixtureKey
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
      # the shape of a real Samen resource: logical names, only the STORED columns carry the prefix
      attribute :scopes, :map, source: :zzk_scopes
      attribute :minter_role, :atom, source: :zzk_minter_role
    end
  end

  @table "zzk_api_key"
  @scopes "zzk_scopes"
  @role "zzk_minter_role"

  setup do
    dir = Path.join(System.tmp_dir!(), "samen_aks_gen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp quiet(fun), do: ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, fun.()}) end) && receive(do: ({:result, r} -> r))

  describe "the generator" do
    test "writes one migration of literal SQL for the keys, with a unique module name", %{dir: dir} do
      path = quiet(fn -> Task.generate(ScratchRepo, [{"b_api_key", "b_scopes", "b_minter_role"}, {"a_api_key", "a_scopes", "a_minter_role"}], dir, "20261127100000") end)

      assert path == Path.join(dir, "20261127100000_api_key_scopes.exs")
      src = File.read!(path)
      assert src =~ "defmodule #{inspect(ScratchRepo)}.Migrations.ApiKeyScopes20261127100000 do"
      assert src =~ ~s|a_scopes = '{"all":["read","write"]}'::jsonb|
      assert src =~ ~s|a_minter_role IN ('owner', 'admin', 'member')|
      assert src =~ ~s|b_scopes = '{"all":["read"]}'::jsonb|
      assert src =~ ~s|b_minter_role = 'viewer'|
      assert src =~ "@disable_ddl_transaction true"
      assert [{mod, _}] = Code.compile_string(src)
      assert function_exported?(mod, :up, 0)
      :code.purge(mod)
      :code.delete(mod)
    end

    test "a re-run writes nothing (the table is already backfilled by a migration there)", %{dir: dir} do
      keys = [{@table, @scopes, @role}]
      assert quiet(fn -> Task.generate(ScratchRepo, keys, dir, "20261127100000") end)
      assert quiet(fn -> Task.generate(ScratchRepo, keys, dir, "20261127100001") end) == nil
      assert length(Path.wildcard(Path.join(dir, "*.exs"))) == 1
    end

    test "another table is still written when one is already backfilled", %{dir: dir} do
      assert quiet(fn -> Task.generate(ScratchRepo, [{@table, @scopes, @role}], dir, "20261127100000") end)
      path = quiet(fn -> Task.generate(ScratchRepo, [{@table, @scopes, @role}, {"other_api_key", "other_scopes", "other_minter_role"}], dir, "20261127100001") end)
      src = File.read!(path)
      assert src =~ "other_api_key"
      refute src =~ @table
    end

    test "discovers an API-key table with its STORED scopes and role columns from a domain; ignores other tables" do
      assert Task.discover([FixtureDomain]) == [{@table, @scopes, @role}]
      assert Task.discover([]) == []
    end
  end

  describe "the generated migration, run for real" do
    setup %{dir: dir} do
      base = Repo.config()
      db = "#{Keyword.fetch!(base, :database)}_scratch_aksgen_#{:rand.uniform(1_000_000)}"
      config = base |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 5) |> Keyword.put(:database, db)

      :ok = Samen.TestDb.reset!(config)
      on_exit(fn -> Samen.TestDb.drop!(config) end)
      _ = start_supervised!({ScratchRepo, config})

      ScratchRepo.query!(
        "CREATE TABLE #{@table} (id serial PRIMARY KEY, #{@scopes} jsonb DEFAULT '{}'::jsonb, #{@role} text)",
        []
      )

      assert quiet(fn -> Task.generate(ScratchRepo, [{@table, @scopes, @role}], dir, "20261127100009") end)
      :ok
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

    defp insert(role, scopes), do: ScratchRepo.query!("INSERT INTO #{@table} (#{@role}, #{@scopes}) VALUES ($1, $2::text::jsonb)", [role, scopes])
    defp insert_null_scopes(role), do: ScratchRepo.query!("INSERT INTO #{@table} (#{@role}, #{@scopes}) VALUES ($1, NULL)", [role])

    defp scopes_by_role do
      ScratchRepo.query!("SELECT coalesce(#{@role}, '(none)'), #{@scopes}::text FROM #{@table} ORDER BY id", []).rows
    end

    @tag timeout: 120_000
    test "RED: backfill gives a viewer-minted key read only; CONTROL: owner, admin and member keys get read and write", %{dir: dir} do
      for role <- ["owner", "admin", "member", "viewer"], do: insert(role, "{}")
      insert_null_scopes("member")

      migrate!(dir)

      rows = Map.new(Enum.take(scopes_by_role(), 4), fn [role, scopes] -> {role, scopes} end)
      assert Jason.decode!(rows["viewer"]) == %{"all" => ["read"]}
      for role <- ["owner", "admin", "member"], do: assert(Jason.decode!(rows[role]) == %{"all" => ["read", "write"]})
      assert [_, ["member", member_null]] = Enum.drop(scopes_by_role(), 3)
      assert Jason.decode!(member_null) == %{"all" => ["read", "write"]}
    end

    @tag timeout: 120_000
    test "a key that has scopes, or no known minter role, is not touched; a second run changes nothing", %{dir: dir} do
      insert("admin", ~s({"crm.contact":["read"]}))
      insert("viewer", ~s({"billing":["read"]}))
      insert(nil, "{}")
      insert("janitor", "{}")
      insert("member", "{}")

      migrate!(dir)
      first = scopes_by_role()

      assert [["admin", ~s({"crm.contact": ["read"]})], ["viewer", ~s({"billing": ["read"]})], ["(none)", "{}"], ["janitor", "{}"], ["member", granted]] = first
      assert Jason.decode!(granted) == %{"all" => ["read", "write"]}

      # run the same migration again (forget that it ran): nothing is left to match, nothing changes
      ScratchRepo.query!("DELETE FROM schema_migrations", [])
      migrate!(dir)
      assert scopes_by_role() == first
    end
  end
end
