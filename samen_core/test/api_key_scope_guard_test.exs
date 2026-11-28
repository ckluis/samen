defmodule Samen.ApiKeyScopeGuardTest do
  @moduledoc """
  The walk behind the hosts' scope guards is refutable here: it reports a JSON:API-less domain as walked-but-not-exposed,
  and it names a scope family two domains of one router share (a scope on it would cover both). Each report is paired with
  a router whose families differ.
  """
  use ExUnit.Case, async: true

  defmodule One.Crm do
    use Ash.Domain, validate_config_inclusion?: false
    resources do
      resource(Samen.ApiKeyScopeGuardTest.Thing)
    end
  end

  defmodule Two.Crm do
    use Ash.Domain, validate_config_inclusion?: false
  end

  defmodule Two.Billing do
    use Ash.Domain, validate_config_inclusion?: false
  end

  defmodule Thing do
    use Ash.Resource, domain: Samen.ApiKeyScopeGuardTest.One.Crm, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule SharedFamilyRouter do
    def domains, do: [Samen.ApiKeyScopeGuardTest.One.Crm, Samen.ApiKeyScopeGuardTest.Two.Crm]
  end

  defmodule DistinctFamilyRouter do
    def domains, do: [Samen.ApiKeyScopeGuardTest.One.Crm, Samen.ApiKeyScopeGuardTest.Two.Billing]
  end

  test "two domains of one router that share a scope family are reported; distinct families are not" do
    assert Samen.ApiKeyScopeGuard.duplicate_families(SharedFamilyRouter) == ["crm"]
    assert Samen.ApiKeyScopeGuard.duplicate_families(DistinctFamilyRouter) == []
    assert Map.keys(Samen.ApiKeyScopeGuard.families(DistinctFamilyRouter)) |> Enum.sort() == ["billing", "crm"]
  end

  test "the walk counts the resources it visited and reports none exposed for a domain with no JSON:API type" do
    report = Samen.ApiKeyScopeGuard.report([One.Crm])
    assert report.walked == 1
    assert report.exposed == []
    assert report.unguarded == []
    refute Samen.ApiKeyScopeGuard.guarded?(Thing)
  end
end
