defmodule Samen.ScopeApiKeyGrammarTest do
  @moduledoc """
  The grammar a key's scopes are created under (`Samen.Scope.ApiKey.Grammar`): a non-empty map whose keys are `all`, a
  family or `family.type` and whose values list `read` and/or `write`, and, given a host's catalogue, a family and type
  that exist. Every refusal is paired with the nearest accepted scope map.
  """
  use ExUnit.Case, async: true

  alias Samen.Scope.ApiKey.Grammar

  @catalogue %{"crm" => ["company", "contact"], "freight" => ["driver"]}

  test "RED: an empty scope map is refused; CONTROL: one scope is accepted" do
    assert {:error, _} = Grammar.validate(%{})
    assert :ok = Grammar.validate(%{"all" => ["read"]})
  end

  test "RED: a scope key outside the grammar is refused; CONTROL: all, a family, family.type, atoms or strings pass" do
    for bad <- [%{"" => ["read"]}, %{"CRM" => ["read"]}, %{"crm." => ["read"]}, %{".contact" => ["read"]},
                %{"crm.contact.extra" => ["read"]}, %{"crm contact" => ["read"]}, %{"1crm" => ["read"]}, %{1 => ["read"]}] do
      assert {:error, _} = Grammar.validate(bad), "#{inspect(bad)} should be refused"
    end

    for good <- [%{"all" => ["read"]}, %{all: [:read]}, %{"crm" => ["read"]}, %{crm: [:write]}, %{"crm.contact" => ["read", "write"]},
                 %{"billing_api.line_item" => [:read]}] do
      assert :ok = Grammar.validate(good), "#{inspect(good)} should pass"
    end
  end

  test "RED: a value outside read/write is refused; CONTROL: read, write or both pass" do
    for bad <- [%{"crm" => ["delete"]}, %{"crm" => "read"}, %{"crm" => []}, %{"crm" => ["read", "admin"]}, %{"crm" => nil}, %{"crm" => [1]}] do
      assert {:error, _} = Grammar.validate(bad), "#{inspect(bad)} should be refused"
    end

    for good <- [%{"crm" => ["read"]}, %{"crm" => ["write"]}, %{"crm" => [:read, "write"]}], do: assert(:ok = Grammar.validate(good))
  end

  test "RED: a map is required; CONTROL: a map passes" do
    for bad <- [nil, "all", ["all"], [read: true]], do: assert({:error, _} = Grammar.validate(bad))
    assert :ok = Grammar.validate(%{"all" => ["read"]})
  end

  test "RED: an unknown family or type is refused by membership; CONTROL: known ones and `all` pass" do
    assert {:error, _} = Grammar.validate_membership(%{"nope" => ["read"]}, @catalogue)
    assert {:error, _} = Grammar.validate_membership(%{"crm.nope" => ["read"]}, @catalogue)
    assert {:error, _} = Grammar.validate_membership(%{"freight.contact" => ["read"]}, @catalogue)
    assert {:error, _} = Grammar.validate_membership(%{"crm" => ["read"]}, %{})

    assert :ok = Grammar.validate_membership(%{"crm" => ["read"], "crm.contact" => ["write"], "freight.driver" => ["read"]}, @catalogue)
    assert :ok = Grammar.validate_membership(%{"all" => ["read"]}, %{})
  end
end
