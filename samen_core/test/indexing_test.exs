defmodule Samen.IndexingTest.Bare do
  @moduledoc false
  use Ash.Resource,
    domain: Samen.IndexingTest.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("ix_bare")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end

defmodule Samen.IndexingTest.Ghost do
  @moduledoc "Org-scoped, but its table is never created: the verifier cannot inspect it."
  use Ash.Resource,
    domain: Samen.IndexingTest.GhostDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("ix_ghost_absent")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end

defmodule Samen.IndexingTest.NoOrg do
  @moduledoc "No org_id at all: not org-scoped, never inspected."
  use Ash.Resource,
    domain: Samen.IndexingTest.NoOrgDomain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("ix_no_org")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end
end

defmodule Samen.IndexingTest.Sortable do
  @moduledoc """
  Org-scoped, with two candidate sort columns. It carries no `keyset_sort` of its own: the tests
  say which sort the contract should assume (`keyset_sorts:`), standing in for a resource whose
  declaration changed between two deploys.
  """
  use Ash.Resource,
    domain: Samen.IndexingTest.SortableDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("ix_sortable")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, allow_nil?: false, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:note, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end

defmodule Samen.IndexingTest.SortableDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.IndexingTest.Sortable)
  end
end

defmodule Samen.IndexingTest.InvalidLeftoverMigration do
  @moduledoc "A literal retrofit migration over a table whose same-named index build once failed."
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [{"ix_leftover", ["org_id", "name", "id"], "ix_leftover_org_name_id_idx"}]

  def up, do: create_org_keyset_indexes(@indexes, concurrently: true)
  def down, do: drop_org_keyset_indexes(@indexes, concurrently: true)
end

defmodule Samen.IndexingTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.IndexingTest.Bare)
  end
end

defmodule Samen.IndexingTest.GhostDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.IndexingTest.Ghost)
  end
end

defmodule Samen.IndexingTest.NoOrgDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.IndexingTest.NoOrg)
  end
end

