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

    test "POSITIVE CONTROL: an update to a PAST expiry retires the key early (the clamp never extends a key)" do
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
end
