defmodule Demo.IdentityRbacRedPathTest do
  @moduledoc """
  Identity RBAC red paths (T3.1):

    * role escalation denied — a `member` cannot mint an `admin`; an `admin` cannot
      mint an `owner` (`Samen.Policy.RoleAtLeast` + `Samen.Policy.ManageRole`);
    * api_key cannot out-reach its actor — a key's effective authority is the
      intersection of its declared scopes and its minter's role
      (`Samen.Scope.ApiKey.authorized?/4`).

  These exercise the REAL mounted resources + the REAL policy authorizer where the
  path is DB-backed (membership writes), and the pure authorization model where it is
  a use-time decision (api_key reach).
  """
  use Demo.DataCase, async: false

  alias Demo.Identity.{Org, User, Membership}
  alias Samen.Scope.{Role, ApiKey}

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_user(org_id, handle) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{handle: handle, org_id: org_id})
      |> Ash.create(authorize?: false)

    user
  end

  # =========================================================================
  # Role escalation — the pure RBAC rank model (Samen.Scope.Role).
  # =========================================================================

  test "role rank model: a member cannot manage an admin; an admin cannot manage an owner" do
    # The mechanism behind the red path.
    refute Role.may_manage?(:member, :admin)
    refute Role.may_manage?(:member, :owner)
    refute Role.may_manage?(:admin, :owner)
    refute Role.may_manage?(:admin, :admin)
    refute Role.may_manage?(:owner, :owner)
    refute Role.may_manage?(:viewer, :viewer)

    # The allowed cases (positive control — the check is not vacuously false).
    assert Role.may_manage?(:owner, :admin)
    assert Role.may_manage?(:owner, :member)
    assert Role.may_manage?(:admin, :member)
    assert Role.may_manage?(:admin, :viewer)

    # Unknown / nil roles rank below everything (fail closed).
    refute Role.may_manage?(nil, :viewer)
    refute Role.may_manage?(:bogus, :viewer)
  end

  # =========================================================================
  # Role escalation — through the REAL policy authorizer on membership writes.
  # =========================================================================

  test "a member actor CANNOT create an admin membership (RoleAtLeast denies)" do
    org = mk_org("esc1")
    target = mk_user(org.id, "target")
    member_scope = Samen.Scope.new(%{id: "m", org_id: org.id, role: :member})

    result =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, user_id: target.id, role: :admin})
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin actor CANNOT create an owner membership (ManageRole denies escalation)" do
    org = mk_org("esc2")
    target = mk_user(org.id, "target2")
    admin_scope = Samen.Scope.new(%{id: "a", org_id: org.id, role: :admin})

    result =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, user_id: target.id, role: :owner})
      |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin actor CAN create a member membership (positive control)" do
    org = mk_org("esc3")
    target = mk_user(org.id, "target3")
    admin_scope = Samen.Scope.new(%{id: "a", org_id: org.id, role: :admin})

    assert {:ok, membership} =
             Membership
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               user_id: target.id,
               role: :member
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert membership.role == :member
  end

  test "an admin CANNOT promote an existing member to owner (update escalation denied)" do
    org = mk_org("esc4")
    target = mk_user(org.id, "target4")
    admin_scope = Samen.Scope.new(%{id: "a", org_id: org.id, role: :admin})

    {:ok, membership} =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, user_id: target.id, role: :member})
      |> Ash.create(actor: admin_scope.actor, authorize?: true)

    result =
      membership
      |> Ash.Changeset.for_update(:update, %{role: :owner})
      |> Ash.update(actor: admin_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # api_key cannot out-reach its actor.
  # =========================================================================

  test "a key cannot perform an action its minting role cannot (actor ceiling)" do
    # A viewer-minted key with a DECLARED write scope on billing is still read-only:
    # the key inherits the viewer ceiling.
    viewer_key = %{
      org_id: "org-1",
      plane: :tenant,
      scopes: %{billing: [:read, :write], crm: [:read, :write]},
      minter_role: :viewer
    }

    # Declared write, but viewer cannot write → denied.
    refute ApiKey.authorized?(viewer_key, :write, :billing, "org-1")
    refute ApiKey.authorized?(viewer_key, :write, :crm, "org-1")
    # Viewer CAN read (positive control).
    assert ApiKey.authorized?(viewer_key, :read, :billing, "org-1")
  end

  test "a key cannot reach an org other than its own (org isolation)" do
    key = %{
      org_id: "org-1",
      plane: :tenant,
      scopes: %{crm: [:read, :write]},
      minter_role: :admin
    }

    # Same org → allowed.
    assert ApiKey.authorized?(key, :read, :crm, "org-1")
    assert ApiKey.authorized?(key, :write, :crm, "org-1")
    # Foreign org → denied, even with a matching declared scope + high role.
    refute ApiKey.authorized?(key, :read, :crm, "org-2")
    refute ApiKey.authorized?(key, :write, :crm, "org-2")
  end

  test "a key cannot touch a family it did not declare (allowlist, not denylist)" do
    key = %{
      org_id: "org-1",
      plane: :tenant,
      scopes: %{crm: [:read]},
      minter_role: :admin
    }

    # Declared read on crm → allowed.
    assert ApiKey.authorized?(key, :read, :crm, "org-1")
    # Undeclared write on crm → denied (only :read declared).
    refute ApiKey.authorized?(key, :write, :crm, "org-1")
    # Undeclared family entirely → denied.
    refute ApiKey.authorized?(key, :read, :billing, "org-1")
  end

  test "two key planes: tenant key over its own org reads PII in clear; operator key masked" do
    tenant_key = %{org_id: "org-1", plane: :tenant, scopes: %{}, minter_role: :member}
    operator_key = %{org_id: "org-ops", plane: :operator, scopes: %{}, minter_role: :admin}

    # Tenant key over its OWN org → clear (no reveal grant needed; tenant owns its PII).
    assert ApiKey.masking_for(tenant_key, "org-1") == :clear
    # Tenant key reaching a FOREIGN org → masked (belt; authorized?/4 already denies).
    assert ApiKey.masking_for(tenant_key, "org-2") == :masked
    # Operator key → always masked unless a grant covers the subject (reveal seam).
    assert ApiKey.masking_for(operator_key, "org-1") == :masked
  end
end
