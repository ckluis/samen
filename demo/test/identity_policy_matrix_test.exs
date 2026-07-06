defmodule Demo.IdentityPolicyMatrixTest do
  @moduledoc """
  The Identity org-scope + RBAC policy matrix (T3.1). Exercises the REAL mounted
  Identity resources against the REAL Postgres, through the REAL Ash policy
  authorizer (simple_sat). These are the load-bearing acceptance tests for the
  scope-packaging + policy patterns every other scope copies.

  Covers:
    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (the `cross-org read denied (policy matrix property test)` red path);
    * cross-org write denied;
    * PII masked-by-default on the tenant-plane read (user/invitation);
    * the positive cases (an actor sees + writes its OWN org's rows).
  """
  use Demo.DataCase, async: false
  use ExUnitProperties

  alias Demo.Identity.{Org, User, Invitation}

  # --- helpers -------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_user(org_id, handle, role \\ :member) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: handle,
        org_id: org_id,
        full_name: %{first: handle, last: "L"},
        emails: ["#{handle}@example.com"]
      })
      |> Ash.create(authorize?: false)

    {user, Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})}
  end

  # =========================================================================
  # Cross-org read denial — the org-scope FilterCheck. PROPERTY test.
  # =========================================================================

  property "an actor scoped to org A never reads another org's users (cross-org read denied)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 25
          ) do
      org_a = mk_org("A-" <> name_a)
      org_b = mk_org("B-" <> name_b)

      {_ua, scope_a} = mk_user(org_a.id, "ua")
      {_ub, _scope_b} = mk_user(org_b.id, "ub")

      # Actor A reads through the policy authorizer. Select org_id explicitly so we
      # can assert on the tenant boundary of every returned row.
      query = User |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      # Every row seen belongs to org A. Org B's user is invisible (not forbidden —
      # filtered out; the correct multi-tenant semantics).
      assert seen_orgs == [org_a.id]
      refute org_b.id in seen_orgs
    end
  end

  test "an org-less actor (no org_id scope) sees zero tenant-plane rows (fail closed)" do
    org = mk_org("orgless-probe")
    {_u, _s} = mk_user(org.id, "u1")

    # An actor with a nil org_id → the org-scope filter is `false`. Fail closed:
    # the actor either gets an empty result or is forbidden outright — never a
    # foreign org's rows. Both outcomes are "zero rows".
    orgless_actor = %{id: "nobody", org_id: nil, role: :member}

    case Ash.read(User, actor: orgless_actor, authorize?: true) do
      {:ok, seen} -> assert seen == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  test "an actor DOES see its own org's rows (positive case)" do
    org = mk_org("self-read")
    {_u, scope} = mk_user(org.id, "self")
    query = User |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert length(seen) == 1
    assert hd(seen).org_id == org.id
  end

  # =========================================================================
  # Cross-org WRITE denial.
  # =========================================================================

  test "an actor cannot update a foreign org's user (cross-org write denied)" do
    org_a = mk_org("wa")
    org_b = mk_org("wb")
    {_ua, scope_a} = mk_user(org_a.id, "wua")
    {ub, _scope_b} = mk_user(org_b.id, "wub")

    result =
      ub
      |> Ash.Changeset.for_update(:update, %{status: "tampered"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an actor CAN update its own org's user (positive write case)" do
    org = mk_org("selfwrite")
    {u, scope} = mk_user(org.id, "sw")

    assert {:ok, updated} =
             u
             |> Ash.Changeset.for_update(:update, %{status: "changed"})
             |> Ash.update(actor: scope.actor, authorize?: true)

    assert updated.status == "changed"
  end

  # =========================================================================
  # PII masked-by-default on the tenant-plane read.
  # =========================================================================

  test "user PII (full_name, emails) is %Masked{} by default on a tenant-plane read" do
    org = mk_org("mask")
    {_u, scope} = mk_user(org.id, "masked")

    query = User |> Ash.Query.select([:id, :full_name, :emails])
    {:ok, [user]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = user.full_name
    assert %Samen.Masked{} = user.emails
    # The masked value renders as bullets, never plaintext.
    assert Phoenix.HTML.Safe.to_iodata(user.full_name) |> IO.iodata_to_binary() =~ "•"
  end

  test "invitation email is %Masked{} by default (invitation🔒 vault routing)" do
    org = mk_org("inv-mask")

    {:ok, invite} =
      Invitation
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        role: :member,
        email: ["invitee@example.com"]
      })
      |> Ash.create(authorize?: false)

    scope = Samen.Scope.new(%{id: "admin", org_id: org.id, role: :admin})
    query = Invitation |> Ash.Query.select([:id, :email])
    {:ok, [read_invite]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = read_invite.email
    refute is_binary(read_invite.email)
    # The plaintext email never appears in the read struct.
    refute inspect(read_invite) =~ "invitee@example.com"
    _ = invite
  end
end
