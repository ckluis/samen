defmodule Samen.Web.IdentityAuthzTest do
  @moduledoc """
  Identity authorization bugs found by the 2026-11-13 evaluation (catalog-b1 findings
  1, 5, 7, 10, 13, 16). Each RED test performs the forbidden write through the real
  Ash action + policy on the samen_web test host's Operator Identity mount, paired with a
  POSITIVE CONTROL (the legitimate path still works).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.WebTest.Operator.ApiKey
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Invitation
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp invite_mods,
    do: %{invitation: Invitation, credential: Credential, user: User, membership: Membership, repo: Repo}

  defp unique_email, do: "authz-#{System.unique_integer([:positive])}@example.test"

  defp register! do
    attrs = %{
      org_name: "Authz Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  defp scope(result, role, opts \\ []) do
    %Samen.Scope{
      actor: %{
        id: result.user.id,
        org_id: result.org.id,
        role: role,
        verified?: Keyword.get(opts, :verified?, true),
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp reread(mod, id) do
    mod |> Ash.Query.filter(id == ^id) |> Ash.read!(authorize?: false) |> List.first()
  end

  # ===========================================================================
  # A. Invitation default :update
  # ===========================================================================

  describe "A. Invitation :update cannot escalate role or reopen a terminal invite" do
    test "RED: an unverified viewer cannot raise a pending invite's role to :owner (nor can the accept then grant it)" do
      inviter = register!()
      invitee = register!()

      {:ok, invitation, raw} =
        Invite.create(invite_mods(), scope(inviter, :owner), %{email: invitee.email, role: :member})

      row = reread(Invitation, invitation.id)

      result =
        row
        |> Ash.Changeset.for_update(:update, %{role: :owner}, scope: scope(inviter, :viewer, verified?: false))
        |> Ash.update(scope: scope(inviter, :viewer, verified?: false))

      assert {:error, _} = result
      assert reread(Invitation, invitation.id).role == :member

      assert {:ok, joined} = Invite.accept(invite_mods(), raw)
      assert joined.membership.role == :member
    end

    test "RED: an in-org member cannot reopen a revoked invite to pending" do
      inviter = register!()
      invitee = register!()

      {:ok, invitation, raw} =
        Invite.create(invite_mods(), scope(inviter, :owner), %{email: invitee.email, role: :admin})

      assert {:ok, _} = Invite.revoke(invite_mods(), scope(inviter, :owner), invitation.id)
      row = reread(Invitation, invitation.id)
      member = scope(inviter, :member)

      assert {:error, _} =
               row |> Ash.Changeset.for_update(:update, %{status: "pending"}, scope: member) |> Ash.update(scope: member)

      assert reread(Invitation, invitation.id).status == "revoked"
      assert {:error, :revoked} = Invite.accept(invite_mods(), raw)
    end

    test "RED: even an owner has no generic update (role/status/email are not actor-writable after creation)" do
      inviter = register!()
      invitee = register!()
      {:ok, invitation, _raw} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: invitee.email})
      row = reread(Invitation, invitation.id)
      owner = scope(inviter, :owner)

      assert {:error, _} =
               row |> Ash.Changeset.for_update(:update, %{role: :owner}, scope: owner) |> Ash.update(scope: owner)

      assert reread(Invitation, invitation.id).role == :member
    end

    test "POSITIVE CONTROL: admin invites a member, admin revokes, and the accept grants exactly the invited role" do
      inviter = register!()
      invitee = register!()
      other = register!()

      {:ok, inv1, _} = Invite.create(invite_mods(), scope(inviter, :admin), %{email: invitee.email, role: :member})
      {:ok, _inv2, raw2} = Invite.create(invite_mods(), scope(inviter, :admin), %{email: other.email, role: :member})

      assert {:ok, _} = Invite.revoke(invite_mods(), scope(inviter, :admin), inv1.id)
      assert {:ok, joined} = Invite.accept(invite_mods(), raw2)
      assert joined.membership.role == :member
    end
  end

  describe "A2. Invitation :destroy is admin-gated; :revoke only moves a pending invite" do
    test "RED: a viewer/member cannot destroy an invitation (single or bulk); CONTROL: an admin can" do
      inviter = register!()
      invitee = register!()
      other = register!()
      {:ok, inv1, _} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: invitee.email})
      {:ok, inv2, _} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: other.email})

      for role <- [:viewer, :member] do
        s = scope(inviter, role)
        assert {:error, _} = reread(Invitation, inv1.id) |> Ash.destroy(scope: s)

        result = Invitation |> Ash.Query.filter(org_id == ^inviter.org.id) |> Ash.bulk_destroy(:destroy, %{}, scope: s, strategy: [:stream, :atomic], return_errors?: true)
        assert result.status == :error or result.error_count > 0
      end

      assert reread(Invitation, inv1.id) && reread(Invitation, inv2.id)

      assert :ok = reread(Invitation, inv1.id) |> Ash.destroy(scope: scope(inviter, :admin))
      assert is_nil(reread(Invitation, inv1.id))
    end

    test "RED: an admin cannot relabel an ACCEPTED invite as revoked through the :revoke action; CONTROL: a pending one revokes" do
      inviter = register!()
      invitee = register!()
      other = register!()
      {:ok, inv, raw} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: invitee.email})
      {:ok, pending, _} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: other.email})
      assert {:ok, _} = Invite.accept(invite_mods(), raw)

      admin = scope(inviter, :admin)
      accepted = reread(Invitation, inv.id)
      assert accepted.status == "accepted"

      assert {:error, _} =
               accepted
               |> Ash.Changeset.for_update(:revoke, %{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}, scope: admin)
               |> Ash.update(scope: admin)

      assert reread(Invitation, inv.id).status == "accepted"

      assert {:ok, %{status: "revoked"}} =
               reread(Invitation, pending.id)
               |> Ash.Changeset.for_update(:revoke, %{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}, scope: admin)
               |> Ash.update(scope: admin)
    end
  end

  describe "A3. Invitation :revoke is decided by the database" do
    test "RED: a STALE pending struct cannot relabel an invite that was accepted in between; CONTROL: Invite.revoke of a pending one works" do
      inviter = register!()
      invitee = register!()
      other = register!()
      {:ok, inv, raw} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: invitee.email})
      {:ok, pending, _} = Invite.create(invite_mods(), scope(inviter, :owner), %{email: other.email})

      admin = scope(inviter, :admin)
      stale = reread(Invitation, inv.id)
      assert stale.status == "pending"

      # the invitee accepts AFTER the admin read the row and BEFORE the admin's revoke commits
      assert {:ok, _} = Invite.accept(invite_mods(), raw)

      assert {:error, _} =
               stale
               |> Ash.Changeset.for_update(:revoke, %{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}, scope: admin)
               |> Ash.update(scope: admin)

      fresh = reread(Invitation, inv.id)
      assert fresh.status == "accepted"
      assert is_nil(fresh.revoked_at)

      assert {:ok, %{status: "revoked"}} = Invite.revoke(invite_mods(), admin, pending.id)
    end
  end

  # ===========================================================================
  # B. ApiKey default create/update
  # ===========================================================================

  describe "B. ApiKey cannot be written above the acting role, un-revoked, or kept alive past the ceiling" do
    alias Samen.Scope.ApiKey, as: KeyScope
    alias Samen.Web.Mount
    alias Samen.Web.Plane
    alias Samen.Web.Settings.ApiKeys

    defp mount, do: Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo, plane: Plane.tenant())

    defp direct_create(result, role, attrs) do
      s = scope(result, role)

      ApiKey
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{org_id: result.org.id, membership_id: result.membership.id, plane: :tenant, scopes: %{all: [:read]}},
          attrs
        ),
        scope: s
      )
      |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
      |> Ash.create(scope: s)
    end

    defp mint!(result, role, opts \\ []) do
      {:ok, _raw, row} =
        ApiKeys.mint(
          mount(),
          scope(result, role),
          Keyword.merge([membership_id: result.membership.id, minter_role: role, scopes: %{all: [:read]}], opts)
        )

      row
    end

    defp key_update(row, action, attrs, s) do
      row |> Ash.Changeset.for_update(action, attrs, scope: s) |> Ash.update(scope: s)
    end

    test "RED: an admin cannot mint a key with minter_role :owner through the default create" do
      r = register!()

      assert {:error, _} = direct_create(r, :admin, %{minter_role: :owner})
      assert [] = ApiKey |> Ash.Query.filter(minter_role == :owner) |> Ash.read!(authorize?: false)
    end

    test "POSITIVE CONTROL: an admin CAN mint at its own rank (admin) and below; an owner can mint :owner" do
      r = register!()
      assert {:ok, %{minter_role: :admin}} = direct_create(r, :admin, %{minter_role: :admin})
      assert {:ok, %{minter_role: :member}} = direct_create(r, :admin, %{minter_role: :member})
      assert {:ok, %{minter_role: :owner}} = direct_create(r, :owner, %{minter_role: :owner})
    end

    # a second user holding `role` in the registrant's org (a result-shaped map, usable with `scope/3`)
    defp member_of(r, role) do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "m-#{System.unique_integer([:positive])}"}, authorize?: false)
        |> Ash.create!()

      mbr =
        Membership
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: role}, authorize?: false)
        |> Ash.create!()

      %{org: r.org, user: user, membership: mbr}
    end

    defp create_for(actor, membership, minter_role, role \\ nil) do
      s = scope(actor, role || minter_role)

      ApiKey
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: actor.org.id, membership_id: membership.id, plane: :tenant, minter_role: minter_role, scopes: %{all: [:read]}},
        scope: s
      )
      |> Ash.Changeset.force_change_attribute(:token_digest, "d-#{System.unique_integer([:positive])}")
      |> Ash.create(scope: s)
    end

    test "RED: an admin cannot mint a key bound to the OWNER's membership (actor identity spoof); CONTROL: its own" do
      r = register!()
      admin = member_of(r, :admin)

      assert {:error, _} = create_for(admin, r.membership, :admin)
      assert [] = ApiKey |> Ash.Query.filter(membership_id == ^r.membership.id) |> Ash.read!(authorize?: false)

      assert {:ok, %{membership_id: mid}} = create_for(admin, admin.membership, :admin)
      assert mid == admin.membership.id
      assert {:ok, _} = create_for(admin, admin.membership, :member, :admin)
    end

    test "RED: minter_role may not exceed the bound membership's CURRENT role (an admin claiming :owner via an owner-scoped actor)" do
      r = register!()
      admin = member_of(r, :admin)

      # the scope CLAIMS owner, the membership row says admin: the row wins
      assert {:error, _} = create_for(admin, admin.membership, :owner, :owner)
      assert {:ok, _} = create_for(admin, admin.membership, :admin, :owner)
    end

    test "RED: a key cannot be bound to a membership that is no longer active" do
      r = register!()
      admin = member_of(r, :admin)

      admin.membership
      |> Ash.Changeset.for_update(:update, %{status: "suspended"}, authorize?: false)
      |> Ash.update!()

      assert {:error, _} = create_for(admin, admin.membership, :admin)
    end

    test "RED: a key must carry a minter_role (a role-less key is refused at create)" do
      r = register!()
      assert {:error, _} = direct_create(r, :admin, %{minter_role: nil})
    end

    test "RED: an admin cannot raise an existing key's minter_role to :owner" do
      r = register!()
      row = mint!(r, :admin)

      assert {:error, _} = key_update(row, :update, %{minter_role: :owner}, scope(r, :admin))
      assert Ash.get!(ApiKey, row.id, authorize?: false).minter_role == :admin
    end

    test "RED: an admin cannot un-revoke a key (revocation is one-way)" do
      r = register!()
      row = mint!(r, :admin)
      assert {:ok, revoked} = key_update(row, :revoke, %{}, scope(r, :admin))
      refute is_nil(revoked.revoked_at)

      assert {:error, _} = key_update(revoked, :update, %{revoked_at: nil}, scope(r, :admin))
      assert {:error, _} = key_update(revoked, :revoke, %{revoked_at: nil}, scope(r, :admin))
      assert Ash.get!(ApiKey, row.id, authorize?: false).revoked_at == revoked.revoked_at

      # a second revoke is idempotent and keeps the ORIGINAL revocation instant
      assert {:ok, again} = key_update(Ash.get!(ApiKey, row.id, authorize?: false), :revoke, %{}, scope(r, :admin))
      assert again.revoked_at == revoked.revoked_at
    end

    test "RED: revoking a row read WITHOUT revoked_at still revokes it (the action never trusts unloaded data)" do
      r = register!()
      row = mint!(r, :admin)
      partial = ApiKey |> Ash.Query.filter(id == ^row.id) |> Ash.Query.select([:id, :org_id]) |> Ash.read_one!(authorize?: false)
      assert %Ash.NotLoaded{} = partial.revoked_at

      assert {:ok, _} = key_update(partial, :revoke, %{}, scope(r, :admin))
      fresh = Ash.get!(ApiKey, row.id, authorize?: false)
      assert %DateTime{} = fresh.revoked_at
      assert [] = KeyScope.active_query(ApiKey, row.token_digest) |> Ash.read!(authorize?: false)

      # CONTROL: an already revoked row read the same partial way keeps its ORIGINAL instant
      partial2 = ApiKey |> Ash.Query.filter(id == ^row.id) |> Ash.Query.select([:id, :org_id]) |> Ash.read_one!(authorize?: false)
      assert {:ok, _} = key_update(partial2, :revoke, %{}, scope(r, :admin))
      assert Ash.get!(ApiKey, row.id, authorize?: false).revoked_at == fresh.revoked_at
    end

    test "POSITIVE CONTROL: an admin can revoke through :revoke; a member cannot" do
      r = register!()
      row = mint!(r, :admin)

      assert {:error, _} = key_update(row, :revoke, %{}, scope(r, :member))
      assert is_nil(Ash.get!(ApiKey, row.id, authorize?: false).revoked_at)
      assert {:ok, %{revoked_at: %DateTime{}}} = key_update(row, :revoke, %{}, scope(r, :admin))
    end

    test "RED: expiry is clamped on every write that sets it (default create and update)" do
      r = register!()
      far = DateTime.utc_now() |> DateTime.add(KeyScope.max_ttl_seconds() * 10, :second) |> DateTime.truncate(:second)
      ceiling = DateTime.add(DateTime.utc_now(), KeyScope.max_ttl_seconds() + 5, :second)

      assert {:ok, created} = direct_create(r, :admin, %{minter_role: :admin, expires_at: far})
      assert DateTime.compare(created.expires_at, ceiling) != :gt

      assert {:ok, no_expiry} = direct_create(r, :admin, %{minter_role: :admin})
      assert %DateTime{} = no_expiry.expires_at
      assert DateTime.compare(no_expiry.expires_at, ceiling) != :gt

      row = mint!(r, :admin)
      assert {:ok, updated} = key_update(row, :update, %{expires_at: far}, scope(r, :admin))
      assert DateTime.compare(updated.expires_at, ceiling) != :gt
    end

    test "POSITIVE CONTROL: a shorter requested expiry is kept as requested" do
      r = register!()
      soon = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      assert {:ok, created} = direct_create(r, :admin, %{minter_role: :admin, expires_at: soon})
      assert created.expires_at == soon
    end

    test "RED: an admin cannot EXTEND a live key by update (a later time, or nil) — update may only shorten" do
      r = register!()
      row = mint!(r, :admin)
      later = DateTime.add(row.expires_at, 30 * 86_400, :second)

      assert {:ok, same} = key_update(row, :update, %{expires_at: later}, scope(r, :admin))
      assert same.expires_at == row.expires_at
      assert Ash.get!(ApiKey, row.id, authorize?: false).expires_at == row.expires_at

      assert {:ok, kept} = key_update(row, :update, %{expires_at: nil}, scope(r, :admin))
      assert kept.expires_at == row.expires_at
      assert Ash.get!(ApiKey, row.id, authorize?: false).expires_at == row.expires_at
    end

    test "RED: an admin cannot extend an OWNER-rank key (and may shorten or revoke it)" do
      r = register!()
      owner_key = mint!(r, :owner)
      later = DateTime.add(owner_key.expires_at, 30 * 86_400, :second)

      assert {:ok, same} = key_update(owner_key, :update, %{expires_at: later}, scope(r, :admin))
      assert same.expires_at == owner_key.expires_at
      assert {:ok, same2} = key_update(owner_key, :update, %{expires_at: nil}, scope(r, :admin))
      assert same2.expires_at == owner_key.expires_at

      # no gain for the admin: shortening / revoking the owner's key is the permitted direction
      soon = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      assert {:ok, %{expires_at: ^soon}} = key_update(owner_key, :update, %{expires_at: soon}, scope(r, :admin))
      assert {:ok, %{revoked_at: %DateTime{}}} = key_update(owner_key, :revoke, %{}, scope(r, :admin))
    end

    test "RED: an expired key cannot be revived by update, and the shared lookup still refuses it" do
      r = register!()
      row = mint!(r, :owner)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, dead} = key_update(row, :update, %{expires_at: past}, scope(r, :owner))

      later = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

      for attrs <- [%{expires_at: nil}, %{expires_at: later}, %{expires_at: DateTime.add(past, -5, :second)}] do
        assert {:error, _} = key_update(dead, :update, attrs, scope(r, :admin))
        assert {:error, _} = key_update(dead, :update, attrs, scope(r, :owner))
      end

      fresh = Ash.get!(ApiKey, row.id, authorize?: false)
      assert fresh.expires_at == past
      assert [] = KeyScope.active_query(ApiKey, row.token_digest) |> Ash.read!(authorize?: false)
    end

    test "RED: a revoked key cannot be updated back to a live expiry" do
      r = register!()
      row = mint!(r, :admin)
      assert {:ok, revoked} = key_update(row, :revoke, %{}, scope(r, :admin))
      later = DateTime.add(row.expires_at, 86_400, :second)

      assert {:error, _} = key_update(revoked, :update, %{expires_at: later}, scope(r, :admin))
      assert {:error, _} = key_update(revoked, :update, %{expires_at: nil}, scope(r, :admin))
      assert [] = KeyScope.active_query(ApiKey, row.token_digest) |> Ash.read!(authorize?: false)
    end

    test "RED: a STALE struct cannot revive a key another actor already retired or revoked; CONTROL: a fresh struct still shortens" do
      r = register!()
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      # X holds K (expires T1); Y retires K early; X then "shortens" K to T1 - 1s, which the stale struct calls live
      stale = mint!(r, :admin)
      shorter = DateTime.add(stale.expires_at, -1, :second)
      assert {:ok, %{expires_at: ^past}} = key_update(stale, :update, %{expires_at: past}, scope(r, :owner))

      assert {:error, _} = key_update(stale, :update, %{expires_at: shorter}, scope(r, :admin))
      assert Ash.get!(ApiKey, stale.id, authorize?: false).expires_at == past
      assert [] = KeyScope.active_query(ApiKey, stale.token_digest) |> Ash.read!(authorize?: false)

      # the same through a revoke: X's struct still says "not revoked"
      stale2 = mint!(r, :admin)
      original = stale2.expires_at
      assert {:ok, %{revoked_at: %DateTime{}}} = key_update(stale2, :revoke, %{}, scope(r, :owner))
      assert {:error, _} = key_update(stale2, :update, %{expires_at: DateTime.add(original, -1, :second)}, scope(r, :admin))
      assert Ash.get!(ApiKey, stale2.id, authorize?: false).expires_at == original

      # a stale struct holding a SOONER expiry than the database never writes a later one either
      live = mint!(r, :admin)
      sooner = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      assert {:ok, %{expires_at: ^sooner}} = key_update(live, :update, %{expires_at: sooner}, scope(r, :owner))
      assert {:ok, kept} = key_update(live, :update, %{expires_at: DateTime.add(sooner, 600, :second)}, scope(r, :admin))
      assert kept.expires_at == sooner
      assert Ash.get!(ApiKey, live.id, authorize?: false).expires_at == sooner

      # CONTROL: a fresh struct shortens a live key
      fresh = mint!(r, :admin)
      shorter_ok = DateTime.add(fresh.expires_at, -120, :second)
      assert {:ok, %{expires_at: ^shorter_ok}} = key_update(fresh, :update, %{expires_at: shorter_ok}, scope(r, :admin))
    end

    test "a legacy row with a nil expiry may be given an expiry (clamped), and only shortened after" do
      r = register!()
      row = mint!(r, :admin)

      legacy =
        row
        |> Ash.Changeset.for_update(:mark_used, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:expires_at, nil)
        |> Ash.update!(authorize?: false)

      assert is_nil(legacy.expires_at)
      far = DateTime.utc_now() |> DateTime.add(KeyScope.max_ttl_seconds() * 10, :second) |> DateTime.truncate(:second)
      ceiling = DateTime.add(DateTime.utc_now(), KeyScope.max_ttl_seconds() + 5, :second)

      assert {:ok, bounded} = key_update(legacy, :update, %{expires_at: far}, scope(r, :admin))
      assert DateTime.compare(bounded.expires_at, ceiling) != :gt
      assert {:ok, still} = key_update(bounded, :update, %{expires_at: far}, scope(r, :admin))
      assert still.expires_at == bounded.expires_at
    end

    test "POSITIVE CONTROL: an update to a PAST expiry retires a live key early (update only ever shortens)" do
      r = register!()
      row = mint!(r, :admin)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      assert {:ok, updated} = key_update(row, :update, %{expires_at: past}, scope(r, :admin))
      assert updated.expires_at == past
      assert KeyScope.expired?(updated, DateTime.utc_now())
    end

    test "RED: token_digest, plane and scopes are not writable after mint" do
      r = register!()
      row = mint!(r, :admin)

      for attrs <- [%{token_digest: "x"}, %{plane: :operator}, %{scopes: %{all: [:read, :write]}}] do
        assert {:error, _} = key_update(row, :update, attrs, scope(r, :admin))
      end

      fresh = Ash.get!(ApiKey, row.id, authorize?: false)
      assert fresh.plane == :tenant and fresh.scopes == row.scopes and fresh.token_digest == row.token_digest
    end
  end

  # ===========================================================================
  # C. The shared key lookup
  # ===========================================================================

  describe "C. Samen.Scope.ApiKey.active_query/3 is the one auth lookup" do
    defp lookup(digest), do: Samen.Scope.ApiKey.active_query(ApiKey, digest) |> Ash.read!(authorize?: false)

    test "RED: a revoked key and an expired key are never resolved; CONTROL: a live key and a legacy nil-expiry key are" do
      r = register!()
      s = scope(r, :admin)

      seed = fn digest, attrs ->
        ApiKey
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: r.org.id, membership_id: r.membership.id, minter_role: :admin},
          scope: s
        )
        |> Ash.Changeset.force_change_attribute(:token_digest, digest)
        |> Ash.create!(scope: s)
        |> then(fn row ->
          Enum.reduce(attrs, Ash.Changeset.for_update(row, :mark_used, %{}, authorize?: false), fn {k, v}, cs ->
            Ash.Changeset.force_change_attribute(cs, k, v)
          end)
        end)
        |> Ash.update!(authorize?: false)
      end

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      seed.("d-live", %{})
      seed.("d-expired", %{expires_at: past})
      seed.("d-revoked", %{revoked_at: past})
      seed.("d-legacy", %{expires_at: nil})

      assert [_] = lookup("d-live")
      assert [] = lookup("d-expired")
      assert [] = lookup("d-revoked")
      assert [_] = lookup("d-legacy")
    end

    test "acting_role/1 refuses a role-less or out-of-set key and accepts a real one" do
      assert :error = Samen.Scope.ApiKey.acting_role(%{minter_role: nil})
      assert :error = Samen.Scope.ApiKey.acting_role(%{minter_role: :root})
      assert {:ok, :member} = Samen.Scope.ApiKey.acting_role(%{minter_role: :member})
    end
  end

  # ===========================================================================
  # D. Org update / destroy need a role
  # ===========================================================================

  describe "D. Org update needs admin, destroy needs owner; plan is not tenant-writable" do
    defp org_scope(org, role),
      do: %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org.id, role: role, verified?: true, kind: :tenant, plane: :tenant}}

    defp bare_org! do
      Org |> Ash.Changeset.for_create(:create, %{name: "Bare #{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create!()
    end

    defp org_update(org, attrs, role) do
      s = org_scope(org, role)
      org |> Ash.Changeset.for_update(:update, attrs, scope: s) |> Ash.update(scope: s)
    end

    test "RED: a viewer cannot update its org's settings; CONTROL: an admin can rename it" do
      org = bare_org!()

      assert {:error, _} = org_update(org, %{max_concurrent_sessions: 1}, :viewer)
      assert {:error, _} = org_update(org, %{name: "Pwned"}, :member)
      assert Ash.get!(Org, org.id, authorize?: false).name == org.name

      assert {:ok, %{name: "Renamed"}} = org_update(org, %{name: "Renamed"}, :admin)
      assert {:ok, %{max_concurrent_sessions: 3}} = org_update(org, %{max_concurrent_sessions: 3}, :owner)
    end

    test "RED: no tenant actor can write `plan` or `onboarded_at` as input, whatever its role" do
      org = bare_org!()

      for role <- [:viewer, :admin, :owner] do
        assert {:error, _} = org_update(org, %{plan: "enterprise-free-forever"}, role)
        assert {:error, _} = org_update(org, %{onboarded_at: DateTime.utc_now()}, role)
      end

      assert Ash.get!(Org, org.id, authorize?: false).plan == "free"
    end

    test "RED: Org :create takes name and slug only (plan, onboarded_at and org_id are not input); CONTROL: name + slug work" do
      for attrs <- [%{plan: "enterprise"}, %{onboarded_at: DateTime.utc_now()}, %{org_id: Ash.UUID.generate()}] do
        assert {:error, _} =
                 Org
                 |> Ash.Changeset.for_create(:create, Map.merge(%{name: "Sneaky #{System.unique_integer([:positive])}"}, attrs))
                 |> Ash.create()
      end

      assert {:ok, %{plan: "free", onboarded_at: nil, org_id: nil, slug: slug}} =
               Org
               |> Ash.Changeset.for_create(:create, %{name: "Plain #{System.unique_integer([:positive])}", slug: "plain-#{System.unique_integer([:positive])}"})
               |> Ash.create()

      assert is_binary(slug)
    end

    test "RED: Org :open_account (plan + org_id) is refused unless the actor is scoped to the org it files under AND the operator console vouched" do
      op = bare_org!()
      other = bare_org!()
      attrs = %{name: "Acct #{System.unique_integer([:positive])}", plan: "growth", org_id: op.id}
      create = fn scope, context ->
        Org |> Ash.Changeset.for_create(:open_account, attrs, scope: scope, context: context) |> Ash.create(scope: scope)
      end

      vouched = %{samen_operator_write: true}

      # another org's actor, no actor: refused even with the flag
      assert {:error, _} = create.(org_scope(other, :member), vouched)
      assert {:error, _} = create.(%Samen.Scope{actor: nil}, vouched)

      # a TENANT actor of the very org (viewer/member/admin/owner) calling the action directly, no console flag: refused
      for role <- [:viewer, :member, :admin, :owner] do
        assert {:error, _} = create.(org_scope(op, role), %{}), "#{role} must not open an account directly"
        assert {:error, _} = create.(org_scope(op, role), %{samen_operator_write: false})
      end

      assert Ash.count!(Org, authorize?: false) == 2

      # CONTROL: the console's call (synthetic :member scope of the operator org + the flag it sets after its role check)
      assert {:ok, %{plan: "growth", org_id: org_id}} = create.(org_scope(op, :member), vouched)
      assert org_id == op.id
    end

    test "RED: Org :open_account refuses a slug that is another org's slug or id; CONTROL: a fresh slug opens" do
      op = bare_org!()
      s = org_scope(op, :member)
      open = fn slug ->
        Org
        |> Ash.Changeset.for_create(:open_account, %{name: "A #{System.unique_integer([:positive])}", slug: slug, org_id: op.id}, scope: s, context: %{samen_operator_write: true})
        |> Ash.create(scope: s)
      end

      assert {:ok, first} = open.("acme-tenant")
      assert {:error, _} = open.("acme-tenant")
      assert {:error, _} = open.(first.id)
      assert {:error, _} = open.(op.id)
      assert {:ok, _} = open.("another-tenant")
    end

    test "RED: a viewer/member/admin cannot destroy the org; CONTROL: an owner can; another org's owner cannot" do
      org = bare_org!()
      other = bare_org!()

      for role <- [:viewer, :member, :admin] do
        s = org_scope(org, role)
        assert {:error, _} = org |> Ash.Changeset.for_destroy(:destroy, %{}, scope: s) |> Ash.destroy(scope: s)
      end

      s = org_scope(other, :owner)
      assert {:error, _} = org |> Ash.Changeset.for_destroy(:destroy, %{}, scope: s) |> Ash.destroy(scope: s)
      assert Ash.get!(Org, org.id, authorize?: false)

      s = org_scope(org, :owner)
      assert :ok = org |> Ash.Changeset.for_destroy(:destroy, %{}, scope: s) |> Ash.destroy(scope: s)
      assert {:error, _} = Ash.get(Org, org.id, authorize?: false)
    end

    test "POSITIVE CONTROL: the onboarding plan step (owner) still selects an OFFERED plan, and refuses an unoffered one" do
      r = register!()
      mount = Samen.Web.Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant(), labels: %{plan_labels: {__MODULE__, :plans, []}})
      s = scope(r, :owner)

      assert {:ok, %{plan: "pro"}} = Samen.Web.Onboarding.select_plan(mount, s, r.org.id, "pro")
      assert {:error, :invalid_plan} = Samen.Web.Onboarding.select_plan(mount, s, r.org.id, "enterprise-free-forever")
      assert {:ok, %{onboarded_at: %DateTime{}}} = Samen.Web.Onboarding.complete!(mount, s, r.org.id)
    end
  end

  # ===========================================================================
  # E. A row's org (and a membership's user) cannot be rewritten by the generic update
  # ===========================================================================

  describe "E. Membership/User/Role :update cannot move a row to another org" do
    defp org_of(mod, id), do: mod |> Ash.Query.filter(id == ^id) |> Ash.Query.ensure_selected([:org_id]) |> Ash.read!(authorize?: false) |> hd() |> Map.fetch!(:org_id)

    defp mk_org_member(role) do
      r = register!()
      # a second user in the registrant's org holding `role`
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "e-#{System.unique_integer([:positive])}"}, authorize?: false)
        |> Ash.create!()

      mbr = Membership |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: role}, authorize?: false) |> Ash.create!()
      {r, user, mbr}
    end

    test "RED: an admin cannot move a lower-ranked membership to another org or re-point its user; CONTROL: role and status changes still work" do
      {r, user, mbr} = mk_org_member(:member)
      other = register!()
      s = scope(r, :admin)
      upd = fn attrs -> mbr |> Ash.Changeset.for_update(:update, attrs, scope: s) |> Ash.update(scope: s) end

      assert {:error, _} = upd.(%{org_id: other.org.id})
      assert {:error, _} = upd.(%{user_id: other.user.id})
      assert org_of(Membership, mbr.id) == r.org.id
      assert reread(Membership, mbr.id).user_id == user.id

      # CONTROL: role/status keep working, under the same ManageRole rule (an admin may set :member/:viewer, never :owner)
      assert {:ok, %{role: :viewer}} = upd.(%{role: :viewer})
      assert {:ok, %{status: "suspended"}} = upd.(%{status: "suspended"})
      assert {:error, _} = upd.(%{role: :owner})
    end

    test "RED: an admin cannot update a User or Role into another org; CONTROL: the row still updates in place" do
      {r, user, _mbr} = mk_org_member(:member)
      other = register!()
      s = scope(r, :admin)

      assert {:error, _} = user |> Ash.Changeset.for_update(:update, %{org_id: other.org.id}, scope: s) |> Ash.update(scope: s)
      assert org_of(User, user.id) == r.org.id
      assert {:ok, %{handle: "renamed-e"}} = user |> Ash.Changeset.for_update(:update, %{handle: "renamed-e"}, scope: s) |> Ash.update(scope: s)

      role =
        Samen.WebTest.Operator.Role
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, name: :member, rank: 1, label: "M"}, authorize?: false)
        |> Ash.create!()

      assert {:error, _} = role |> Ash.Changeset.for_update(:update, %{org_id: other.org.id}, scope: s) |> Ash.update(scope: s)
      assert org_of(Samen.WebTest.Operator.Role, role.id) == r.org.id
      assert {:ok, %{label: "Renamed"}} = role |> Ash.Changeset.for_update(:update, %{label: "Renamed"}, scope: s) |> Ash.update(scope: s)
    end
  end

  describe "F. membership_for_user is deterministic: the LOWEST-ranked active membership wins" do
    test "RED: a user holding an owner and a viewer membership in one org resolves the viewer, in either insertion order; CONTROL: one membership resolves as is" do
      for order <- [[:owner, :viewer], [:viewer, :owner]] do
        r = register!()
        user = User |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "dup-#{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create!()

        for role <- order do
          Membership |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: role}, authorize?: false) |> Ash.create!()
        end

        for _ <- 1..3 do
          assert {:ok, %{role: :viewer}} = Samen.Scope.ApiKey.membership_for_user(Membership, r.org.id, user.id)
        end
      end

      r = register!()
      assert {:ok, %{role: :owner}} = Samen.Scope.ApiKey.membership_for_user(Membership, r.org.id, r.user.id)
      assert :error = Samen.Scope.ApiKey.membership_for_user(Membership, Ash.UUID.generate(), r.user.id)
    end
  end

  def plans(_org_id), do: [%{key: "free", label: "Free"}, %{key: "pro", label: "Pro"}]
end
