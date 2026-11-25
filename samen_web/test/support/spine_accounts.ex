defmodule Samen.WebTest.SpineAccounts do
  @moduledoc """
  Real accounts for the samen_web test host's identity spine (`Samen.WebTest.Operator`): `register!/0`
  (a tenant + owner through `Samen.Identity.Register`), `accept_into!/2` (an invitee who ACCEPTS a real
  invitation, so the membership row carries the role), `suspend!/2`, and `user_id/2`. Used by the tests
  that drive a real `POST /login` (`Samen.WebTest.SecurityEndpoint`) rather than a hand-built session.
  """
  require Ash.Query

  alias Samen.Auth.OrgActor
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.WebTest.Operator, as: Op

  @password "correct horse battery staple"

  @doc "The password every account registered here logs in with."
  def password, do: @password

  defp register_mods,
    do: %{org: Op.Org, credential: Op.Credential, user: Op.User, membership: Op.Membership, auth_token: Op.AuthToken, repo: Samen.WebTest.Repo}

  defp invite_mods,
    do: %{invitation: Op.Invitation, credential: Op.Credential, user: Op.User, membership: Op.Membership, repo: Samen.WebTest.Repo}

  @doc "Register a tenant (an org and its owner). The result carries the owner's `:email`."
  def register! do
    attrs = %{
      org_name: "Role Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "role-#{System.unique_integer([:positive])}@example.test",
      password: @password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  @doc "A new account that accepted a real invitation into `host`'s org with `role`."
  def accept_into!(host, role) do
    invitee = register!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    {:ok, _inv, raw_token} = Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})
    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  @doc "The per-org `Identity.User` id of `account` in `org_id`."
  def user_id(account, org_id) do
    {:ok, %{user_id: id}} = OrgActor.resolve(%{user: Op.User, membership: Op.Membership}, account.credential.id, org_id)
    id
  end

  @doc "Suspend `account`'s membership in `org_id` (an inactive membership gives no access)."
  def suspend!(account, org_id) do
    user_id = user_id(account, org_id)
    [m] = Op.Membership |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id) |> Ash.read!(authorize?: false)
    m |> Ash.Changeset.for_update(:update, %{status: "suspended"}, authorize?: false) |> Ash.update!()
  end
end
