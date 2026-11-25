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
end