defmodule Samen.IndexingTest do
  @moduledoc """
  ARCH-4 — `Samen.Indexing` (the index contract) and `mix samen.verify.indexes` (its verifier).

  The load-bearing pairs (anti-tautology): a resource whose migrated table carries the index is
  CLEAN, and the same assertion goes red once the index is dropped inside the test transaction;
  a resource the verifier cannot inspect is a violation, never a pass.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.Samen.Verify.Indexes
  alias Samen.Indexing
  alias Samen.IndexingTest.{Bare, Ghost, NoOrg}
  alias SamenCore.Support.CrmScopeFixture
  alias SamenCore.Support.WorkFixture

  @repo SamenCore.TestRepo
  @project_dir Path.expand("..", __DIR__)

  setup do
    :ok = Sandbox.checkout(@repo)
  end

  defp index(attrs) do
    Map.merge(
      %{
        name: "i",
        valid: true,
        ready: true,
        partial: false,
        method: "btree",
        keys: ["o", "s", "id"],
        desc: [false, false, false],
        nulls_first: [false, false, false],
        default_collation: [true, true, true],
        default_opclass: [true, true, true]
      },
      attrs
    )
  end

  @spec_cols %{columns: ["o", "s", "id"]}

  describe "spec/1 — the index shape is derived, not guessed" do
    test "a resource with a keyset_sort leads with org_id, then the sort column, then id (stored names)" do
      assert {:ok, spec} = Indexing.spec(WorkFixture.Task)
      assert spec.columns == ["stw_org_id", "stw_title", "stw_id"]
      assert spec.logical == [:org_id, :title, :id]
      assert spec.table == "stw_task"
      assert spec.name == "stw_task_org_title_id_idx"
    end

    test "a resource with no keyset_sort is served by (org_id, id)" do
      assert {:ok, spec} = Indexing.spec(WorkFixture.Project)
      assert [org, id] = spec.columns
      assert String.ends_with?(org, "_org_id") and String.ends_with?(id, "_id")
    end

    test "the declared sort is the one the CRM list views default to" do
      assert Samen.Info.keyset_sort(CrmScopeFixture.Person) == :display_name
      assert Samen.Info.keyset_sort(CrmScopeFixture.Company) == :name
      assert Samen.Info.keyset_sort(CrmScopeFixture.Opportunity) == nil
    end
  end

  describe "classify/1" do
    test "an OrgScope resource with an org_id and a Postgres table is org-scoped" do
      assert Indexing.classify(WorkFixture.Task) == :org_scoped
      assert Indexing.classify(Bare) == :org_scoped
    end

    test "a resource without org_id is not org-scoped" do
      assert Indexing.classify(NoOrg) == :not_org_scoped
    end

    test "a module that is not a resource cannot be inspected: an error, never :not_org_scoped" do
      assert {:error, reason} = Indexing.classify(Samen.Indexing)
      assert reason =~ "not a loadable Ash resource"
    end
  end

  describe "serves?/2 — only an index the planner can walk counts" do
    test "a plain valid btree with the exact leading columns serves; extra trailing columns are fine" do
      assert Indexing.serves?(index(%{}), @spec_cols)
      assert Indexing.serves?(
               index(%{
                 keys: ["o", "s", "id", "x"],
                 desc: [false, false, false, false],
                 nulls_first: [false, false, false, false],
                 default_collation: [true, true, true, true],
                 default_opclass: [true, true, true, true]
               }),
               @spec_cols
             )
    end

    test "an all-descending sort/id pair (with the default NULLS FIRST) serves, a mixed one does not" do
      desc = %{desc: [false, true, true], nulls_first: [false, true, true]}
      assert Indexing.serves?(index(desc), @spec_cols)
      refute Indexing.serves?(index(%{desc: [false, false, true], nulls_first: [false, false, true]}), @spec_cols)
    end

    test "the NULLS ordering must be the default for the direction — one rejected shape per direction" do
      # ASC with NULLS FIRST: a forward scan yields nulls last, the page asks for last.
      refute Indexing.serves?(index(%{nulls_first: [false, true, false]}), @spec_cols)
      # DESC with NULLS LAST: a backward scan yields nulls first, the page asks for first.
      refute Indexing.serves?(index(%{desc: [false, true, true], nulls_first: [false, false, true]}), @spec_cols)
    end

    test "a key with a non-default collation does not serve" do
      refute Indexing.serves?(index(%{default_collation: [true, false, true]}), @spec_cols)
    end

    test "a key with a non-default operator class (e.g. text_pattern_ops) does not serve" do
      refute Indexing.serves?(index(%{default_opclass: [true, false, true]}), @spec_cols)
    end

    test "the extra trailing columns are not held to the shape (only the contract's leading columns are)" do
      assert Indexing.serves?(
               index(%{
                 keys: ["o", "s", "id", "x"],
                 desc: [false, false, false, true],
                 nulls_first: [false, false, false, false],
                 default_collation: [true, true, true, false],
                 default_opclass: [true, true, true, false]
               }),
               @spec_cols
             )
    end

    test "each of these does NOT serve" do
      refute Indexing.serves?(index(%{partial: true}), @spec_cols)
      refute Indexing.serves?(index(%{valid: false}), @spec_cols)
      refute Indexing.serves?(index(%{ready: false}), @spec_cols)
      refute Indexing.serves?(index(%{method: "hash"}), @spec_cols)
      refute Indexing.serves?(index(%{keys: ["s", "o", "id"]}), @spec_cols)
      refute Indexing.serves?(index(%{keys: ["o", "id"], desc: [false, false]}), @spec_cols)
      refute Indexing.serves?(index(%{keys: ["o", nil, "id"]}), @spec_cols)
      refute Indexing.serves?(index(%{keys: ["o"], desc: [false]}), @spec_cols)
    end
  end

  describe "against the live catalog" do
    test "the migrated fixture table carries the index the contract names" do
      {:ok, spec} = Indexing.spec(WorkFixture.Task)
      {:ok, indexes} = Indexing.live_indexes(@repo, "public", spec.table)

      assert Enum.any?(indexes, &Indexing.serves?(&1, spec))
      assert Enum.any?(indexes, &(&1.name == spec.name))
    end

    test "a table absent from the database is an error, not an empty index list" do
      assert {:error, reason} = Indexing.live_indexes(@repo, "public", "ix_ghost_absent")
      assert reason =~ "does not exist"
    end

    test "dropping the index (inside the test transaction) flips serving to false — the positive control" do
      {:ok, spec} = Indexing.spec(WorkFixture.Task)
      assert Indexes.violations(domains: [WorkFixture]) == []

      @repo.query!(~s(DROP INDEX "#{spec.name}"))

      {:ok, indexes} = Indexing.live_indexes(@repo, "public", spec.table)
      refute Enum.any?(indexes, &Indexing.serves?(&1, spec))

      assert [violation] = Indexes.violations(domains: [WorkFixture])
      assert violation =~ "WorkFixture.Task"
      assert violation =~ "need btree (stw_org_id, stw_title, stw_id) named stw_task_org_title_id_idx"
    end
  end

  describe "mix samen.verify.indexes — violations/1" do
    test "a bare table is a violation naming the resource, the index to build and what exists" do
      @repo.query!("CREATE TABLE ix_bare (id uuid PRIMARY KEY, org_id uuid NOT NULL)")

      assert [violation] = Indexes.violations(domains: [Samen.IndexingTest.Domain])
      assert violation =~ "Samen.IndexingTest.Bare"
      assert violation =~ "need btree (org_id, id) named ix_bare_org_id_idx"
      assert violation =~ "ix_bare_pkey(id)"
      assert violation =~ "mix samen.gen.indexes"
    end

    test "the same table is clean once (org_id, id) exists, and a partial index does not count" do
      @repo.query!("CREATE TABLE ix_bare (id uuid PRIMARY KEY, org_id uuid NOT NULL)")

      @repo.query!("CREATE INDEX ix_bare_partial ON ix_bare (org_id, id) WHERE org_id IS NOT NULL")
      assert [_] = Indexes.violations(domains: [Samen.IndexingTest.Domain])

      @repo.query!("CREATE INDEX ix_bare_org_id_idx ON ix_bare (org_id, id)")
      assert Indexes.violations(domains: [Samen.IndexingTest.Domain]) == []
    end

    test "a resource whose table is absent is a violation (cannot inspect), never a silent pass" do
      assert [violation] = Indexes.violations(domains: [Samen.IndexingTest.GhostDomain])
      assert violation =~ "cannot inspect Samen.IndexingTest.Ghost"
      assert violation =~ "does not exist"
    end

    test "a domain with no org-scoped resource proves nothing: it is a violation, not a pass" do
      assert Indexes.violations(domains: [Samen.IndexingTest.NoOrgDomain]) |> Enum.join() =~
               "no org-scoped resource"
    end

    test "no domains configured is a violation: nothing was inspected, nothing is proven" do
      assert [reason] = Indexes.violations(domains: [])
      assert reason =~ "nothing is proven"
    end

    test "an exemption is honoured, and a stale one is itself a violation" do
      assert Indexes.violations(
               domains: [Samen.IndexingTest.GhostDomain],
               exempt: %{Ghost => "a literal reason"}
             ) == []

      assert [stale] =
               Indexes.violations(domains: [WorkFixture], exempt: %{Ghost => "a literal reason"})

      assert stale =~ "stale exemption"
    end

    test "a resource declared unmounted is not checked — and a stale declaration is a violation" do
      ghost = %{Ghost => "this host does not migrate it"}

      # the table is absent and declared so: not a violation (the run PRINTS it as not inspected)
      assert Indexes.violations(domains: [Samen.IndexingTest.GhostDomain], unmounted: ghost) == []
      # positive control: without the declaration the same domain is red
      assert [_] = Indexes.violations(domains: [Samen.IndexingTest.GhostDomain])

      # declared unmounted but its table EXISTS in the live database: the entry excuses nothing
      assert [stale] =
               Indexes.violations(domains: [WorkFixture], unmounted: %{WorkFixture.Task => "claims it is absent"})

      assert stale =~ "stale unmounted entry"
      assert stale =~ "has its table in the live database"

      # declared unmounted but not a resource of the configured domains at all
      assert [stale2] = Indexes.violations(domains: [WorkFixture], unmounted: ghost)
      assert stale2 =~ "is not an org-scoped resource of the configured domains"
    end

    test "samen_core's own configured domains (kernel resources) are all served" do
      assert Indexes.violations(domains: Application.fetch_env!(:samen_core, :ash_domains)) == []
    end

    test "the shipped exemption list is empty: no resource is excused from the contract" do
      assert Indexes.violations(domains: [WorkFixture]) == []
      refute Enum.any?(Indexes.violations(domains: [WorkFixture], exempt: %{}), &(&1 =~ "stale"))
    end
  end

  describe "Samen.Migration.create_org_keyset_indexes/2 — which resources it indexes" do
    test "a listed resource that is not org-scoped is skipped; nothing is executed for it" do
      assert Samen.Migration.__org_keyset_indexes__(:up, __MODULE__, [NoOrg], []) == :ok
    end

    test "a listed module that cannot be inspected RAISES — never a silent skip" do
      assert_raise ArgumentError, ~r/not a loadable Ash resource/, fn ->
        Samen.Migration.__org_keyset_indexes__(:up, __MODULE__, [Samen.Indexing], [])
      end
    end

    test "the concurrent form refuses a migration that did not disable the DDL transaction" do
      defmodule TxEnabledMigration do
        @moduledoc false
        def __migration__, do: [disable_ddl_transaction: false]
      end

      assert_raise RuntimeError, ~r/disable/i, fn ->
        Samen.Migration.__org_keyset_indexes__(:up, TxEnabledMigration, [WorkFixture.Task], concurrently: true)
      end
    end
  end

  describe "mix samen.gen.indexes" do
    alias Mix.Tasks.Samen.Gen.Indexes, as: Gen

    test "renders LITERAL {table, columns, name} tuples, sorted, and a reversible concurrent up/down" do
      source = Gen.render(SamenCore.TestRepo, [WorkFixture.Task, CrmScopeFixture.Person], "20261114100000")

      assert source =~ "defmodule SamenCore.TestRepo.Migrations.OrgKeysetIndexes20261114100000 do"
      assert source =~ "use Samen.Migration, phase: :expand"
      assert source =~ "@disable_ddl_transaction true"
      assert source =~ "create_org_keyset_indexes(@indexes ++ @created_with_table, concurrently: true)"
      assert source =~ "drop_org_keyset_indexes(@indexes, concurrently: true)"

      assert source =~
               ~s({"scp_person", ["scp_org_id", "scp_display_name", "scp_id"], "scp_person_org_display_name_id_idx"})

      assert source =~ ~s({"stw_task", ["stw_org_id", "stw_title", "stw_id"], "stw_task_org_title_id_idx"})
      assert :binary.match(source, "scp_person") < :binary.match(source, "stw_task")

      # no resource module is ever EXECUTED by the migration: only a comment names it
      refute source =~ "@resources"
      refute Regex.match?(~r/^\s*[^#\s].*SamenCore\.Support\./m, source)

      assert {:defmodule, _, _} = Code.string_to_quoted!(source)
    end

    test "the committed samen_core test_repo migration IS the generator's output for its domains" do
      path = Path.join(@project_dir, "priv/test_repo/migrations/20261114100000_org_keyset_indexes.exs")

      domains =
        [
          Samen.CustomObjects.Domain,
          Core.Ctx,
          Samen.AI.Domain,
          Samen.Replay.Domain,
          WorkFixture,
          CrmScopeFixture
        ]

      {resources, []} = Indexing.org_scoped(domains)
      assert File.read!(path) == Gen.render(SamenCore.TestRepo, resources, "20261114100000")
    end

    test "the replay tables' indexes are built by up but never dropped by down (their own migration owns them)" do
      source = Gen.render(SamenCore.TestRepo, [WorkFixture.Task, Samen.Replay.Session], "20261114100000")
      [own, rest] = String.split(source, "@created_with_table [", parts: 2)
      [owned, _] = String.split(rest, "def up", parts: 2)

      assert owned =~ "replay_session_org_id_idx"
      refute owned =~ "stw_task"
      refute own =~ "replay_session_org_id_idx"
      assert own =~ "stw_task_org_title_id_idx"
    end

    test "a re-run (another timestamp) is a different module AND file name — Ecto accepts both" do
      one = Gen.render(SamenCore.TestRepo, [WorkFixture.Task], "20270101000000")
      two = Gen.render(SamenCore.TestRepo, [WorkFixture.Task], "20270101000001")

      assert one =~ "Migrations.OrgKeysetIndexes20270101000000 do"
      assert two =~ "Migrations.OrgKeysetIndexes20270101000001 do"

      [{m1, _}] = Code.compile_string(one)
      [{m2, _}] = Code.compile_string(two)
      assert m1 != m2

      out = Path.join(System.tmp_dir!(), "ix_gen_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(out) end)
      args = ["--out", out, "--domain", "SamenCore.Support.WorkFixture"]

      first = Gen.run(args ++ ["--timestamp", "20270101000000"])
      second = Gen.run(args ++ ["--timestamp", "20270101000001"])

      assert first != second
      assert File.exists?(first) and File.exists?(second)
      assert File.read!(first) =~ "OrgKeysetIndexes20270101000000"
      assert File.read!(second) =~ "OrgKeysetIndexes20270101000001"
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Tests that must COMMIT (CREATE INDEX CONCURRENTLY cannot run inside the sandbox transaction).
  # ---------------------------------------------------------------------------------------------

  describe "a changed keyset_sort (M1) — caught by the verifier, repaired by a re-run of the generator" do
    alias Mix.Tasks.Samen.Gen.Indexes, as: Gen
    alias Samen.IndexingTest.{Sortable, SortableDomain}

    @old_version 29_990_101_000_001
    @new_version 29_990_101_000_002

    setup do
      Samen.TestSandbox.auto!(@repo)
      @repo.query!("DROP TABLE IF EXISTS ix_sortable")
      @repo.query!("CREATE TABLE ix_sortable (id uuid PRIMARY KEY, org_id uuid NOT NULL, name text, note text)")

      on_exit(fn ->
        @repo.query!("DROP TABLE IF EXISTS ix_sortable")
        @repo.query!("DELETE FROM schema_migrations WHERE version IN ($1, $2)", [@old_version, @new_version])
      end)
    end

    defp migrate!(source, version) do
      [{module, _}] = Code.compile_string(source)
      Ecto.Migrator.run(@repo, [{version, module}], :up, all: true, log: false, migration_lock: false)
    end

    defp index_names(table) do
      {:ok, indexes} = Indexing.live_indexes(@repo, "public", table)
      indexes |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "the old literal migration builds the old index; a new sort is red with the concrete next step; the re-run builds it" do
      old_sorts = %{Sortable => :name}
      new_sorts = %{Sortable => :note}

      # --- deploy 1: the resource sorted by :name; the generator wrote a LITERAL migration -------
      old_source = Gen.render(@repo, [Sortable], "29990101000001", keyset_sorts: old_sorts)
      assert old_source =~ ~s({"ix_sortable", ["org_id", "name", "id"], "ix_sortable_org_name_id_idx"})
      assert [_] = migrate!(old_source, @old_version)

      assert "ix_sortable_org_name_id_idx" in index_names("ix_sortable")
      assert Indexes.violations(domains: [SortableDomain], keyset_sorts: old_sorts) == []

      # --- deploy 2: the resource now sorts by :note. The applied migration is literal, so it did
      # NOT change meaning; the database still holds the :name index and the verifier says so. ---
      assert [violation] = Indexes.violations(domains: [SortableDomain], keyset_sorts: new_sorts)
      assert violation =~ "Samen.IndexingTest.Sortable"
      assert violation =~ "need btree (org_id, note, id) named ix_sortable_org_note_id_idx"
      assert violation =~ "The shape changed"
      assert violation =~ "ix_sortable_org_name_id_idx was built for another shape"
      assert violation =~ "mix samen.gen.indexes"
      assert violation =~ "NEW index ix_sortable_org_note_id_idx"
      assert violation =~ "drop ix_sortable_org_name_id_idx in a follow-up migration"

      # --- the re-run: a NEW file/module whose name is different, and which really builds it ------
      new_source = Gen.render(@repo, [Sortable], "29990101000002", keyset_sort_opts(new_sorts))
      assert new_source =~ ~s("ix_sortable_org_note_id_idx")
      assert [_] = migrate!(new_source, @new_version)

      assert Indexes.violations(domains: [SortableDomain], keyset_sorts: new_sorts) == []
      assert ["ix_sortable_org_name_id_idx", "ix_sortable_org_note_id_idx"] -- index_names("ix_sortable") ==
               []

      # the old index is NOT dropped by the generator (that is the operator's follow-up step), so
      # the database still serves the old shape too
      assert Indexes.violations(domains: [SortableDomain], keyset_sorts: old_sorts) == []
    end

    defp keyset_sort_opts(sorts), do: [keyset_sorts: sorts]
  end

  describe "an INVALID same-named index is replaced, not skipped (S3)" do
    setup do
      Samen.TestSandbox.auto!(@repo)
      @repo.query!("DROP TABLE IF EXISTS ix_leftover")
      @repo.query!("CREATE TABLE ix_leftover (id uuid PRIMARY KEY, org_id uuid NOT NULL, name text)")
      version = 29_990_101_000_010

      on_exit(fn ->
        @repo.query!("DROP TABLE IF EXISTS ix_leftover")
        @repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      {:ok, version: version}
    end

    defp index_state(name) do
      @repo.query!(
        "SELECT i.indisvalid, i.indexrelid::oid::bigint, i.indnatts FROM pg_index i " <>
          "JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
        [name]
      ).rows
    end

    test "a failed CONCURRENTLY build leaves an invalid index; the migration drops it and builds the real one",
         %{version: version} do
      name = "ix_leftover_org_name_id_idx"
      id = fn -> Ecto.UUID.bingenerate() end
      org = Ecto.UUID.bingenerate()
      @repo.query!("INSERT INTO ix_leftover (id, org_id) VALUES ($1, $2), ($3, $2)", [id.(), org, id.()])

      # Manufacture the leftover: a UNIQUE concurrent build over duplicate rows fails halfway
      # and leaves the named index behind, INVALID.
      assert {:error, _} = @repo.query("CREATE UNIQUE INDEX CONCURRENTLY #{name} ON ix_leftover (org_id)")
      assert [[false, _oid, 1]] = index_state(name)

      assert [_] =
               Ecto.Migrator.run(
                 @repo,
                 [{version, Samen.IndexingTest.InvalidLeftoverMigration}],
                 :up,
                 all: true,
                 log: false,
                 migration_lock: false
               )

      # without the drop, `IF NOT EXISTS` would have skipped the name and left it invalid, 1 column
      assert [[true, _oid, 3]] = index_state(name)

      {:ok, indexes} = Indexing.live_indexes(@repo, "public", "ix_leftover")
      assert Enum.find(indexes, &(&1.name == name)).keys == ["org_id", "name", "id"]

      # a VALID same-named index is left alone: re-running the migration does not rebuild it
      assert :ok = Ecto.Migrator.down(@repo, version, Samen.IndexingTest.InvalidLeftoverMigration, log: false)
      assert index_state(name) == []

      @repo.query!("CREATE INDEX #{name} ON ix_leftover (org_id, name, id)")
      [[true, oid_before, 3]] = index_state(name)

      assert :ok = Ecto.Migrator.up(@repo, version, Samen.IndexingTest.InvalidLeftoverMigration, log: false)
      assert [[true, ^oid_before, 3]] = index_state(name)
    end
  end

  describe "the live catalog sees each rejected shape (NULLS, collation, operator class)" do
    alias Samen.IndexingTest.{Sortable, SortableDomain}

    @sorts %{Sortable => :name}

    setup do
      @repo.query!("CREATE TABLE ix_sortable (id uuid PRIMARY KEY, org_id uuid NOT NULL, name text, note text)")
      :ok
    end

    defp violations_for(index_sql) do
      @repo.query!(index_sql)
      Indexes.violations(domains: [SortableDomain], keyset_sorts: @sorts)
    end

    test "the default ascending index is clean — the positive control for every shape below" do
      assert violations_for("CREATE INDEX i ON ix_sortable (org_id, name, id)") == []
    end

    test "the default descending index (NULLS FIRST) is clean — walked backward" do
      assert violations_for("CREATE INDEX i ON ix_sortable (org_id, name DESC, id DESC)") == []
    end

    test "ASC NULLS FIRST is rejected" do
      assert [_] = violations_for("CREATE INDEX i ON ix_sortable (org_id, name NULLS FIRST, id)")
    end

    test "DESC NULLS LAST is rejected" do
      assert [_] = violations_for("CREATE INDEX i ON ix_sortable (org_id, name DESC NULLS LAST, id DESC)")
    end

    test "a non-default collation is rejected" do
      assert [_] = violations_for("CREATE INDEX i ON ix_sortable (org_id, name COLLATE \"C\", id)")
    end

    test "a non-default operator class is rejected" do
      assert [_] = violations_for("CREATE INDEX i ON ix_sortable (org_id, name text_pattern_ops, id)")
    end
  end

  describe "mix samen.verify.indexes — the process exits non-zero" do
    test "with the discovered domains cleared (SAMEN_EMPTY_ASH_DOMAINS=1) it exits 1 and says why" do
      {out, status} =
        System.cmd("mix", ["samen.verify.indexes"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}, {"SAMEN_EMPTY_ASH_DOMAINS", "1"}],
          stderr_to_stdout: true
        )

      assert status == 1
      assert out =~ "FAIL: samen.verify.indexes found 1 violation(s)"
      assert out =~ "no Ash domains are configured"
    end
  end
end
