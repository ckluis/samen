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

  # A pre-existing duplicate membership for (org, user), as an older database may hold one. It is written by moving
  # a freshly created row's `user_id` with raw SQL, because `Membership :create` now refuses a second row.
  defp dup_membership!(org_id, user_id, role) do
    donor =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "dup-#{System.unique_integer([:positive])}"}, authorize?: false)
      |> Ash.create!()

    row = Membership |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: donor.id, role: role}, authorize?: false) |> Ash.create!()
    table = AshPostgres.DataLayer.Info.table(Membership)
    col = fn name -> Ash.Resource.Info.attribute(Membership, name).source |> to_string() end

    Repo.query!("UPDATE #{table} SET #{col.(:user_id)} = $1 WHERE #{col.(:id)} = $2", [Ecto.UUID.dump!(user_id), Ecto.UUID.dump!(row.id)])
    reread(Membership, row.id)
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
          %{org_id: r.org.id, membership_id: r.membership.id, minter_role: :admin, scopes: %{"all" => ["read"]}},
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

    defp mk_org_member(role, r \\ nil) do
      r = r || register!()
      # a second user in the registrant's org holding `role`
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "e-#{System.unique_integer([:positive])}"}, authorize?: false)
        |> Ash.create!()

      mbr = Membership |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: role}, authorize?: false) |> Ash.create!()
      {r, user, mbr}
    end

    # The input is not an input of the action at all (`NoSuchInput`), which is what the accept-list guarantees: a
    # widened accept-list would turn this into the org_id pin's refusal (an `InvalidAttribute`) or into no error.
    defp assert_not_accepted({:error, %Ash.Error.Invalid{errors: errors}}, input) do
      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: ^input}, &1)),
             "expected #{inspect(input)} to be refused as an unknown input, got: #{inspect(Enum.map(errors, & &1.__struct__))}"
    end

    defp assert_not_accepted(other, input), do: flunk("expected #{inspect(input)} to be refused as an unknown input, got: #{inspect(other)}")

    test "RED: an admin cannot move a lower-ranked membership to another org or re-point its user; CONTROL: role and status changes still work" do
      {r, user, mbr} = mk_org_member(:member)
      {_r, same_org_user, _same_org_mbr} = mk_org_member(:viewer, r)
      other = register!()
      s = scope(r, :admin)
      upd = fn attrs -> mbr |> Ash.Changeset.for_update(:update, attrs, scope: s) |> Ash.update(scope: s) end

      # (the accept-list, not the org_id pin or SameOrgFk, is what refuses each of these)
      assert_not_accepted(upd.(%{org_id: other.org.id}), :org_id)
      assert_not_accepted(upd.(%{user_id: other.user.id}), :user_id)
      assert org_of(Membership, mbr.id) == r.org.id
      assert reread(Membership, mbr.id).user_id == user.id

      # ... including a re-point to another user of the SAME org, which no cross-org check could ever catch
      assert_not_accepted(upd.(%{user_id: same_org_user.id}), :user_id)
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

      assert_not_accepted(user |> Ash.Changeset.for_update(:update, %{org_id: other.org.id}, scope: s) |> Ash.update(scope: s), :org_id)
      assert org_of(User, user.id) == r.org.id
      assert {:ok, %{handle: "renamed-e"}} = user |> Ash.Changeset.for_update(:update, %{handle: "renamed-e"}, scope: s) |> Ash.update(scope: s)

      role =
        Samen.WebTest.Operator.Role
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, name: :member, rank: 1, label: "M"}, authorize?: false)
        |> Ash.create!()

      assert_not_accepted(role |> Ash.Changeset.for_update(:update, %{org_id: other.org.id}, scope: s) |> Ash.update(scope: s), :org_id)
      assert org_of(Samen.WebTest.Operator.Role, role.id) == r.org.id
      assert {:ok, %{label: "Renamed"}} = role |> Ash.Changeset.for_update(:update, %{label: "Renamed"}, scope: s) |> Ash.update(scope: s)
    end
  end

  describe "F. membership_for_user is deterministic: the LOWEST-ranked active membership wins" do
    test "RED: a user holding an owner and a viewer membership in one org resolves the viewer, in either insertion order; CONTROL: one membership resolves as is" do
      for order <- [[:owner, :viewer], [:viewer, :owner]] do
        r = register!()
        user = User |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "dup-#{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create!()

        [first, second] = order
        Membership |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: first}, authorize?: false) |> Ash.create!()
        dup_membership!(r.org.id, user.id, second)

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

  # ===========================================================================
  # G. User :update / :destroy / :create are not gated on org scope alone
  # ===========================================================================

  describe "G. User writes follow the role model: a user edits their own profile; everything else is a strictly-below manage" do
    defp mk_user(r, role, handle) do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: handle}, authorize?: false)
        |> Ash.create!()

      Membership |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: role}, authorize?: false) |> Ash.create!()
      user
    end

    defp as_user(r, user, role),
      do: %Samen.Scope{actor: %{id: user.id, org_id: r.org.id, role: role, verified?: true, kind: :tenant, plane: :tenant}}

    defp upd(user, attrs, s), do: user |> Ash.Changeset.for_update(:update, attrs, scope: s) |> Ash.update(scope: s)

    test "RED: a viewer or member cannot edit another user's handle or status; CONTROL: they edit their own handle" do
      r = register!()
      victim = mk_user(r, :member, "g-victim")
      viewer = mk_user(r, :viewer, "g-viewer")
      member = mk_user(r, :member, "g-member")

      for {u, role} <- [{viewer, :viewer}, {member, :member}] do
        s = as_user(r, u, role)
        assert {:error, _} = upd(victim, %{handle: "hijacked-#{role}"}, s)
        assert {:error, _} = upd(victim, %{status: "suspended"}, s)
      end

      assert reread(User, victim.id).handle == "g-victim"
      assert reread(User, victim.id).status == "active"

      # CONTROL: self-edit of the profile fields
      assert {:ok, %{handle: "g-viewer-2"}} = upd(viewer, %{handle: "g-viewer-2"}, as_user(r, viewer, :viewer))
      assert {:ok, %{handle: "g-member-2"}} = upd(member, %{handle: "g-member-2"}, as_user(r, member, :member))
    end

    test "RED: nobody changes their OWN status (a member cannot reactivate or suspend itself); an admin does so only for a lower rank" do
      r = register!()
      member = mk_user(r, :member, "g-self")
      admin = mk_user(r, :admin, "g-admin")
      other_admin = mk_user(r, :admin, "g-admin2")

      assert {:error, _} = upd(member, %{status: "suspended"}, as_user(r, member, :member))
      assert {:error, _} = upd(admin, %{status: "suspended"}, as_user(r, admin, :admin))
      assert reread(User, member.id).status == "active"

      # an admin may not suspend a peer; may suspend a member (CONTROL)
      assert {:error, _} = upd(other_admin, %{status: "suspended"}, as_user(r, admin, :admin))
      assert {:ok, %{status: "suspended"}} = upd(member, %{status: "suspended"}, as_user(r, admin, :admin))

      # the suspended member cannot reactivate itself
      assert {:error, _} = upd(reread(User, member.id), %{status: "active"}, as_user(r, member, :member))
      assert reread(User, member.id).status == "suspended"
    end

    test "RED: an admin cannot edit the owner; CONTROL: the owner edits an admin" do
      r = register!()
      admin = mk_user(r, :admin, "g-adm")
      owner_user = reread(User, r.user.id)

      assert {:error, _} = upd(owner_user, %{handle: "pwned"}, as_user(r, admin, :admin))
      assert reread(User, r.user.id).handle != "pwned"
      assert {:ok, %{handle: "renamed-by-owner"}} = upd(admin, %{handle: "renamed-by-owner"}, scope(r, :owner))
    end

    test "RED: a viewer or member cannot destroy a user, nobody destroys themselves; CONTROL: an admin destroys a member" do
      r = register!()
      viewer = mk_user(r, :viewer, "g-del-viewer")
      admin = mk_user(r, :admin, "g-del-admin")
      # users WITHOUT a membership row, so a refusal here is the policy and not the membership FK
      bare = fn h -> User |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: h}, authorize?: false) |> Ash.create!() end
      victim = bare.("g-del")

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(victim, scope: as_user(r, viewer, :viewer))
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(victim, scope: as_user(r, victim, :member))
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(admin, scope: as_user(r, admin, :admin))
      assert reread(User, victim.id)

      assert :ok = Ash.destroy(victim, scope: as_user(r, admin, :admin))
      assert reread(User, victim.id) == nil
    end

    test "RED: a viewer or member cannot create a user row (and so cannot link one to a credential); CONTROL: an admin can" do
      r = register!()
      viewer = mk_user(r, :viewer, "g-c-viewer")
      create = fn s -> User |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "g-new"}, scope: s) |> Ash.create(scope: s) end

      assert {:error, _} = create.(as_user(r, viewer, :viewer))
      assert {:ok, _} = create.(scope(r, :admin))
    end

    test "RED: a target with no id (the template record of a bulk or query-based write) is refused, even for an admin" do
      r = register!()
      lower = mk_user(r, :member, "g-template-lower")
      admin = scope(r, :admin).actor
      match = fn data -> Samen.Policy.ManageUser.match?(admin, %{changeset: Ash.Changeset.for_update(data, :update, %{handle: "bulk"}, authorize?: false)}, membership: Membership) end

      # No id: the target's rank cannot be looked up, so it must not read as "a viewer an admin may manage"
      assert {:ok, false} = match.(struct(User, id: nil, org_id: r.org.id))
      # an actor whose own id is blank must not "own" a row with no id either
      assert {:ok, false} = Samen.Policy.ManageUser.match?(%{admin | id: nil}, %{changeset: Ash.Changeset.for_update(struct(User, id: nil, org_id: r.org.id), :update, %{handle: "bulk"}, authorize?: false)}, membership: Membership)

      # CONTROL: the same admin over a real, lower-ranked row is allowed
      assert {:ok, true} = match.(User |> Ash.Query.filter(id == ^lower.id) |> Ash.read_one!(authorize?: false))
    end

    test "CONTROL: Membership :destroy and Role writes keep their rank / admin gates (they were already closed)" do
      r = register!()
      member = mk_user(r, :member, "g-m-destroy")
      viewer = mk_user(r, :viewer, "g-m-viewer")
      mbr = Membership |> Ash.Query.filter(user_id == ^member.id) |> Ash.read!(authorize?: false) |> hd()

      assert {:error, _} = Ash.destroy(mbr, scope: as_user(r, viewer, :viewer))
      assert {:error, _} =
               Samen.WebTest.Operator.Role
               |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, name: :member, rank: 1, label: "M"}, scope: as_user(r, viewer, :viewer))
               |> Ash.create(scope: as_user(r, viewer, :viewer))

      assert :ok = Ash.destroy(mbr, scope: scope(r, :admin))
    end
  end

  describe "H. A membership write must out-rank BOTH the stored role and the role being set" do
    defp h_member(r, role) do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "h-#{System.unique_integer([:positive])}"}, authorize?: false)
        |> Ash.create!()

      Membership |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user.id, role: role}, authorize?: false) |> Ash.create!()
    end

    defp h_mbr_of(r, user_id), do: Membership |> Ash.Query.filter(user_id == ^user_id and org_id == ^r.org.id) |> Ash.read!(authorize?: false) |> hd()

    defp h_upd(mbr, attrs, s), do: mbr |> Ash.Changeset.for_update(:update, attrs, scope: s) |> Ash.update(scope: s)

    test "RED: an admin cannot demote or suspend an owner or a peer admin (role, status, or both in one write); CONTROL: it can demote a member" do
      r = register!()
      owner = h_mbr_of(r, r.user.id)
      peer_admin = h_member(r, :admin)
      admin = scope(r, :admin)

      for {target, label} <- [{owner, "owner"}, {peer_admin, "peer admin"}],
          attrs <- [%{role: :member}, %{role: :viewer, status: "suspended"}, %{status: "suspended"}, %{role: :admin}] do
        result = h_upd(target, attrs, admin)
        assert match?({:error, _}, result), "an admin must not write #{inspect(attrs)} onto the #{label}"
      end

      assert reread(Membership, owner.id) |> Map.take([:role, :status]) == %{role: :owner, status: "active"}
      assert reread(Membership, peer_admin.id) |> Map.take([:role, :status]) == %{role: :admin, status: "active"}

      member = h_member(r, :member)
      assert {:ok, %{role: :viewer}} = h_upd(member, %{role: :viewer}, admin)
      assert {:ok, %{status: "suspended"}} = h_upd(member, %{status: "suspended"}, admin)
    end

    test "RED: the stored role is read from the database, not the record in hand (a stale or partially loaded struct cannot hide a promotion)" do
      r = register!()
      member = h_member(r, :member)
      stale = reread(Membership, member.id)
      # the row is promoted to admin behind the struct's back
      {:ok, _} = h_upd(member, %{role: :admin}, scope(r, :owner))
      admin = scope(r, :admin)

      assert %{role: :member} = stale
      assert {:error, _} = h_upd(stale, %{role: :viewer}, admin)
      assert reread(Membership, member.id).role == :admin

      unloaded = %{stale | role: %Ash.NotLoaded{field: :role, type: :attribute}}
      assert {:error, _} = h_upd(unloaded, %{status: "suspended"}, admin)
      assert reread(Membership, member.id).status == "active"

      # CONTROL: an owner may still manage that admin, through the same stale struct
      assert {:ok, %{role: :member}} = h_upd(stale, %{role: :member}, scope(r, :owner))
    end

    test "RED: an owner cannot demote, suspend or remove another owner (Role.may_manage?/2 is strict: no lateral management); CONTROL: it manages an admin" do
      r = register!()
      co_owner = h_member(r, :owner)
      owner = scope(r, :owner)

      assert {:error, _} = h_upd(co_owner, %{role: :admin}, owner)
      assert {:error, _} = h_upd(co_owner, %{status: "suspended"}, owner)
      assert {:error, _} = Ash.destroy(co_owner, scope: owner)
      assert reread(Membership, co_owner.id).role == :owner

      admin = h_member(r, :admin)
      assert {:ok, %{role: :member}} = h_upd(admin, %{role: :member}, owner)
    end

    test "RED: an admin cannot remove an owner or peer admin membership; CONTROL: a member" do
      r = register!()
      owner = h_mbr_of(r, r.user.id)
      peer = h_member(r, :admin)
      member = h_member(r, :member)
      admin = scope(r, :admin)

      assert {:error, _} = Ash.destroy(owner, scope: admin)
      assert {:error, _} = Ash.destroy(peer, scope: admin)
      assert :ok = Ash.destroy(member, scope: admin)
    end
  end

  describe "I. A membership that is not active confers no role and no org access" do
    alias Samen.Auth.SessionCreate
    alias Samen.Web.Auth, as: WebAuth
    alias Samen.Web.CurrentOrg
    alias Samen.Web.Mount
    alias Samen.Web.Plane
    alias Samen.WebTest.Operator.Session

    defp i_mount, do: Mount.new(:settings, Samen.WebTest.Operator, Repo, plane: Plane.tenant(), labels: %{authn: :required})

    # a credential that registered its own org (Y) and joins `host` (X) as a member through a real invitation
    defp i_join!(host, role) do
      guest = register!()
      {:ok, _inv, raw} = Invite.create(invite_mods(), scope(host, :owner), %{email: guest.email, role: role})
      {:ok, joined} = Invite.accept(invite_mods(), raw)
      {guest, joined.membership}
    end

    defp i_session!(guest) do
      {:ok, _row, raw} = SessionCreate.create(%{session: Session, org: Org, membership: Membership, user: User}, guest.credential.id)
      %{WebAuth.session_token_key() => raw}
    end

    test "RED: a suspended member's EXISTING session resolves no actor and no access to the org; CONTROL: active, and active again after reactivation" do
      host = register!()
      {guest, membership} = i_join!(host, :member)
      session = i_session!(guest)
      mount = i_mount()
      x = host.org.id
      y = guest.org.id
      admin = scope(host, :admin)

      # CONTROL: while active the same session holds the role and the org
      assert %{role: :member, org_id: ^x} = CurrentOrg.resolve_actor(mount, guest.credential.id, x)
      assert x in CurrentOrg.authorized_orgs(mount, session)
      assert CurrentOrg.resolve(mount, %{"org" => x}, session) == x

      assert {:ok, %{status: "suspended"}} = h_upd(membership, %{status: "suspended"}, admin)

      # the same session: no role, no org (its OWN org is untouched)
      assert CurrentOrg.resolve_actor(mount, guest.credential.id, x) == nil
      refute x in CurrentOrg.authorized_orgs(mount, session)
      assert y in CurrentOrg.authorized_orgs(mount, session)
      assert CurrentOrg.resolve(mount, %{"org" => x}, session) == y
      assert CurrentOrg.resolve_actor(mount, guest.credential.id, y).role == :owner

      assert {:ok, %{status: "active"}} = h_upd(reread(Membership, membership.id), %{status: "active"}, admin)
      assert %{role: :member} = CurrentOrg.resolve_actor(mount, guest.credential.id, x)
      assert x in CurrentOrg.authorized_orgs(mount, session)
    end

    test "RED: a suspended ADMIN keeps no authority (the role it held is not resolved); a PRE-EXISTING duplicate resolves the lowest ACTIVE row" do
      host = register!()
      {guest, membership} = i_join!(host, :admin)
      mount = i_mount()
      assert %{role: :admin} = CurrentOrg.resolve_actor(mount, guest.credential.id, host.org.id)

      {:ok, _} = h_upd(membership, %{status: "suspended"}, scope(host, :owner))
      assert CurrentOrg.resolve_actor(mount, guest.credential.id, host.org.id) == nil

      # a pre-existing second, ACTIVE, lower row for the same user (the create path now refuses to add one): that one
      # answers, never the suspended admin row
      dup_membership!(host.org.id, membership.user_id, :viewer)

      assert %{role: :viewer} = CurrentOrg.resolve_actor(mount, guest.credential.id, host.org.id)
    end

    test "CONTROL: ManageUser still ranks a SUSPENDED target (an admin cannot suspend an admin to get around the rank rule)" do
      host = register!()
      {_guest, membership} = i_join!(host, :admin)
      {:ok, _} = h_upd(membership, %{status: "suspended"}, scope(host, :owner))
      user = reread(User, membership.user_id)

      assert {:error, _} = upd(user, %{handle: "renamed-by-peer"}, scope(host, :admin))
      assert {:ok, _} = upd(user, %{handle: "renamed-by-owner"}, scope(host, :owner))
    end
  end

  describe "J. The session cap counts only LIVE sessions" do
    alias Samen.Auth.SessionCreate
    alias Samen.WebTest.Operator.Session

    defp j_mods, do: %{session: Session, org: Org, membership: Membership, user: User}

    defp j_capped_credential!(cap) do
      r = register!()

      Org
      |> Ash.get!(r.org.id, authorize?: false)
      |> Ash.Changeset.for_update(:update, %{max_concurrent_sessions: cap}, authorize?: false)
      |> Ash.update!()

      r
    end

    defp j_revoked?(id), do: reread(Session, id).revoked_at != nil

    test "RED: an abandoned EXPIRED session does not occupy a slot, so the live session is not evicted; CONTROL: two live sessions still evict the oldest" do
      r = j_capped_credential!(2)
      cred = r.credential.id

      {:ok, a, _} = SessionCreate.create(j_mods(), cred)
      {:ok, b_expired, _} = SessionCreate.create(j_mods(), cred, ttl_seconds: -60)
      {:ok, c, _} = SessionCreate.create(j_mods(), cred)

      refute j_revoked?(a.id), "the oldest LIVE session was revoked to make room for an expired one"
      refute j_revoked?(c.id)
      # the expired one is neither counted nor revoked on its behalf
      assert reread(Session, b_expired.id).expires_at < DateTime.utc_now()

      # CONTROL: now a and c are both live and the cap is 2: the next sign-in evicts the oldest live one (a)
      {:ok, d, _} = SessionCreate.create(j_mods(), cred)
      assert j_revoked?(a.id)
      refute j_revoked?(c.id)
      refute j_revoked?(d.id)
    end
  end

  describe "K. Every Invitation create yields a PENDING invitation with its expiry; status is not an input" do
    defp k_create(r, role, attrs) do
      s = scope(r, role)

      Invitation
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{org_id: r.org.id, role: :member, email: ["k-#{System.unique_integer([:positive])}@example.test"]}, attrs),
        scope: s
      )
      |> Ash.create(scope: s)
    end

    defp k_row(id), do: Invitation |> Ash.Query.filter(id == ^id) |> Ash.Query.select([:id, :status, :expires_at, :role]) |> Ash.read_one!(authorize?: false)

    test "RED: status is not an input of the generic create (accepted, revoked, junk); CONTROL: without one the row is pending with a 14-day expiry" do
      r = register!()

      for status <- ["accepted", "revoked", "expired", "junk"] do
        assert_not_accepted(k_create(r, :admin, %{status: status}), :status)
      end

      assert {:ok, inv} = k_create(r, :admin, %{})
      row = k_row(inv.id)
      assert row.status == "pending"
      assert %DateTime{} = row.expires_at
      assert DateTime.diff(row.expires_at, DateTime.utc_now(), :day) in 13..14
    end

    test "RED: a direct create (not through Invite.create) always carries the 14-day expiry" do
      r = register!()
      assert {:ok, inv} = k_create(r, :admin, %{})
      assert %DateTime{} = k_row(inv.id).expires_at
    end

    test "RED: expires_at is not an input of the generic create either" do
      r = register!()
      assert_not_accepted(k_create(r, :admin, %{expires_at: DateTime.add(DateTime.utc_now(), 10 * 365, :day)}), :expires_at)
    end

    test "CONTROL: Invite.create still yields a pending invitation with the 14-day expiry that can be accepted" do
      inviter = register!()
      invitee = register!()
      {:ok, inv, raw} = Invite.create(invite_mods(), scope(inviter, :admin), %{email: invitee.email, role: :member})
      row = k_row(inv.id)
      assert row.status == "pending"
      assert DateTime.diff(row.expires_at, DateTime.utc_now(), :day) in 13..14
      assert {:ok, %{status: :joined}} = Invite.accept(invite_mods(), raw)
    end
  end
  describe "L. An org's slug is unique on update and on the generic create" do
    defp l_org!(slug),
      do: Org |> Ash.Changeset.for_create(:create, %{name: "L #{slug}", slug: slug}, authorize?: false) |> Ash.create!()

    test "RED: an org admin cannot take another org's slug or id; CONTROL: a normal rename, and re-sending its own slug, work" do
      a = l_org!("l-a-#{System.unique_integer([:positive])}")
      b = l_org!("l-b-#{System.unique_integer([:positive])}")

      assert {:error, _} = org_update(a, %{slug: b.slug}, :admin)
      assert {:error, _} = org_update(a, %{slug: b.id}, :admin)
      assert Ash.get!(Org, a.id, authorize?: false).slug == a.slug

      fresh = "l-fresh-#{System.unique_integer([:positive])}"
      assert {:ok, %{slug: ^fresh}} = org_update(a, %{slug: fresh}, :admin)
      assert {:ok, %{slug: ^fresh}} = org_update(Ash.get!(Org, a.id, authorize?: false), %{slug: fresh}, :admin)
    end

    test "RED: the generic create refuses a taken slug; CONTROL: a free one works" do
      taken = l_org!("l-taken-#{System.unique_integer([:positive])}")

      assert {:error, _} = Org |> Ash.Changeset.for_create(:create, %{name: "Dup", slug: taken.slug}, authorize?: false) |> Ash.create()
      assert {:error, _} = Org |> Ash.Changeset.for_create(:create, %{name: "Dup", slug: taken.id}, authorize?: false) |> Ash.create()
      assert {:ok, _} = Org |> Ash.Changeset.for_create(:create, %{name: "Ok", slug: "l-free-#{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create()
    end
  end
  describe "L2. Slug uniqueness ignores case and surrounding whitespace, and never counts the org's own row" do
    test "RED: `Acme`, ` acme ` and `ACME` collide with `acme`, on update and on create; CONTROL: a different slug is free" do
      base = "l2-#{System.unique_integer([:positive])}"
      taken = l_org!(base)
      other = l_org!("l2-other-#{System.unique_integer([:positive])}")

      for variant <- [String.upcase(base), " #{base}", "#{base} ", " #{String.capitalize(base)} "] do
        assert {:error, _} = org_update(other, %{slug: variant}, :admin), "update accepted #{inspect(variant)}"

        assert {:error, _} =
                 Org |> Ash.Changeset.for_create(:create, %{name: "Dup", slug: variant}, authorize?: false) |> Ash.create(),
               "create accepted #{inspect(variant)}"
      end

      assert Ash.get!(Org, other.id, authorize?: false).slug == other.slug
      assert {:ok, _} = org_update(other, %{slug: "#{base}-two"}, :admin)
      assert taken.slug == base
    end

    test "RED: re-sending the org's own slug, or its own id, is never a self-collision even when `slug` is not loaded; another org's id is still refused" do
      a = l_org!("l2-a-#{System.unique_integer([:positive])}")
      b = l_org!("l2-b-#{System.unique_integer([:positive])}")
      # the record in hand was read without `slug`
      thin = Org |> Ash.Query.filter(id == ^a.id) |> Ash.Query.select([:id, :name]) |> Ash.read!(authorize?: false) |> hd()
      assert %Ash.NotLoaded{} = thin.slug

      assert {:ok, %{slug: slug}} = org_update(thin, %{slug: a.slug}, :admin)
      assert slug == a.slug
      assert {:ok, %{slug: id_slug}} = org_update(thin, %{slug: a.id}, :admin)
      assert id_slug == a.id
      assert {:error, _} = org_update(thin, %{slug: b.id}, :admin)
      assert {:error, _} = org_update(thin, %{slug: b.slug}, :admin)
    end
  end

  describe "M. ApiKey :mark_used is a system action" do
    test "RED: an authorized admin (or owner) cannot forge last_used_at; CONTROL: the auth path (no actor) still stamps it" do
      r = register!()
      key = mint!(r, :admin)
      forged = ~U[2020-01-01 00:00:00Z]

      for role <- [:admin, :owner] do
        s = scope(r, role)
        assert {:error, _} = key_update(key, :mark_used, %{last_used_at: forged}, s)
      end

      assert reread(ApiKey, key.id).last_used_at == nil

      stamped = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, _} =
               key |> Ash.Changeset.for_update(:mark_used, %{last_used_at: stamped}) |> Ash.update(authorize?: false)

      assert reread(ApiKey, key.id).last_used_at == stamped
    end
  end

  describe "N. A user holds ONE membership per org (a second, lower row would demote the owner)" do
    test "RED: an admin cannot add a second :viewer row for the owner or a peer admin; CONTROL: the owner still resolves as owner, and a fresh user can be added" do
      r = register!()
      peer = h_member(r, :admin)
      admin = scope(r, :admin)
      mods = %{user: User, membership: Membership}

      for {user_id, role} <- [{r.user.id, :owner}, {peer.user_id, :admin}] do
        assert {:error, _} =
                 Membership
                 |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: user_id, role: :viewer}, scope: admin)
                 |> Ash.create(scope: admin)

        rows = Membership |> Ash.Query.filter(user_id == ^user_id and org_id == ^r.org.id) |> Ash.read!(authorize?: false)
        assert [%{role: ^role}] = rows
        assert {:ok, %{role: ^role}} = Samen.Auth.OrgActor.active_membership(Membership, user_id, r.org.id)
      end

      assert %{role: :owner} = elem(Samen.Auth.OrgActor.resolve(%{user: User, membership: Membership}, r.credential.id, r.org.id), 1)
      _ = mods

      # CONTROL: a membership for a user that has none is still created
      fresh = User |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, handle: "n-#{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create!()

      assert {:ok, %{role: :viewer}} =
               Membership
               |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: fresh.id, role: :viewer}, scope: admin)
               |> Ash.create(scope: admin)
    end

    test "RED: the refusal also holds for authorize?: false creates, whatever the existing row's status" do
      r = register!()
      member = h_member(r, :member)
      {:ok, _} = h_upd(member, %{status: "suspended"}, scope(r, :owner))

      assert {:error, _} =
               Membership
               |> Ash.Changeset.for_create(:create, %{org_id: r.org.id, user_id: member.user_id, role: :viewer}, authorize?: false)
               |> Ash.create()

      assert Membership |> Ash.Query.filter(user_id == ^member.user_id) |> Ash.read!(authorize?: false) |> length() == 1
    end

    test "RED: a probe that cannot run is an ERROR, never `{:ok, false}` (fail closed); CONTROL: a readable probe answers true and false" do
      r = register!()
      probe = &Samen.Identity.OneMembership.exists?/3

      assert {:ok, true} = probe.(Membership, r.org.id, r.user.id)
      assert {:ok, false} = probe.(Membership, r.org.id, Ash.UUID.generate())

      # a value that cannot be dumped and a missing id: none of them reads as "free"
      assert {:error, _} = probe.(Membership, r.org.id, "not-a-uuid")
      assert {:error, _} = probe.(Membership, nil, r.user.id)
      assert {:error, _} = probe.(Membership, r.org.id, nil)
    end
  end

  describe "P. A role set through an atomic update is judged like any other role" do
    require Ash.Expr

    test "RED: an admin cannot make a member an owner through atomic_update(:role); CONTROL: a plain role write and an atomic non-role write still work" do
      r = register!()
      member = h_member(r, :member)
      admin = scope(r, :admin)

      result =
        member
        |> Ash.Changeset.for_update(:update, %{}, scope: admin)
        |> Ash.Changeset.atomic_update(:role, Ash.Expr.expr(if status == "active", do: ^:owner, else: role))
        |> Ash.update(scope: admin)

      assert {:error, _} = result
      assert reread(Membership, member.id).role == :member

      # the check itself ERRORS (fail closed, by name) rather than reading the stored role through `get_attribute`
      changeset =
        member
        |> Ash.Changeset.for_update(:update, %{}, scope: admin)
        |> Ash.Changeset.atomic_update(:role, Ash.Expr.expr(if status == "active", do: ^:owner, else: role))

      assert {:error, :atomic_role} = Samen.Policy.ManageRole.match?(admin.actor, %{changeset: changeset}, [])

      assert {:ok, %{role: :viewer}} = h_upd(member, %{role: :viewer}, admin)

      assert {:ok, %{status: "suspended"}} =
               reread(Membership, member.id)
               |> Ash.Changeset.for_update(:update, %{}, scope: admin)
               |> Ash.Changeset.atomic_update(:status, Ash.Expr.expr(^"suspended"))
               |> Ash.update(scope: admin)
    end
  end

  describe "Q. authorized_org_ids reads memberships once, not once per org" do
    alias Samen.Auth.OrgActor

    defp q_queries(fun) do
      parent = self()
      id = {:q_count, System.unique_integer([:positive])}

      :telemetry.attach(
        id,
        [:samen, :web_test, :repo, :query],
        fn _event, _measure, meta, _ -> send(parent, {id, meta.source}) end,
        nil
      )

      result = fun.()
      :telemetry.detach(id)
      {result, drain(id, [])}
    end

    defp drain(id, acc) do
      receive do
        {^id, source} -> drain(id, [source | acc])
      after
        0 -> acc
      end
    end

    test "RED: a credential in several orgs (one suspended) resolves the same orgs with ONE membership read; CONTROL: the result and the single-org case" do
      h1 = register!()
      h2 = register!()
      guest = register!()

      joined =
        for host <- [h1, h2] do
          {:ok, _inv, raw} = Invite.create(invite_mods(), scope(host, :owner), %{email: guest.email, role: :member})
          {:ok, j} = Invite.accept(invite_mods(), raw)
          j.membership
        end

      {:ok, _} = h_upd(List.last(joined), %{status: "suspended"}, scope(h2, :owner))
      mods = %{user: User, membership: Membership}
      membership_table = AshPostgres.DataLayer.Info.table(Membership)

      {result, sources} = q_queries(fn -> OrgActor.authorized_org_ids_result(mods, guest.credential.id) end)

      assert {:ok, ids} = result
      assert Enum.sort(ids) == Enum.sort([guest.org.id, h1.org.id])
      assert Enum.count(sources, &(&1 == membership_table)) == 1, "one membership read for all the credential's users, got #{inspect(sources)}"
      assert length(sources) == 2

      assert Enum.sort(OrgActor.authorized_org_ids(mods, guest.credential.id)) == Enum.sort(ids)

      # CONTROL: a credential in one org, and one in none
      assert {:ok, [only]} = OrgActor.authorized_org_ids_result(mods, h1.credential.id)
      assert only == h1.org.id
      assert {:ok, []} = OrgActor.authorized_org_ids_result(mods, Ash.UUID.generate())

      # the single statement of the rule still answers a suspended row as "none", an active one as the member
      assert :none = OrgActor.active_membership(Membership, List.last(joined).user_id, h2.org.id)
      assert {:ok, %{role: :member}} = OrgActor.active_membership(Membership, List.first(joined).user_id, h1.org.id)
    end
  end

  describe "O. A forged struct (own org_id, another org's primary key) cannot write another org's membership" do
    test "RED: update (role, status) and destroy are refused and the foreign row is unchanged; CONTROL: the admin's own org's row is writable" do
      a = register!()
      b = register!()
      foreign = h_member(b, :member)
      admin_a = scope(a, :admin)

      forged = %{foreign | org_id: a.org.id}

      assert {:error, _} = h_upd(forged, %{role: :viewer}, admin_a)
      assert {:error, _} = h_upd(forged, %{status: "suspended"}, admin_a)
      assert {:error, _} = Ash.destroy(forged, scope: admin_a)

      assert reread(Membership, foreign.id) |> Map.take([:role, :status]) == %{role: :member, status: "active"}
      in_b = Membership |> Ash.Query.filter(id == ^foreign.id and org_id == ^b.org.id) |> Ash.read!(authorize?: false)
      assert [_] = in_b

      own = h_member(a, :member)
      assert {:ok, %{role: :viewer}} = h_upd(own, %{role: :viewer}, admin_a)
    end
  end
end
