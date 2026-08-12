defmodule Samen.Web.Operator.Authz do
  @moduledoc """
  The OPERATOR-plane ROLE authorization gate (T146 / ADR-010 §7.2 hardening).

  ## The hole this closes (dogfood W3-E1, CONFIRMED LIVE)

  Before T146 the operator control plane AUTHENTICATED only — it never checked that the
  authenticated principal actually held OPERATOR authority. `samen_operator_routes/2` emitted a
  bare `live_session` with no `on_mount` hook; `Samen.Web.AuthGate` checked only
  `Samen.Web.Auth.authenticated_user_id/1`; and `Samen.Web.Operator.scope/1` fabricates the actor
  from the MOUNT (the well-known operator org id), NEVER from the session principal. Operator and
  tenant share ONE authn realm, so a plain authenticated TENANT user hitting `/operator/accounts`
  in a correctly-configured prod host got a `200` rendering every OTHER tenant's admin email + org
  + MRR in the clear. The framework carried an `operator_role` primitive
  (`Samen.OperatorPlane.Actor`, used by `Samen.BreakGlass` / `Samen.Automation.Health`) but it was
  never wired to the operator routes — the mount's `:operator_role` was only a display label.

  This module is the missing authorization layer. It derives operator authority from the
  AUTHENTICATED PRINCIPAL (never from the mount) and FAILS CLOSED for anyone who is not an
  operator. It is an `on_mount` hook every operator route carries (attached by
  `samen_operator_routes/2`), so a tenant-user session cannot reach ANY `/operator/*` surface.

  ## The host seam — how a host declares operator authority (fail-CLOSED by default)

  Auth is HOST-OWNED (ADR-029): the framework cannot know which principal is an operator. A host
  declares it through the mount's `:operator_authority` label — an `{mod, fun, args}` MFA
  (the SAME shape `Samen.Web.CurrentOrg` uses for `:authorized_orgs`), called with the
  authenticated principal id APPENDED, returning one of `Samen.OperatorPlane.Actor.roles/0`
  (`:operator_admin | :operator_support | :operator_readonly | :operator_break_glass`) or `nil`.

    * a valid operator role → the principal is an operator → `:cont` (the operator plane renders);
    * `nil`, an unknown/invalid return, an ERRORING resolver, or NO `:operator_authority` seam at
      all → the principal is NOT an operator → `:halt` + redirect to `/login`.

  A host that wires NOTHING gets NO operator access (deny-by-default), never open access. The
  authority is ALWAYS derived from the authenticated principal — this module NEVER fabricates the
  operator identity from the mount.

  ## Dev posture — operator-ROLE authz is NOT bypassed by `auth_required?: false`

  Unlike `Samen.Web.CurrentOrg`/`Samen.Web.AuthGate` (whose AUTHENTICATION relaxes in dev), this
  ROLE gate ALWAYS applies: `resolve_role/2` denies unless the host seam returns an operator role,
  in EVERY environment. Dev CONVENIENCE is opt-in and unmistakably dev-only via `dev_operator_role/2`
  — a NAMED resolver a host/generated router may wire as its `:operator_authority` seam. It grants
  `:operator_admin` ONLY while `auth_required?` is false for the app (dev/test), and `nil`
  (fail-closed) the instant the app is armed for prod. So the exploit is never trivially open in a
  way that could ship: a prod-armed app with a dev seam still refuses every non-operator.
  """
  use Phoenix.Component

  alias Samen.OperatorPlane.Actor
  alias Samen.Web.{Auth, Mount}

  @roles Actor.roles()
  @default_login_path "/login"

  @doc """
  The `on_mount {Samen.Web.Operator.Authz, :require_operator}` hook `samen_operator_routes/2`
  attaches to the operator `live_session`. Resolves operator authority from the authenticated
  session principal (via the host `:operator_authority` seam) and:

    * `{:cont, socket}` with `:samen_operator_role` assigned — the principal is an operator;
    * `{:halt, redirect}` to the login path — anyone who is NOT an operator (fail CLOSED,
      renders NOTHING).
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_operator, _params, session, socket) when is_map(session) do
    mount = Mount.from_session(session["samen_mount"] || %{})

    case resolve_role(mount, session) do
      role when role in @roles ->
        {:cont, assign(socket, :samen_operator_role, role)}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: login_path(mount))}
    end
  end

  def on_mount(:require_operator, _params, _session, socket) do
    {:halt, Phoenix.LiveView.redirect(socket, to: @default_login_path)}
  end

  @doc """
  The operator role the AUTHENTICATED principal holds on this `mount`, or `nil` (NOT an operator).

  Derives the principal id from the SIGNED session (`Samen.Web.Auth.authenticated_user_id/1` —
  never a query param), then calls the host `:operator_authority` MFA with it appended. Validates
  the return is a real operator role. Fail-CLOSED: no seam, an error, or a non-role return → `nil`.
  The mount is consulted ONLY for the host seam — the operator IDENTITY is the session principal.
  """
  @spec resolve_role(Mount.t() | nil, map()) :: Actor.operator_role() | nil
  def resolve_role(%Mount{} = mount, session) when is_map(session) do
    principal_id = Auth.authenticated_user_id(session)

    case authority_mfa(mount) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        validate_role(apply(mod, fun, args ++ [principal_id]))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def resolve_role(_mount, _session), do: nil

  @doc """
  A NAMED, opt-in DEV operator-authority resolver a host/generated router may wire as its
  `:operator_authority` seam (`{Samen.Web.Operator.Authz, :dev_operator_role, [otp_app]}`).

  Grants `:operator_admin` ONLY while `auth_required?` is false for `otp_app` (dev/test) so the
  dogfood operator console works without a login; returns `nil` (fail CLOSED) the instant the app
  is armed for prod (`config otp_app, auth_required?: true`). Unmistakably dev-only by name — a
  real deploy replaces it with a resolver that consults the operator roster / membership.
  """
  @spec dev_operator_role(atom(), String.t() | nil) :: :operator_admin | nil
  def dev_operator_role(otp_app, _principal_id \\ nil) when is_atom(otp_app) do
    if Samen.Web.TenantGate.armed?(otp_app), do: nil, else: :operator_admin
  end

  # -- internals --------------------------------------------------------------

  defp authority_mfa(%Mount{} = mount), do: Mount.label(mount, :operator_authority, nil)

  defp validate_role(role) when role in @roles, do: role
  defp validate_role(_), do: nil

  defp login_path(%Mount{} = mount), do: Mount.label(mount, :login_path, @default_login_path)
end
