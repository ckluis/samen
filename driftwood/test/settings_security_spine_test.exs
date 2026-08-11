defmodule Driftwood.SettingsSecuritySpineTest do
  @moduledoc """
  PP-17 (Batch 7 CONFIG-POSTURE; W3 LOW-1) — driftwood now OPTS IN to the framework
  Identity-spine Security features on its `samen_settings_routes` mount
  (`spine_totp: true, spine_sessions: true`), so Settings → Security offers the REAL
  2FA-enrollment surface and the active login-session list + revoke controls instead of
  the honest "managed by your identity provider" placeholder. Both verticals are now
  complete reference implementations at parity (pawchart still ships the placeholder
  posture; driftwood is the adopted positive control).

  Everything is enumerated off `DriftwoodWeb.Router` (the REAL compiled router), so a
  regression that flips either opt-in back to `false` — or drops the `/settings/security/2fa`
  route — fails these assertions.

  Proofs (paired, anti-tautology):
    * WIRING — the real settings live_session mount carries `spine_totp: true` +
      `spine_sessions: true`, and the router mounts `/settings/security/2fa` →
      `Samen.Web.Auth.TotpEnrollLive` (the enrollment surface a tenant can reach).
    * GREEN — rendering `SecurityLive` over the REAL router mount surfaces the 2FA enroll
      link and the login-session list (the real feature, not the placeholder).
    * REFUTABILITY — the SAME LiveView over a mount WITHOUT the opt-ins renders the honest
      placeholder (no enroll link, no session list), proving the GREEN assertions are
      produced by the opt-in, not vacuously always-true.
  """
  use Driftwood.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.SecurityLive

  # The REAL driftwood settings mount, deserialized from the compiled router's
  # `:settings` live_session for `/settings/security` — the exact mount `SecurityLive.mount/3`
  # receives. (`samen_onboarding_routes` also mounts a `:settings`-kind mount at `/onboarding`,
  # so we key on the SecurityLive route path, not scope_kind alone.)
  defp router_settings_mount do
    {_path, mount} =
      DriftwoodWeb.Router.__routes__()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.map(fn route -> {route.path, mount_of(route)} end)
      |> Enum.reject(fn {_path, m} -> is_nil(m) end)
      |> Enum.find(fn {path, m} -> m.scope_kind == :settings and path == "/settings/security" end)

    mount
  end

  defp mount_of(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
    case get_in(live_session, [:extra, :session]) do
      %{"samen_mount" => raw} -> Mount.from_session(raw)
      _ -> nil
    end
  end

  defp mount_of(_), do: nil

  # A placeholder-posture mount (the pre-PP-17 shape / pawchart's posture): the SAME
  # namespace + plane, but NEITHER opt-in — the refutability control.
  defp placeholder_mount do
    Mount.new(:settings, Driftwood.Operator, Driftwood.Repo,
      plane: Plane.tenant(),
      labels: %{settings_path: "/settings"}
    )
  end

  # ==========================================================================
  # WIRING — the real router mount adopts both opt-ins + mounts the 2FA route.
  # ==========================================================================

  describe "PP-17: driftwood's settings mount adopts the spine Security opt-ins" do
    test "the REAL router settings mount carries spine_totp: true and spine_sessions: true" do
      mount = router_settings_mount()

      assert Mount.label(mount, :spine_totp, false) == true,
             "driftwood's samen_settings_routes must opt in spine_totp so /settings/security " <>
               "offers real 2FA enrollment (else it stays the honest placeholder forever)"

      assert Mount.label(mount, :spine_sessions, false) == true,
             "driftwood's samen_settings_routes must opt in spine_sessions so /settings/security " <>
               "offers the real active-session list + revoke controls"
    end

    test "the router mounts /settings/security/2fa → TotpEnrollLive (the enrollment surface is reachable)" do
      route =
        DriftwoodWeb.Router.__routes__()
        |> Enum.find(fn r -> r.path == "/settings/security/2fa" end)

      assert route, "driftwood must mount the 2FA enrollment route under the spine_totp opt-in"

      {view, _action, _opts, _ls} = route.metadata.phoenix_live_view
      assert view == Samen.Web.Auth.TotpEnrollLive
    end
  end

  # ==========================================================================
  # GREEN — SecurityLive over the REAL mount renders the real features.
  # ==========================================================================

  describe "PP-17: Security settings render the real 2FA + session surfaces (not the placeholder)" do
    test "the REAL router mount surfaces the 2FA enroll link + the login-session list" do
      org_id = Ash.UUID.generate()
      html = render_framework(SecurityLive, router_settings_mount(), [org_id, nil])

      # Real 2FA: a navigation to the enrollment surface (never a fake toggle).
      assert html =~ "security-2fa-enroll-link"
      assert html =~ "Set up two-factor authentication"

      # Real session management: the active-login-sessions block + its table.
      assert html =~ "security-login-sessions"
      assert html =~ "login-sessions-table"

      # The "Active login sessions — handled by your identity provider" placeholder is GONE
      # (replaced by the real table); the surface stays read-only/honest otherwise.
      refute html =~ "Session revocation is handled by your identity provider."
      refute html =~ "phx-click"
    end
  end

  # ==========================================================================
  # REFUTABILITY — without the opt-ins, the placeholder returns (non-vacuous).
  # ==========================================================================

  describe "REFUTABILITY: the placeholder-posture mount renders the honest placeholder" do
    test "a mount WITHOUT the opt-ins has no enroll link and no session list" do
      org_id = Ash.UUID.generate()
      html = render_framework(SecurityLive, placeholder_mount(), [org_id, nil])

      refute html =~ "security-2fa-enroll-link"
      refute html =~ "security-login-sessions"

      # The honest placeholders the opt-in replaces are present here.
      assert html =~ "Session revocation is handled by your identity provider."
      assert html =~ "Managed by your identity provider."
    end
  end
end
