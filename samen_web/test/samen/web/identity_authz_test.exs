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
end
