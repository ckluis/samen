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

  # The scope policy a JSON:API resource carries, written out (this app has no ash_json_api, so the transformer that
  # injects it does not run here); `Samen.ApiKeyScopeGuard.guarded?/1` reads its shape.
  defmodule Guarded.Crm do
    use Ash.Domain, validate_config_inclusion?: false
    resources do
      resource(Samen.ApiKeyScopeGuardTest.GuardedThing)
    end
  end

  defmodule GuardedThing do
    use Ash.Resource,
      domain: Samen.ApiKeyScopeGuardTest.Guarded.Crm,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    policies do
      policy Samen.Policy.ApiKeyScopeRefused do
        forbid_if(always())
      end

      policy always() do
        authorize_if(always())
      end
    end
  end

  # The same resource under a domain whose own policy list opens with a `bypass`: Ash evaluates the domain's
  # policies first, so the scope policy no longer comes first.
  defmodule Bypassing.Crm do
    use Ash.Domain, validate_config_inclusion?: false, authorizers: [Ash.Policy.Authorizer]

    policies do
      bypass always() do
        authorize_if(always())
      end
    end

    resources do
      resource(Samen.ApiKeyScopeGuardTest.BypassedThing)
    end
  end

  defmodule BypassedThing do
    use Ash.Resource,
      domain: Samen.ApiKeyScopeGuardTest.Bypassing.Crm,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    policies do
      policy Samen.Policy.ApiKeyScopeRefused do
        forbid_if(always())
      end
    end
  end

  defmodule Dotted.Crm do
    use Ash.Domain, validate_config_inclusion?: false
    def samen_api_family, do: "crm.contact"
  end

  defmodule DottedFamilyRouter do
    def domains, do: [Samen.ApiKeyScopeGuardTest.Dotted.Crm, Samen.ApiKeyScopeGuardTest.Two.Billing]
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

  test "RED: a family containing a dot is reported; CONTROL: dotless families are not" do
    assert Samen.ApiKeyScopeGuard.dotted_families(DottedFamilyRouter) == ["crm.contact"]
    assert Samen.ApiKeyScopeGuard.dotted_families(DistinctFamilyRouter) == []
  end

  test "RED: a domain-level bypass ahead of the scope policy is not guarded; CONTROL: the same policy under a plain domain is" do
    assert Samen.ApiKeyScopeGuard.guarded?(GuardedThing)
    refute Samen.ApiKeyScopeGuard.guarded?(BypassedThing)
  end
end
