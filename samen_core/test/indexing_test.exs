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
        desc: [false, false, false]
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
      assert spec.name == "stw_task_org_keyset_idx"
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
      assert Indexing.serves?(index(%{keys: ["o", "s", "id", "x"], desc: [false, false, false, false]}), @spec_cols)
    end

    test "an all-descending sort/id pair serves (a backward scan), a mixed one does not" do
      assert Indexing.serves?(index(%{desc: [false, true, true]}), @spec_cols)
      refute Indexing.serves?(index(%{desc: [false, false, true]}), @spec_cols)
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
      assert violation =~ "need btree (stw_org_id, stw_title, stw_id)"
    end
  end

  describe "mix samen.verify.indexes — violations/1" do
    test "a bare table is a violation naming the resource, the index to build and what exists" do
      @repo.query!("CREATE TABLE ix_bare (id uuid PRIMARY KEY, org_id uuid NOT NULL)")

      assert [violation] = Indexes.violations(domains: [Samen.IndexingTest.Domain])
      assert violation =~ "Samen.IndexingTest.Bare"
      assert violation =~ "need btree (org_id, id)"
      assert violation =~ "ix_bare_pkey(id)"
      assert violation =~ "mix samen.gen.indexes"
    end

    test "the same table is clean once (org_id, id) exists, and a partial index does not count" do
      @repo.query!("CREATE TABLE ix_bare (id uuid PRIMARY KEY, org_id uuid NOT NULL)")

      @repo.query!("CREATE INDEX ix_bare_partial ON ix_bare (org_id, id) WHERE org_id IS NOT NULL")
      assert [_] = Indexes.violations(domains: [Samen.IndexingTest.Domain])

      @repo.query!("CREATE INDEX ix_bare_org_keyset_idx ON ix_bare (org_id, id)")
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

    test "renders a literal, sorted @resources list and a reversible concurrent up/down" do
      source = Gen.render(SamenCore.TestRepo, [WorkFixture.Task, CrmScopeFixture.Person])

      assert source =~ "defmodule SamenCore.TestRepo.Migrations.OrgKeysetIndexes do"
      assert source =~ "use Samen.Migration, phase: :expand"
      assert source =~ "@disable_ddl_transaction true"
      assert source =~ "create_org_keyset_indexes(@resources, concurrently: true)"
      assert source =~ "drop_org_keyset_indexes(@resources, concurrently: true)"

      assert source =~
               "SamenCore.Support.CrmScopeFixture.Person,\n    SamenCore.Support.WorkFixture.Task\n"

      assert {:defmodule, _, _} = Code.string_to_quoted!(source)
    end

    test "the committed samen_core test_repo migration IS the generator's output for its domains" do
      path = Path.join(@project_dir, "priv/test_repo/migrations/20261114100000_org_keyset_indexes.exs")

      domains =
        [Samen.CustomObjects.Domain, Core.Ctx, Samen.AI.Domain, WorkFixture, CrmScopeFixture]

      {resources, []} = Indexing.org_scoped(domains)
      assert File.read!(path) == Gen.render(SamenCore.TestRepo, resources)
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
