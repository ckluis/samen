defmodule Samen.OrgIdPinnedGuardCoreTest do
  @moduledoc """
  The walk behind the per-host "org_id is pinned" guards is itself refutable: a resource that
  takes `org_id` and carries no pin is reported on update AND create, and the same resource with
  `Samen.Policy.OrgIdPinned` is not. Zero resources walked is an error, not a pass.
  """
  use ExUnit.Case, async: true

  defmodule Unpinned do
    use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.Dom, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule Pinned do
    use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.Dom, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule Dom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedGuardCoreTest.Unpinned)
      resource(Samen.OrgIdPinnedGuardCoreTest.Pinned)
    end
  end

  # A resource whose build-time change does what `Demo.MarketingScope.Send` used to: touch the database
  # while the changeset is BUILT. `mode` picks how it fails: raise, exit (a shared owner that died), or
  # query and map the `{:error, _}` to a validation error (the swallow that hid the CI flake).
  for mode <- [:raise, :exit, :query_swallowed] do
    mod = Module.concat(__MODULE__, "Builds#{Macro.camelize(Atom.to_string(mode))}")

    defmodule mod do
      use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.BuildsDom, data_layer: Ash.DataLayer.Ets

      attributes do
        uuid_primary_key(:id)
        attribute(:org_id, :uuid, public?: true, writable?: true)
      end

      changes do
        change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])

        change(
          fn changeset, _ctx ->
            case unquote(mode) do
              :raise ->
                raise "boom"

              :exit ->
                exit({:noproc, {DBConnection.Holder, :checkout, []}})

              :query_swallowed ->
                case SamenCore.TestRepo.query("SELECT 1") do
                  {:ok, _} -> changeset
                  {:error, _} -> Ash.Changeset.add_error(changeset, field: :id, message: "not found")
                end
            end
          end,
          on: [:create]
        )
      end

      actions do
        defaults([:read, create: :*, update: :*])
      end
    end
  end

  defmodule BuildsDom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedGuardCoreTest.BuildsRaise)
      resource(Samen.OrgIdPinnedGuardCoreTest.BuildsExit)
      resource(Samen.OrgIdPinnedGuardCoreTest.BuildsQuerySwallowed)
    end
  end

  test "a resource whose build raises, exits or queries is UNEXERCISABLE by name, never exercised" do
    report = Samen.OrgIdPinnedGuard.walk([BuildsDom], %{}, repos: [SamenCore.TestRepo])

    assert Enum.sort(for {r, a, _why} <- report.unexercisable, do: {r, a}) ==
             Enum.sort([
               {Samen.OrgIdPinnedGuardCoreTest.BuildsRaise, :create},
               {Samen.OrgIdPinnedGuardCoreTest.BuildsExit, :create},
               {Samen.OrgIdPinnedGuardCoreTest.BuildsQuerySwallowed, :create}
             ])

    why = Map.new(report.unexercisable, fn {r, _a, why} -> {r, why} end)
    assert why[Samen.OrgIdPinnedGuardCoreTest.BuildsQuerySwallowed] =~ "queried the database"
    assert why[Samen.OrgIdPinnedGuardCoreTest.BuildsExit] =~ "exit"
    # the update actions of the same resources do not touch the database and are exercised
    assert report.actions == 3
  end

  test "watching a repo does not flag a database-free resource (positive control)" do
    report = Samen.OrgIdPinnedGuard.walk([Dom], %{}, repos: [SamenCore.TestRepo])
    assert report.unexercisable == []
  end

  test "an unpinned resource is a violation on update and create; the pinned one is not" do
    report = Samen.OrgIdPinnedGuard.walk([Dom])

    assert report.walked == 2
    assert report.unexercisable == []
    assert Enum.sort(for {r, _, t, _} <- report.violations, do: {r, t}) == [{Unpinned, :create}, {Unpinned, :update}]
  end

  test "a declared exception is carried in the report and suppresses only that resource" do
    report = Samen.OrgIdPinnedGuard.walk([Dom], %{Unpinned => "test"})
    assert report.violations == []
    assert report.exceptions == %{Unpinned => "test"}
  end

  test "a walk over no resource has walked == 0 (the host guards assert > 0)" do
    assert %{walked: 0, actions: 0} = Samen.OrgIdPinnedGuard.walk([])
  end

  test "the pin allows a same-value org_id write, an actor-less create, and an unauthorized system write" do
    org = Ash.UUID.generate()
    other = Ash.UUID.generate()
    actor = %{id: Ash.UUID.generate(), org_id: org}

    assert %{valid?: true} = Ash.Changeset.for_create(Pinned, :create, %{org_id: org}, actor: actor)
    assert %{valid?: true} = Ash.Changeset.for_create(Pinned, :create, %{org_id: other})
    assert %{valid?: true} = Ash.Changeset.for_create(Pinned, :create, %{org_id: other}, actor: actor, authorize?: false)
    assert %{valid?: false} = Ash.Changeset.for_create(Pinned, :create, %{org_id: other}, actor: actor)

    record = Ash.Seed.seed!(Pinned, %{org_id: org})
    assert %{valid?: true} = Ash.Changeset.for_update(record, :update, %{org_id: org}, actor: actor)
    assert %{valid?: false} = Ash.Changeset.for_update(record, :update, %{org_id: other}, actor: actor)
    assert %{valid?: true} = Ash.Changeset.for_update(record, :update, %{org_id: other}, actor: actor, authorize?: false)
  end

  # --- the watch is derived, not optional ------------------------------------------------------------------

  defmodule PgBuildsQuery do
    use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.PgDom, data_layer: AshPostgres.DataLayer

    postgres do
      table "zzz_org_pin_walk_never_created"
      repo SamenCore.TestRepo
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])

      change(
        fn changeset, _ctx ->
          case SamenCore.TestRepo.query("SELECT 1") do
            {:ok, _} -> changeset
            {:error, _} -> Ash.Changeset.add_error(changeset, field: :id, message: "not found")
          end
        end,
        on: [:create]
      )
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule PgDom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedGuardCoreTest.PgBuildsQuery)
    end
  end

  test "the watched repos are derived from the resources: a Postgres build that queries is caught WITHOUT repos:" do
    report = Samen.OrgIdPinnedGuard.walk([PgDom])

    assert SamenCore.TestRepo in report.watched_repos
    assert [{PgBuildsQuery, :create, why}] = report.unexercisable
    assert why =~ "queried the database"
  end

  defmodule NoRepoPg do
    use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.NoRepoDom, data_layer: AshPostgres.DataLayer

    postgres do
      table "zzz_org_pin_walk_no_repo"
      repo(fn _resource, _type -> nil end)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule NoRepoDom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedGuardCoreTest.NoRepoPg)
    end
  end

  test "a Postgres-backed resource whose repo cannot be resolved fails the walk by name" do
    assert_raise ArgumentError, ~r/NoRepoPg is Postgres-backed but no repo could be resolved/, fn ->
      Samen.OrgIdPinnedGuard.walk([NoRepoDom])
    end
  end

  # --- a query issued by a Task the build started ------------------------------------------------------------

  defmodule BuildsTaskQuery do
    use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.TaskDom, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])

      change(
        fn changeset, _ctx ->
          Task.async(fn -> SamenCore.TestRepo.query("SELECT 1") end) |> Task.await()
          changeset
        end,
        on: [:create]
      )
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule TaskDom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedGuardCoreTest.BuildsTaskQuery)
    end
  end

  test "a query issued from a Task the build started is seen (its $callers include the walker)" do
    report = Samen.OrgIdPinnedGuard.walk([TaskDom], %{}, repos: [SamenCore.TestRepo])
    assert [{BuildsTaskQuery, :create, why}] = report.unexercisable
    assert why =~ "queried the database"
  end

  # --- an action that sets org_id inside a hook -------------------------------------------------------------

  defmodule HookSets do
    use Ash.Resource, domain: Samen.OrgIdPinnedGuardCoreTest.HookDom, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: false)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])
    end

    actions do
      defaults([:read])

      create :create do
        argument(:org_id, :uuid, allow_nil?: false)

        change(fn changeset, _ctx ->
          Ash.Changeset.before_action(changeset, fn cs ->
            Ash.Changeset.force_change_attribute(cs, :org_id, Ash.Changeset.get_argument(cs, :org_id))
          end)
        end)
      end
    end
  end

  defmodule HookDom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedGuardCoreTest.HookSets)
    end
  end

  @this_file Path.relative_to_cwd(__ENV__.file)

  test "an action that sets org_id in a hook is NOT counted as exercised; unlisted it fails the walk by name" do
    report = Samen.OrgIdPinnedGuard.walk([HookDom])

    assert report.hook_set == [{HookSets, :create}]
    assert report.hook_set_unlisted == [{HookSets, :create}]
    assert report.actions == 0
    assert report.violations == []
  end

  test "a listed hook-set action needs a reason and a named test that exists" do
    ok = %{reason: "org taken from an argument", test_file: @this_file, test_name: "a listed hook-set action needs a reason"}
    report = Samen.OrgIdPinnedGuard.walk([HookDom], %{}, hook_set: %{{HookSets, :create} => ok})
    assert report.hook_set_unlisted == []
    assert report.hook_set_unproven == []

    for {label, bad} <- [
          {"test not in the file", %{ok | test_name: "a test that does not exist anywhere #{System.unique_integer()}"}},
          {"no file", %{ok | test_file: "test/nope_#{System.unique_integer([:positive])}.exs"}},
          {"no reason", %{ok | reason: ""}}
        ] do
      report = Samen.OrgIdPinnedGuard.walk([HookDom], %{}, hook_set: %{{HookSets, :create} => bad})
      assert [{HookSets, :create, _why}] = report.hook_set_unproven, label
    end

    stale = Samen.OrgIdPinnedGuard.walk([HookDom], %{}, hook_set: %{{HookSets, :create} => ok, {HookSets, :gone} => ok})
    assert [{HookSets, :gone, "the action does not exist"}] = stale.hook_set_unproven
  end

  test "the Marketing Send mount is detected as hook-set (the real shape)" do
    report = Samen.OrgIdPinnedGuard.walk([SamenCore.Support.SuppressionFixture])
    assert {SamenCore.Support.SuppressionFixture.Send, :create_checked} in report.hook_set
  end
end
