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
