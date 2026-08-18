defmodule Samen.Web.Settings.Reads do
  @moduledoc """
  The framework settings read layer (WS-E E5; ADR-029) — bounded, org-scoped reads +
  per-plane PII resolution for the self-serve settings surfaces.

  ## Current-user seam (host-owned auth boundary — ADR-029 §2.2)

  Auth is HOST-OWNED: `samen_web` has no login LiveView and no session user store. The
  settings surfaces need to know WHICH `User` row is "me" — resolved the SAME way
  `Samen.Web.CurrentOrg` resolves the current org (the notifications `:recipient_id`
  precedent): `session["samen_current_user"]` → the host-wired
  `Mount.label(:current_user_id)` → the DISARMED-ONLY `params["user"]` dev leg →
  `nil` (the honest "no user wired" card). The framework never invents an identity;
  it reads the one the host supplies.

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

  @session_key "samen_current_user"

  @user_select [:handle, :status, :full_name, :emails, :org_id, :id]

  @doc "The session key under which a host stores the current user id."
  def session_key, do: @session_key

  @doc """
  Resolve the current user id for `mount` given the LiveView `params` + `session`.
  First hit wins: session → host-wired mount label → the DISARMED-ONLY `?user=` dev
  param → `nil`. Never raises. See the moduledoc's B-SEC / S2 note for why the param
  leg moved LAST and behind the arming gate.
  """
  @spec current_user_id(Mount.t() | nil, map(), map()) :: String.t() | nil
  def current_user_id(mount, params, session) do
    present(session_user(session)) ||
      present(label_user(mount)) ||
      present(dev_param_user(mount, params))
  end

  @doc """
  Re-resolve the current user id inside `handle_params/3` — the shared helper the settings /
  billing-settings / onboarding surfaces call in place of the old
  `Map.get(params, "user") || socket.assigns.user_id` idiom (B-SEC / S2, the identity twin of
  `Samen.Web.CurrentOrg.reresolve/2`).

  `handle_params/3` runs on the initial DEAD RENDER, so that idiom let a client `?user=`
  overwrite the session-derived identity `mount/3` had just computed. Here the param is
  honoured ONLY in the explicitly DISARMED dev posture; otherwise the identity `mount/3`
  resolved from the session stands.
  """
  @spec reresolve_user(Phoenix.LiveView.Socket.t() | map(), map()) :: String.t() | nil
  def reresolve_user(socket, params) do
    assigns = socket_assigns(socket)
    current = Map.get(assigns, :user_id)

    present(dev_param_user(Map.get(assigns, :samen_mount), params)) || current
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

  defp label_user(%Mount{} = mount), do: Mount.label(mount, :current_user_id, nil)
  defp label_user(_), do: nil

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
  def get_user(mount, scope, id) when is_binary(id) do
    Mount.resource(mount, User)
    |> Ash.Query.ensure_selected(@user_select)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, scope)
    |> case do
      [user | _] -> {:ok, user}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def get_user(_mount, _scope, _id), do: {:error, :not_found}

  @doc """
  The current user's `Membership` in `org_id` (for the API-key minter ceiling) —
  `{:ok, membership}` or `{:error, :not_found}`. Org-scoped via `scope`.
  """
  def current_membership(mount, scope, user_id, org_id)
      when is_binary(user_id) and is_binary(org_id) do
    Mount.resource(mount, Membership)
    |> Ash.Query.ensure_selected([:role, :status, :org_id, :id, :user_id])
    |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> case do
      [membership | _] -> {:ok, membership}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def current_membership(_mount, _scope, _user_id, _org_id), do: {:error, :not_found}

  # -- private -----------------------------------------------------------------

  defp resolve_pii(records, mount, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, User),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
