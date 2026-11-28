defmodule Samen.ScopeApiKeyPermitsTest do
  @moduledoc """
  The scope grammar an API key is enforced by (`Samen.Scope.ApiKey.permits?/4`, `family/1`, `action_class/1`) as a pure,
  refutable predicate. Keys are `"all"`, `"<family>"` and `"<family>.<type>"`, atoms or strings; values are
  `read` / `write`. An empty or malformed scope map authorizes nothing. Each refusal is paired with the same call on a key
  whose only difference is the scope that covers it.
  """
  use ExUnit.Case, async: true

  alias Samen.Scope.ApiKey

  defmodule FixtureDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.ScopeApiKeyPermitsTest.Plain)
    end
  end

  defmodule NamedDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.ScopeApiKeyPermitsTest.Named)
    end

    def samen_api_family, do: "billing_api"
  end

  defmodule Plain do
    use Ash.Resource, domain: Samen.ScopeApiKeyPermitsTest.FixtureDomain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Named do
    use Ash.Resource, domain: Samen.ScopeApiKeyPermitsTest.NamedDomain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defp key(scopes), do: %{org_id: "o1", plane: :tenant, scopes: scopes, minter_role: :admin}

  test "each scope key form grants its class; the others do not" do
    for scopes <- [
          %{"all" => ["read"]},
          %{all: [:read]},
          %{"crm" => ["read"]},
          %{crm: [:read]},
          %{"crm.contact" => ["read"]},
          %{"crm.contact" => [:read, :write]},
          %{"billing" => ["write"], "crm" => ["read"]}
        ] do
      assert ApiKey.permits?(key(scopes), :read, "crm", "contact"), inspect(scopes)
    end

    for scopes <- [
          %{"crm" => ["write"]},
          %{"crm.company" => ["read"]},
          %{"billing" => ["read"]},
          %{"contact" => ["read"]},
          %{"crm" => ["delete"]},
          %{"crm" => "read"},
          %{"crm" => nil}
        ] do
      refute ApiKey.permits?(key(scopes), :read, "crm", "contact"), inspect(scopes)
    end
  end

  test "write is its own class: a read scope does not write, a write scope does not read" do
    assert ApiKey.permits?(key(%{"crm" => ["write"]}), :write, "crm", "contact")
    refute ApiKey.permits?(key(%{"crm" => ["read"]}), :write, "crm", "contact")
    refute ApiKey.permits?(key(%{"crm" => ["write"]}), :read, "crm", "contact")
  end

  test "an empty or malformed scope map authorizes nothing" do
    for class <- [:read, :write] do
      refute ApiKey.permits?(key(%{}), class, "crm", "contact")
      refute ApiKey.permits?(%{org_id: "o1"}, class, "crm", "contact")
      refute ApiKey.permits?(key(nil), class, "crm", "contact")
      refute ApiKey.permits?(key([{"all", ["read", "write"]}]), class, "crm", "contact")
    end

    # CONTROL: the same call with the key's scope in place
    assert ApiKey.permits?(key(%{"all" => ["read", "write"]}), :write, "crm", "contact")
  end

  test "a resource with no family or type is reached only by the all scope" do
    assert ApiKey.permits?(key(%{"all" => ["read"]}), :read, nil, nil)
    refute ApiKey.permits?(key(%{"crm" => ["read"]}), :read, nil, nil)
  end

  test "generic actions count as write; only a read action is read" do
    assert ApiKey.action_class(:read) == :read
    for type <- [:create, :update, :destroy, :action], do: assert(ApiKey.action_class(type) == :write)
  end

  test "family is the underscored last domain segment, or the domain's own samen_api_family" do
    assert ApiKey.family(Plain) == "fixture_domain"
    assert ApiKey.family(Named) == "billing_api"
  end
end
