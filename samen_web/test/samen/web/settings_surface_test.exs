defmodule Samen.Web.SettingsSurfaceTest do
  @moduledoc """
  WS-E E5.3 — THE SETTINGS SURFACE (ADR-029; AC-G18-1/5). The three framework settings
  LiveViews (Profile · API keys · Security) render over a real Identity host
  (`Samen.WebTest.Operator`), mounted by ONE `samen_settings_routes` macro — zero authored
  settings LiveViews per vertical.

  Includes RP-ST-4 (AC-G18-5): the Security surface is READ-ONLY and HONEST about the
  host-auth boundary — it renders the real impersonation-session accountability view + an
  explicit "managed by your identity provider" affordance, and has NO write control
  (`phx-click`) that fakes host-owned password/2FA/session-revocation. Adding such a fake
  toggle (the committed `14-e5-security-fake-toggle` patch) FLIPS the honesty test.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Type.FullName
  alias Samen.Web.Settings.ApiKeys
  alias Samen.Web.Router

  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.User

  @secret_first "SurfaceSecretFirst"
  @secret_last "SurfaceSecretLast"

  defp seed!(org_id, role \\ :admin) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "surfaceuser",
        full_name: %FullName{first: @secret_first, last: @secret_last},
        emails: [%{address: "surface.secret@example.test"}]
      })
      |> Ash.create!(authorize?: false)

    membership =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
      |> Ash.create!(authorize?: false)

    {user, membership}
  end

  defp admin_scope(user_id, org_id),
    do: %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}}

  # ==========================================================================
  # Mount / route table (AC-G18-1)
  # ==========================================================================

  describe "the settings route table + mount macro (AC-G18-1)" do
    test "one macro mounts the three surfaces (profile index + profile + api-keys + security)" do
      routes = Router.__routes__(:settings, "/settings")

      assert {"/settings", Samen.Web.Settings.ProfileLive} in routes
      assert {"/settings/profile", Samen.Web.Settings.ProfileLive} in routes
      assert {"/settings/api-keys", Samen.Web.Settings.ApiKeysLive} in routes
      assert {"/settings/security", Samen.Web.Settings.SecurityLive} in routes
    end

    test "the settings mount scope_kind survives session round-trip" do
      mount = build_mount(:settings)
      rebuilt = Samen.Web.Mount.from_session(Samen.Web.Mount.to_session(mount))
      assert rebuilt.scope_kind == :settings
      assert rebuilt.namespace == Samen.WebTest.Operator
    end
  end

  # ==========================================================================
  # Profile surface — tenant clear, operator masked (AC-G18-2 render)
  # ==========================================================================

  describe "ProfileLive render" do
    test "TENANT plane renders editable name fields in the clear" do
      org_id = Ash.UUID.generate()
      {user, _} = seed!(org_id)

      html = render_live(Samen.Web.Settings.ProfileLive, build_mount(:settings), [org_id, user.id])

      assert html =~ "settings-profile"
      assert html =~ ~s(id="settings-profile-form")
      # First/last editable inputs carry the plaintext on the tenant plane.
      assert html =~ @secret_first
      assert html =~ "First name"
      refute html =~ "vt_"
    end

    test "OPERATOR plane masks the vaulted fields read-only (••••), never plaintext (RP-ST-1 render)" do
      org_id = Ash.UUID.generate()
      {user, _} = seed!(org_id)

      html =
        render_live(
          Samen.Web.Settings.ProfileLive,
          build_mount(:settings, plane: :operator, target_org_id: org_id),
          [org_id, user.id]
        )

      assert html =~ "••••"
      assert html =~ "data-masked"
      refute html =~ @secret_first
      refute html =~ @secret_last
      refute html =~ "vt_"
    end
  end

  # ==========================================================================
  # API-keys surface (AC-G18-3 render)
  # ==========================================================================

  describe "ApiKeysLive render" do
    test "TENANT plane shows the mint form; the list shows a digest prefix, never a raw key" do
      org_id = Ash.UUID.generate()
      {user, membership} = seed!(org_id)

      {:ok, raw, _row} =
        ApiKeys.mint(build_mount(:settings), admin_scope(user.id, org_id),
          membership_id: membership.id,
          minter_role: :admin,
          scopes: %{all: [:read]}
        )

      html = render_live(Samen.Web.Settings.ApiKeysLive, build_mount(:settings), [org_id, user.id])

      assert html =~ ~s(id="api-key-mint-form")
      assert html =~ ~s(id="api-keys-table")
      # The raw key is NEVER rendered in the list (it isn't stored).
      refute html =~ raw
    end

    test "OPERATOR plane is read-only — no mint form, an honest note instead" do
      org_id = Ash.UUID.generate()
      {user, _} = seed!(org_id)

      html =
        render_live(
          Samen.Web.Settings.ApiKeysLive,
          build_mount(:settings, plane: :operator, target_org_id: org_id),
          [org_id, user.id]
        )

      refute html =~ ~s(id="api-key-mint-form")
      assert html =~ ~s(id="api-key-operator-note")
    end
  end

  # ==========================================================================
  # Security surface — read-only + honest (RP-ST-4 · AC-G18-5)
  # ==========================================================================

  describe "SecurityLive is read-only and honest about the host-auth boundary (RP-ST-4)" do
    test "renders the accountability view + the honest 'managed by your identity provider' affordance" do
      org_id = Ash.UUID.generate()
      {user, _} = seed!(org_id)

      html = render_live(Samen.Web.Settings.SecurityLive, build_mount(:settings), [org_id, user.id])

      assert html =~ "settings-security"
      assert html =~ ~s(id="security-sessions-table")
      assert html =~ ~s(id="security-host-managed")
      assert html =~ "Managed by your identity provider"

      # PP-11 (T150) — the framework surface carries the REVEAL-access ledger section. This
      # host has no aud_chain migration, so the reader degrades to the honest empty state
      # (never a fake) — the org-scoped, populated render is proven on driftwood (aud_chain).
      assert html =~ ~s(id="security-reveal-table")
      assert html =~ "No reveal access recorded"
    end

    test "HONESTY: the surface has NO write control (phx-click) — it fakes no host-auth toggle" do
      org_id = Ash.UUID.generate()
      {user, _} = seed!(org_id)

      html = render_live(Samen.Web.Settings.SecurityLive, build_mount(:settings), [org_id, user.id])

      # SABOTAGE (14-e5): adding a fake "revoke session" toggle introduces a phx-click,
      # which FLIPS this refutation. There is no framework auth to toggle.
      refute html =~ "phx-click"
      refute html =~ "phx-submit"
    end

    test "ANTI-TAUTOLOGY: a modeled fake-toggle DOM IS caught by the honesty scan (refutable)" do
      leaked = ~s(<button phx-click="revoke_all_sessions">Revoke all</button>)
      assert leaked =~ "phx-click"
    end
  end
end
