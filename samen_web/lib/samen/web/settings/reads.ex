defmodule Samen.Web.Settings.Reads do
  @moduledoc """
  The framework settings read layer (WS-E E5; ADR-029) — bounded, org-scoped reads +
  per-plane PII resolution for the self-serve settings surfaces.

  ## Current-user seam (host-owned auth boundary — ADR-029 §2.2)

  Auth is HOST-OWNED: `samen_web` has no login LiveView and no session user store. The
  settings surfaces need to know WHICH `User` row is "me" — resolved the SAME way
  `Samen.Web.CurrentOrg` resolves the current org: the legacy BYO
  `session["samen_current_user"]` → the framework SPINE session (`samen_session_token`, what
  `POST /login` writes; the credential's per-org `Identity.User` through `Samen.Auth.OrgActor`) →
  the DISARMED-ONLY dev legs (the host-wired `Mount.label(:current_user_id)`, then `params["user"]`) →
  `nil` (the honest "no user wired" card). The framework never invents an identity.
  `actor_in_org/3` is the ONE resolver that also yields the member's real ROLE (and refuses a
  principal with no active membership); the notifications surfaces use it.

  ## B-SEC / S2 — `params["user"]` is a DEV leg, gated exactly like `?org=`

  Before this fix `current_user_id/3` tried `params["user"]` FIRST, unconditionally, with
  **no arming gate at all** — unlike `Samen.Web.CurrentOrg.resolve/3` and
  `Samen.Web.Operator.Impersonation.resolve_operator_id/3`, both of which trust their dev
  param leg ONLY in the explicitly disarmed posture. Tenant IDENTITY was therefore a query
  param: `?user=<victim-admin>` on `/settings/invitations` produced a scope carrying the
  victim's REAL membership role, minting an `:admin` invite token into their org; the same
  shape drove reveal-grant approval and API-key mint/revoke.

  Now the SESSION (and the host-wired label) win, and the param leg is consulted ONLY when
  `Samen.Web.CurrentOrg.param_trust_disarmed?/1` — the SAME predicate that governs the
  `?org=` convenience. On an armed host a `?user=` cannot name an identity at all.

  ## MASKING INVARIANT (the profile self-edit surface)

  `User.full_name`/`emails` are vault-routed PII. Every read resolves through
  `Samen.Api.PiiResolution` on the caller's plane — tenant own-org → clear; operator
  impersonation → `%Samen.Masked{}` (→ `••••`). This module NEVER calls
  `Samen.Vault.reveal/3`, NEVER unwraps a `%Masked{}`, and has no "show plaintext"
  path; on any resolver error the field stays `%Masked{}` (no plaintext downgrade).
  """

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Reads.Guard

  @session_key "samen_current_user"

  @user_select [:handle, :status, :full_name, :emails, :org_id, :id]

  @doc "The session key under which a host stores the current user id."
  def session_key, do: @session_key

  @doc """
  Resolve the current user id for `mount` given the LiveView `params` + `session`.
  First hit wins: the legacy BYO session key → the framework SPINE session (the credential's per-org
  `Identity.User`, through `Samen.Auth.OrgActor`) → the DISARMED-ONLY dev legs (the host-wired
  `:current_user_id` label, then `?user=`) → `nil`. Never raises. See the moduledoc's B-SEC / S2 note
  for why the param leg is behind the arming gate.

  A spine-authenticated session (`samen_session_token`, what `POST /login` writes) used to resolve to
  `nil` here, so every surface keyed on "which user am I" saw "no user wired" for a real login.
  """
  @spec current_user_id(Mount.t() | nil, map(), map()) :: String.t() | nil
  def current_user_id(mount, params, session) do
    present(session_user(session)) || spine_user_id(mount, params, session) ||
      present(dev_label_user(mount)) || present(dev_param_user(mount, params))
  end

  defp spine_user_id(%Mount{} = mount, params, session) do
    org_id = Samen.Web.CurrentOrg.resolve(mount, params, session)

    case current_actor(mount, org_id, params, session) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp spine_user_id(_mount, _params, _session), do: nil

  @typedoc """
  Who is acting on a per-user surface: `{:ok, %{id:, role:}}` (the per-org `Identity.User` id and its ACTIVE
  membership role), `:none` (no user resolved: the honest "nobody signed in" - a dev posture), `:denied` (a
  principal that holds no ACTIVE membership in the org: no access), or `{:error, :unavailable}` (a lookup
  failed - an error state, never an empty answer).
  """
  @type actor_result :: {:ok, %{id: String.t(), role: atom()}} | :none | :denied | {:error, :unavailable}

  @typedoc "The principal a session carries, independent of any org (a credential is org-less; its user is per org)."
  @type principal_ref :: {:credential, String.t()} | {:user, String.t()} | {:dev, String.t()} | :none | {:error, :unavailable}

  @doc """
  The session's PRINCIPAL, org-less: `{:credential, id}` (the spine session token resolved to a live session),
  `{:user, id}` (the legacy BYO `samen_current_user` key), `{:dev, id}` (the DISARMED-ONLY `:current_user_id`
  label / `?user=` legs), `:none`, or `{:error, :unavailable}` when the session lookup failed.
  """
  @spec principal_ref(Mount.t() | nil, map(), map()) :: principal_ref()
  def principal_ref(%Mount{plane: %{kind: :operator}}, _params, _session), do: :none

  def principal_ref(%Mount{} = mount, params, session) do
    idmount = Samen.Web.CurrentOrg.identity_mount(mount)

    case Samen.Web.Auth.resolve_principal(session, %{session: Mount.resource(idmount, Session)}) do
      {:ok, %{credential_id: credential_id}} -> {:credential, credential_id}
      {:ok, %{user_id: user_id}} -> {:user, user_id}
      :error -> dev_ref(mount, params)
    end
  rescue
    e ->
      Guard.report(:settings_principal_ref, nil, e)
      {:error, :unavailable}
  end

  def principal_ref(_mount, _params, _session), do: :none

  defp dev_ref(mount, params) do
    case present(dev_label_user(mount)) || present(dev_param_user(mount, params)) do
      nil -> :none
      id -> {:dev, id}
    end
  end

  @doc """
  The ACTING user for `principal_ref` in `org_id`: the per-org `Identity.User` id AND its real role, derived
  from the spine's Membership rows through `Samen.Auth.OrgActor` - the ONE resolver. A principal without an
  ACTIVE membership in the org is `:denied` (a suspended or invited membership gives no access); a failed
  lookup is `{:error, :unavailable}`. The dev leg (disarmed only) has no credential: it acts as the named user
  with that user's membership role when one exists, else `:member`.
  """
  @spec actor_in_org(Mount.t() | nil, String.t() | nil, principal_ref()) :: actor_result()
  def actor_in_org(%Mount{plane: %{kind: :operator}}, _org_id, _ref), do: :none
  def actor_in_org(_mount, nil, _ref), do: :none
  def actor_in_org(_mount, _org_id, :none), do: :none
  def actor_in_org(_mount, _org_id, {:error, :unavailable}), do: {:error, :unavailable}

  def actor_in_org(%Mount{} = mount, org_id, ref) when is_binary(org_id) do
    idmount = Samen.Web.CurrentOrg.identity_mount(mount)
    mods = %{user: Mount.resource(idmount, User), membership: Mount.resource(idmount, Membership)}

    case ref do
      {:credential, credential_id} ->
        case Samen.Auth.OrgActor.resolve_result(mods, credential_id, org_id) do
          {:ok, %{user_id: user_id, role: role}} -> {:ok, %{id: user_id, role: role}}
          :error -> :denied
          {:error, :unavailable} -> {:error, :unavailable}
        end

      {:user, user_id} ->
        member_actor(mods, user_id, org_id, :denied)

      {:dev, user_id} ->
        member_actor(mods, user_id, org_id, {:ok, %{id: user_id, role: :member}})
    end
  rescue
    e ->
      Guard.report(:settings_actor_in_org, org_id, e)
      {:error, :unavailable}
  end

  def actor_in_org(_mount, _org_id, _ref), do: :none

  defp member_actor(mods, user_id, org_id, when_none) do
    case Samen.Auth.OrgActor.active_membership(mods.membership, user_id, org_id) do
      {:ok, membership} -> {:ok, %{id: user_id, role: membership.role}}
      :none -> when_none
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc "`principal_ref/3` then `actor_in_org/3`: who acts in `org_id` for this `params` + `session`."
  @spec current_actor(Mount.t() | nil, String.t() | nil, map(), map()) :: actor_result()
  def current_actor(mount, org_id, params, session),
    do: actor_in_org(mount, org_id, principal_ref(mount, params, session))

  @doc """
  The ACTING scope for `user_id`: `Mount.scope/2`, with the tenant plane's synthetic org-level actor
  (`broker:<org>`, which names no user) carrying the user the SESSION resolved. This is the one place a
  user identity enters a settings scope, and `user_id` must be the value `current_user_id/3` /
  `reresolve_user/3` produced, never a request argument of its own. `Samen.Web.Settings.Profile.update/4`
  refuses any scope whose actor is not the user being edited. An operator-plane (impersonation) scope is
  returned as it is: its actor is the operator, never the user.
  """
  @spec user_scope(Mount.t(), String.t() | nil, String.t() | nil, atom() | nil) :: Samen.Scope.t()
  def user_scope(%Mount{} = mount, org_id, user_id, role \\ nil) do
    case {Mount.scope(mount, org_id), user_id} do
      {%Samen.Scope{actor: %{plane: :tenant} = actor} = scope, user_id} when is_binary(user_id) ->
        # `Plane.scope` gives every tenant actor `role: :member`; the role the session RESOLVED
        # (`actor_in_org/3`) replaces it, so a viewer is not a member here.
        %{scope | actor: %{actor | id: user_id, role: role || actor.role}}

      {scope, _no_session_user} ->
        scope
    end
  end

  @doc """
  Stash the session's PRINCIPAL (`principal_ref/3`) on the socket at `mount/3`, so `handle_params/3` (which has
  no session) can re-derive the acting user when `?org=` switches to another authorized org. A principal is
  org-less; the user it acts as is PER ORG.
  """
  @spec assign_principal(Phoenix.LiveView.Socket.t(), map(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_principal(socket, params, session) do
    Phoenix.Component.assign(socket, :principal_ref, principal_ref(socket_assigns(socket)[:samen_mount], params, session))
  end

  @doc """
  Re-resolve the current user id inside `handle_params/3` — the shared helper the settings /
  billing-settings / onboarding surfaces call in place of the old
  `Map.get(params, "user") || socket.assigns.user_id` idiom (B-SEC / S2, the identity twin of
  `Samen.Web.CurrentOrg.reresolve/2`).

  `handle_params/3` runs on the initial DEAD RENDER, so that idiom let a client `?user=`
  overwrite the session-derived identity `mount/3` had just computed. Here the param is
  honoured ONLY in the explicitly DISARMED dev posture; otherwise the identity `mount/3`
  resolved from the session stands - for the SAME org.

  A user id is PER ORG: when `?org=` switched to another (authorized) `org_id`, the id `mount/3` resolved
  belongs to the OLD org and is never carried over. The user is re-derived for `org_id` from the principal
  `assign_principal/3` stashed (`actor_in_org/3`); a principal with no active membership there, a failed
  lookup, or no stashed principal gives `nil` - the honest "no user" state, never another org's id.
  """
  @spec reresolve_user(Phoenix.LiveView.Socket.t() | map(), map(), String.t() | nil) :: String.t() | nil
  def reresolve_user(socket, params, org_id) do
    assigns = socket_assigns(socket)
    mount = Map.get(assigns, :samen_mount)

    cond do
      dev = present(dev_param_user(mount, params)) ->
        dev

      org_id == Map.get(assigns, :org_id) ->
        Map.get(assigns, :user_id)

      true ->
        case actor_in_org(mount, org_id, Map.get(assigns, :principal_ref, :none)) do
          {:ok, %{id: id}} -> id
          _ -> nil
        end
    end
  end

  defp socket_assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp socket_assigns(assigns) when is_map(assigns), do: assigns
  defp socket_assigns(_), do: %{}

  # The `?user=` DEV leg — trusted ONLY in the explicitly disarmed posture, the SAME gate
  # `Samen.Web.CurrentOrg` applies to `?org=`. On an armed host it is `nil`, always.
  defp dev_param_user(mount, params) do
    if Samen.Web.CurrentOrg.param_trust_disarmed?(mount), do: param_user(params)
  end

  defp param_user(params) when is_map(params), do: Map.get(params, "user")
  defp param_user(_), do: nil

  defp session_user(session) when is_map(session), do: Map.get(session, @session_key)
  defp session_user(_), do: nil

  # The host-wired `:current_user_id` label names ONE fixed user for EVERY session on the mount, so it is
  # a DEV leg (trusted only in the disarmed posture, like `?user=`): on an armed host it is `nil`, always.
  defp dev_label_user(%Mount{} = mount) do
    if Samen.Web.CurrentOrg.param_trust_disarmed?(mount), do: Mount.label(mount, :current_user_id, nil)
  end

  defp dev_label_user(_), do: nil

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      _ -> v
    end
  end

  defp present(_), do: nil

  @doc """
  Read a SINGLE `User` by id for `scope`, with `full_name`/`emails` plane-resolved —
  `{:ok, user}` or `{:error, :not_found}`. Org-scoped: a cross-org id reads zero rows
  under `OrgScope` (no existence oracle).
  """
  def get_user(mount, scope, id) do
    case get_user_result(mount, scope, id) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Tagged sibling of `get_user/3` (WP6): `{:ok, user}`, `{:error, :not_found}` for a missing or
  denied record, and `{:error, :unavailable}` ONLY when the read FAILED — a failed read is not
  "No user in context".
  """
  def get_user_result(mount, scope, id) when is_binary(id) do
    case Guard.run(:settings_get_user, scope, fn ->
           Mount.resource(mount, User)
           |> Ash.Query.ensure_selected(@user_select)
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.limit(1)
           |> Ash.read!(scope: scope)
           |> resolve_pii(mount, scope)
         end) do
      {:ok, [user | _]} -> {:ok, user}
      {:ok, []} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  def get_user_result(_mount, _scope, _id), do: {:error, :not_found}

  @doc """
  The current user's `Membership` in `org_id` (for the API-key minter ceiling) —
  `{:ok, membership}` or `{:error, :not_found}`. Org-scoped via `scope`.
  """
  def current_membership(mount, scope, user_id, org_id) do
    case current_membership_result(mount, scope, user_id, org_id) do
      {:ok, membership} -> {:ok, membership}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Tagged sibling of `current_membership/4` (WP6): only an ACTIVE membership counts; `{:error, :not_found}` is "no (active) membership"
  (a real answer: fail-closed, no authority); `{:error, :unavailable}` is "the lookup FAILED" —
  still fail-closed (no authority is granted), but a screen can say "couldn't check your role"
  instead of "no membership in context".
  """
  def current_membership_result(mount, scope, user_id, org_id)
      when is_binary(user_id) and is_binary(org_id) do
    case Guard.run(:settings_current_membership, scope, fn ->
           Mount.resource(mount, Membership)
           |> Ash.Query.ensure_selected([:role, :status, :org_id, :id, :user_id])
           # Only an ACTIVE membership carries authority: a suspended or invited one is "no membership" here, as it is for
           # a key's minter (`Samen.Scope.ApiKey.effective_role/2`). If a user somehow holds several active rows in
           # the org the LOWEST role wins, so the answer never depends on row order.
           |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id and status == "active")
           # a bounded read (the reads lint): a user holds one membership per org, a handful at the very most
           |> Ash.Query.limit(25)
           |> Ash.read!(scope: scope)
         end) do
      {:ok, [_ | _] = memberships} -> {:ok, Enum.min_by(memberships, &{Samen.Scope.Role.rank(&1.role), to_string(&1.id)})}
      {:ok, []} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  def current_membership_result(_mount, _scope, _user_id, _org_id), do: {:error, :not_found}

  # -- private -----------------------------------------------------------------

  defp resolve_pii(records, mount, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, User),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    e ->
      # Fail-closed (no plaintext downgrade), but not silent: a resolver outage is logged.
      Guard.report(:settings_resolve_pii, scope, e)
      records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
