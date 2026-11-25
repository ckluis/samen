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
  require Logger

  @type mods :: %{required(:user) => module(), required(:membership) => module()}

  @typedoc "A failed lookup is `{:error, :unavailable}`: neither \"the credential has no org\" nor \"it has one\" is known."
  @type result(t) :: {:ok, t} | {:error, :unavailable}

  @doc """
  Every org id `credential_id` holds a live `User` row AND an ACTIVE membership in (a suspended or invited
  membership gives no access to its org), as a TAGGED result: `{:ok, ids}` (an empty list is the
  honest \"no org anywhere\") or `{:error, :unavailable}` when the read itself failed (an outage, a decrypt
  failure). Nothing is swallowed and nothing is logged here — the caller owns the decision (the landing page
  answers 503; a tenant gate fails closed). Used to build the `:authorized_orgs` seam's return set.
  """
  @spec authorized_org_ids_result(mods(), String.t()) :: result([String.t()])
  def authorized_org_ids_result(mods, credential_id) do
    case fetch_org_ids(mods, credential_id) do
      {:ok, ids} -> {:ok, ids}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp fetch_org_ids(%{} = mods, credential_id) when is_binary(credential_id) do
    mods.user
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.Query.ensure_selected([:id, :org_id])
    # authz-scope: authorization-boundary read — enumerates the org ids this credential holds
    # live User rows in (unique credential key; deny-on-empty). This read BUILDS the
    # :authorized_orgs set everything else scopes by
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, users} -> active_org_ids(mods, users)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_org_ids(_mods, _credential_id), do: {:ok, []}

  @doc """
  The legacy shape of `authorized_org_ids_result/2`: the org ids, `[]` when the credential has none (deny) OR the
  read failed (fail closed). A failure is no longer silent: it is logged by name and exception module only
  (never the message, the query or a value).
  """
  @spec authorized_org_ids(mods(), String.t()) :: [String.t()]
  def authorized_org_ids(mods, credential_id) do
    case fetch_org_ids(mods, credential_id) do
      {:ok, ids} ->
        ids

      {:error, reason} ->
        report(:authorized_org_ids, reason)
        []
    end
  rescue
    e ->
      report(:authorized_org_ids, e)
      []
  end

  @doc """
  Resolve `credential_id` to its per-org ACTOR facts in `org_id` as a tagged result: `{:ok, %{user_id:, role:,
  org_id:}}`, `:error` when the credential has no `User` (hence no `Membership`) in that org, or `{:error,
  :unavailable}` when a read failed — a denial and an outage are different answers.
  """
  @spec resolve_result(mods(), String.t(), String.t()) ::
          {:ok, %{user_id: String.t(), role: atom(), org_id: String.t()}}
          | :error
          | {:error, :unavailable}
  def resolve_result(mods, credential_id, org_id) do
    case fetch_actor(mods, credential_id, org_id) do
      {:error, _reason} -> {:error, :unavailable}
      other -> other
    end
  end

  defp fetch_actor(%{} = mods, credential_id, org_id)
       when is_binary(credential_id) and is_binary(org_id) do
    with {:ok, users} <- find_user(mods, credential_id, org_id),
         [user] <- users,
         {:ok, membership} <- active_membership(mods.membership, user.id, org_id) do
      {:ok, %{user_id: user.id, role: membership.role, org_id: org_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> :error
    end
  end

  defp fetch_actor(_mods, _credential_id, _org_id), do: :error

  @doc """
  Resolve `credential_id` to its per-org ACTOR facts in `org_id`: `{:ok,
  %{user_id:, role:, org_id:}}`, or `:error` when the credential has no
  `User` (hence no `Membership`) in that org — and `:error` (deny, fail closed) when a read failed, which is
  logged by name and exception module. `resolve_result/3` tells the two apart.
  """
  @spec resolve(mods(), String.t(), String.t()) ::
          {:ok, %{user_id: String.t(), role: atom(), org_id: String.t()}} | :error
  def resolve(mods, credential_id, org_id) do
    case fetch_actor(mods, credential_id, org_id) do
      {:ok, actor} ->
        {:ok, actor}

      {:error, reason} ->
        report(:resolve, reason)
        :error

      :error ->
        :error
    end
  rescue
    e ->
      report(:resolve, e)
      :error
  end

  # Module names only — an Ash error interpolates the values it was processing.
  defp report(name, %{__struct__: module}) do
    Logger.error("[Samen.Auth.OrgActor] read failed read=#{name} cause=#{inspect(module)}")
  end

  defp find_user(mods, credential_id, org_id) do
    mods.user
    |> Ash.Query.filter(credential_id == ^credential_id and org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :org_id])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
  end

  # The rule that turns a membership into authority, stated ONCE: only an ACTIVE row counts (a suspended or invited
  # membership confers neither role nor org), and if a user holds several active rows in an org the LOWEST role wins
  # (id breaks a tie), so the answer never depends on row order. `Samen.Auth.OrgActor` (`active_membership/3`,
  # `authorized_org_ids/2`, `resolve/3`) and `Samen.Scope.ApiKey.membership_for_user/3` (an API key's minter) are built
  # on `active_memberships/3` + `lowest/1` below. Other call sites still carry their own copy of the same rule:
  # `Samen.Web.Settings.Reads.current_membership_result/4` (it reads under the caller's scope, not `authorize?: false`),
  # `PawChart.Auth.authorized_org_ids/1` and `Samen.Scope.KeyBoundToMinter`. A change to the rule must be made in each.
  @doc """
  The user's ACTIVE membership in `org_id` (the lowest-ranked one if several): `{:ok, membership}`, `:none` when
  there is no active row (a suspended or invited membership is "no membership"), or `{:error, reason}` when the
  read failed. `membership_mod` is the host's Membership resource. A database that already holds several active rows
  for one user in one org keeps resolving the lowest-ranked (the safe direction: a duplicate never raises authority);
  `Samen.Identity.OneMembership` stops new ones being created.
  """
  @spec active_membership(module(), String.t(), String.t()) :: {:ok, map()} | :none | {:error, term()}
  def active_membership(membership_mod, user_id, org_id) do
    case active_memberships(membership_mod, [user_id], [org_id]) do
      {:ok, []} -> :none
      {:ok, rows} -> {:ok, lowest(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every ACTIVE membership of any of `user_ids` in any of `org_ids`, in ONE read: `{:ok, rows}` (each with `:id`,
  `:user_id`, `:org_id`, `:role`, `:status`) or `{:error, reason}`. The caller pairs rows with the (user, org) it asked
  about: the two lists are independent, so a row may pair a user with an org it was not asked about.
  """
  @spec active_memberships(module(), [String.t()], [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def active_memberships(_membership_mod, [], _org_ids), do: {:ok, []}
  def active_memberships(_membership_mod, _user_ids, []), do: {:ok, []}

  def active_memberships(membership_mod, user_ids, org_ids) do
    membership_mod
    |> Ash.Query.filter(user_id in ^user_ids and org_id in ^org_ids and status == "active")
    |> Ash.Query.ensure_selected([:id, :user_id, :org_id, :role, :status])
    # a user holds one membership per org, a handful at the very most
    |> Ash.Query.limit(25 * length(user_ids))
    |> Ash.read(authorize?: false)
  end

  @doc false
  @spec lowest([map()]) :: map()
  def lowest(rows), do: Enum.min_by(rows, &{Samen.Scope.Role.rank(&1.role), to_string(&1.id)})

  # The orgs among `users` in which the user holds an active membership: ONE `active_memberships/3` read for all the
  # user rows (a credential holds one user per org), then each user is paired with its own org.
  defp active_org_ids(_mods, []), do: {:ok, []}

  defp active_org_ids(mods, users) do
    case active_memberships(mods.membership, Enum.map(users, & &1.id), Enum.map(users, & &1.org_id)) do
      {:ok, rows} ->
        active = MapSet.new(rows, &{&1.user_id, &1.org_id})

        ids =
          for user <- users, MapSet.member?(active, {user.id, user.org_id}), do: user.org_id

        {:ok, Enum.uniq(ids)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
