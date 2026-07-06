defmodule Samen.ScopeRbacTest do
  @moduledoc """
  Unit coverage for the canonical scope/RBAC/api-key model (T3.1) that every scope's
  policy stack keys on. The Ash-policy INTEGRATION (org-scope filtering, escalation
  denial through the authorizer, PII masking) is proven end-to-end in the demo
  (`demo/test/identity_*_test.exs`); here we lock the pure decision functions.
  """
  use ExUnit.Case, async: true

  alias Samen.Scope
  alias Samen.Scope.{Role, ApiKey}

  describe "Samen.Scope.Role — the ranked, closed RBAC set" do
    test "the role set is closed and ranked highest-first" do
      assert Role.all() == [:owner, :admin, :member, :viewer]
      assert Role.rank(:owner) > Role.rank(:admin)
      assert Role.rank(:admin) > Role.rank(:member)
      assert Role.rank(:member) > Role.rank(:viewer)
    end

    test "unknown / nil roles rank -1 (fail closed)" do
      assert Role.rank(:nope) == -1
      assert Role.rank(nil) == -1
      assert Role.rank("garbage") == -1
      refute Role.valid?(:nope)
      refute Role.valid?(nil)
    end

    test "string roles resolve to their atom rank without String.to_atom on untrusted input" do
      assert Role.rank("admin") == Role.rank(:admin)
      assert Role.rank("owner") == Role.rank(:owner)
      # An unknown string never creates a new atom.
      assert Role.rank("definitely_not_a_role_atom_xyz") == -1
    end

    test "may_manage? — the no-escalation rule (red path mechanism)" do
      # A member/viewer may manage NOTHING (below admin floor).
      refute Role.may_manage?(:member, :viewer)
      refute Role.may_manage?(:viewer, :viewer)
      # An admin may manage strictly-lower roles, but NOT admin or owner.
      assert Role.may_manage?(:admin, :member)
      assert Role.may_manage?(:admin, :viewer)
      refute Role.may_manage?(:admin, :admin)
      refute Role.may_manage?(:admin, :owner)
      # An owner may manage admin and below, but NOT another owner (no lateral).
      assert Role.may_manage?(:owner, :admin)
      refute Role.may_manage?(:owner, :owner)
    end

    test "at_least? — rank comparison" do
      assert Role.at_least?(:admin, :member)
      assert Role.at_least?(:owner, :owner)
      refute Role.at_least?(:member, :admin)
      refute Role.at_least?(nil, :viewer)
    end
  end

  describe "Samen.Scope — the actor scope struct" do
    test "new/1 builds a PII-free actor and requires an org_id" do
      scope = Scope.new(%{id: "u1", org_id: "o1", role: :member, membership_id: "m1"})
      assert scope.actor == %{id: "u1", org_id: "o1", role: :member, membership_id: "m1"}
    end

    test "new/1 refuses a scope with no org (cross-org hazard, fail closed)" do
      assert_raise ArgumentError, ~r/requires an :org_id/, fn ->
        Scope.new(%{id: "u1", role: :member})
      end
    end

    test "for_membership/1 derives the actor from a membership, normalizing a string role" do
      scope =
        Scope.for_membership(%{id: "m1", user_id: "u1", org_id: "o1", role: "admin"})

      assert scope.actor.org_id == "o1"
      assert scope.actor.id == "u1"
      assert scope.actor.role == :admin
      assert scope.actor.membership_id == "m1"
    end

    test "an unknown string role normalizes to nil (unprivileged, fail closed)" do
      scope = Scope.for_membership(%{id: "m", user_id: "u", org_id: "o", role: "sudo"})
      assert scope.actor.role == nil
    end

    test "implements Ash.Scope.ToOpts — actor is extracted, tenant is not set" do
      scope = Scope.new(%{id: "u1", org_id: "o1", role: :member})
      assert {:ok, actor} = Ash.Scope.ToOpts.get_actor(scope)
      assert actor.org_id == "o1"
      assert :error == Ash.Scope.ToOpts.get_tenant(scope)
    end
  end

  describe "Samen.Scope.ApiKey — a key cannot out-reach its actor" do
    test "the actor ceiling: a viewer-minted key with a declared write scope is still read-only" do
      key = %{org_id: "o1", plane: :tenant, scopes: %{crm: [:read, :write]}, minter_role: :viewer}
      assert ApiKey.authorized?(key, :read, :crm, "o1")
      refute ApiKey.authorized?(key, :write, :crm, "o1")
    end

    test "org isolation: a key never reaches another org" do
      key = %{org_id: "o1", plane: :tenant, scopes: %{crm: [:read, :write]}, minter_role: :owner}
      assert ApiKey.authorized?(key, :write, :crm, "o1")
      refute ApiKey.authorized?(key, :read, :crm, "o2")
    end

    test "allowlist: a family/action absent from declared scopes is denied" do
      key = %{org_id: "o1", plane: :tenant, scopes: %{crm: [:read]}, minter_role: :admin}
      assert ApiKey.authorized?(key, :read, :crm, "o1")
      refute ApiKey.authorized?(key, :write, :crm, "o1")
      refute ApiKey.authorized?(key, :read, :billing, "o1")
    end

    test ":all scope grants a family it doesn't name explicitly (still bounded by role + org)" do
      key = %{org_id: "o1", plane: :tenant, scopes: %{all: [:read]}, minter_role: :member}
      assert ApiKey.authorized?(key, :read, :anything, "o1")
      refute ApiKey.authorized?(key, :write, :anything, "o1")
      refute ApiKey.authorized?(key, :read, :anything, "o2")
    end

    test "masking_for — two planes" do
      tenant = %{org_id: "o1", plane: :tenant, scopes: %{}, minter_role: :member}
      operator = %{org_id: "ops", plane: :operator, scopes: %{}, minter_role: :admin}
      assert ApiKey.masking_for(tenant, "o1") == :clear
      assert ApiKey.masking_for(tenant, "o2") == :masked
      assert ApiKey.masking_for(operator, "o1") == :masked
    end

    test "malformed key / action fails closed" do
      refute ApiKey.authorized?(%{}, :read, :crm, "o1")
      refute ApiKey.authorized?(%{org_id: "o1", scopes: %{}, minter_role: :admin}, :delete, :crm, "o1")
    end
  end
end
