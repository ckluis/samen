defmodule Samen.Auth.OrgActor do
  @moduledoc """
  ADR-035 §5 A4's `CurrentOrg` paragraph (closed by the T05 binding addendum,
  `_orch/verify/T04-verdict.json` finding — the `:authorized_orgs`/CurrentOrg
  seam was in the ADR's A4 contract but owned by no task until T05, the
  natural completion point since invitation-accept is what first lands a
  credential into a second org's Membership).

  Resolves a spine CREDENTIAL (from `Samen.Web.Auth.resolve_principal/2`) to
  a PER-ORG ACTOR: the credential's linked `Identity.User` in a given org,
  plus that user's `Identity.Membership` ROLE. This is "`authorized_orgs`
  derives from the credential's linked Users' Memberships — closing the
  ADR-031 carry (the seam sources from real Membership rows, and the actor
  role is read from the Membership, not hardcoded `:member`)" — ADR-035 §3.1.

  A credential with NO `User`+`Membership` row in `org_id` resolves `:error`
  (deny) — the RED path: a credential with no membership in org X cannot
  resolve an actor there. A credential that DOES (e.g. right after accepting
  an invitation, which lands exactly this pair — `Samen.Identity.Invite`)
  resolves `{:ok, actor}` — the positive control.
  """

  require Ash.Query

  @type mods :: %{required(:user) => module(), required(:membership) => module()}

  @doc """
  Every org id `credential_id` holds a live `User` row in (deny — `[]` — when
  the credential has no linked `User` anywhere). Used to build the
  `:authorized_orgs` seam's return set.
  """
  @spec authorized_org_ids(mods(), String.t()) :: [String.t()]
  def authorized_org_ids(%{} = mods, credential_id) when is_binary(credential_id) do
    mods.user
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.Query.ensure_selected([:id, :org_id])
    # authz-scope: authorization-boundary read — enumerates the org ids this credential holds
    # live User rows in (unique credential key; deny-on-empty). This read BUILDS the
    # :authorized_orgs set everything else scopes by
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.org_id)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  def authorized_org_ids(_mods, _credential_id), do: []

  @doc """
  Resolve `credential_id` to its per-org ACTOR facts in `org_id`: `{:ok,
  %{user_id:, role:, org_id:}}`, or `:error` when the credential has no
  `User` (hence no `Membership`) in that org.
  """
  @spec resolve(mods(), String.t(), String.t()) ::
          {:ok, %{user_id: String.t(), role: atom(), org_id: String.t()}} | :error
  def resolve(%{} = mods, credential_id, org_id)
      when is_binary(credential_id) and is_binary(org_id) do
    with [user] <- find_user(mods, credential_id, org_id),
         [membership] <- find_membership(mods, user.id, org_id) do
      {:ok, %{user_id: user.id, role: membership.role, org_id: org_id}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def resolve(_mods, _credential_id, _org_id), do: :error

  defp find_user(mods, credential_id, org_id) do
    mods.user
    |> Ash.Query.filter(credential_id == ^credential_id and org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :org_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp find_membership(mods, user_id, org_id) do
    mods.membership
    |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :role])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end
end
