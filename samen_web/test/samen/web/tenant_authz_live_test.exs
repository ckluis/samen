defmodule Samen.Web.TenantAuthzLiveTest do
  @moduledoc """
  B-SEC (luminary pre-merge BLOCKER) — the LIVEVIEW-DRIVING tenant-authz red paths.

  ## The coverage gap this closes (finding S5)

  Every phase-1 tenant-authn proof in this repo — `Samen.Web.TenantAuthnCoverageTest`,
  `PawChart.TenantAuthnProdPathTest`, `Driftwood.AuthProdPathTest` — asserted the security
  property against `Samen.Web.CurrentOrg.resolve/3` **as a unit function**. All of them passed.
  None of them drove a tenant LiveView. The class stayed wide open one callback later:
  `handle_params/3` runs on the INITIAL DEAD RENDER in `phoenix_live_view` 1.2.9
  (`deps/phoenix_live_view/lib/phoenix_live_view/static.ex:155,320-355`), and 42 framework
  tenant LiveViews re-derived the org there from a raw `params["org"]`.

  This suite drives the REAL macros through a REAL router + endpoint
  (`Samen.WebTest.SecurityEndpoint`), both as a dead-render `Phoenix.ConnTest.get/2` — the exact
  cookieless `curl` in the finding, and the callback where the bypass lives — and as
  `Phoenix.LiveViewTest.live/2` for the refusal assertions. Routes come from
  `samen_module_routes/3` / `samen_settings_routes/3` themselves, so deleting
  `{Samen.Web.TenantAuthz, :require_tenant}` from a macro flips these tests.

  ## Anti-tautology

  Every refusal is paired with a POSITIVE CONTROL on the same surface, same posture: the
  legitimately authenticated member of the org still sees their own org's vault-routed
  `full_name` in the CLEAR (`Samen.MaskingCase`'s tenant-plane green). A test that refuses
  everything proves nothing.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Samen.Web.Auth
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  # The victim's PII sentinel — a vault-routed (🔒) `full_name` on `Samen.WebTest.Crm.Person`.
  # If ANY of these red paths regress, this string appears in an attacker's DOM.
  @victim_first "Persephone"
  @victim_last "Victimsworth"
  @victim_name "#{@victim_first} #{@victim_last}"

  @attacker_first "Casimir"
  @attacker_last "Ownorgson"
  @attacker_name "#{@attacker_first} #{@attacker_last}"

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_orgs = Application.get_env(:samen_web, :security_test_authorized_orgs, %{})

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      Application.put_env(:samen_web, :security_test_authorized_orgs, prev_orgs)
    end)

    SecurityHost.revoke_all!()

    victim_org = Ash.UUID.generate()
    attacker_org = Ash.UUID.generate()

    person!(victim_org, "VICTIM CONTACT", @victim_first, @victim_last)
    person!(attacker_org, "ATTACKER OWN CONTACT", @attacker_first, @attacker_last)

    %{victim_org: victim_org, attacker_org: attacker_org}
  end

  defp person!(org_id, display_name, first, last) do
    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        display_name: display_name,
        job_title: "Dispatcher",
        full_name: %Samen.Type.FullName{first: first, last: last}
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # A conn carrying a REAL authenticated principal in the SIGNED session (the only thing
  # `Samen.Web.Auth.authenticated_user_id/1` accepts — never a param).
  defp signed_in_conn(user_id) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(Auth.session_user_key(), user_id)
  end

  # ==========================================================================
  # S1 / S1a — the confirmed cross-tenant read (and, through the write_scope
  # elevators, admin-rank write) on an ARMED host, cookieless.
  # ==========================================================================

  describe "S1 — armed host, UNAUTHENTICATED `?org=<victim>`" do
    test "the DEAD RENDER (plain HTTP GET, no cookies) is REFUSED, not served", ctx do
      SecurityHost.arm!()

      conn = get(build_conn(), "/crm/contacts?org=#{ctx.victim_org}")

      # The on_mount halt fires BEFORE handle_params/3 can overwrite the org.
      assert conn.status == 302, "an armed, unauthenticated tenant dead render must not render"
      assert redirected_to(conn) == "/login"

      body = response(conn, 302)
      refute body =~ @victim_name
      refute body =~ "VICTIM CONTACT"
      # Never a vault token either (the leak scan the masking discipline mandates).
      refute body =~ "vt_"
    end

    test "the LIVE mount is REFUSED", ctx do
      SecurityHost.arm!()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), "/crm/contacts?org=#{ctx.victim_org}")
    end

    test "the same request on the CRM DASHBOARD (a sibling mounted surface) is REFUSED too", ctx do
      SecurityHost.arm!()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), "/crm/dashboard?org=#{ctx.victim_org}")
    end
  end

  describe "S1 — armed host, AUTHENTICATED but cross-tenant `?org=<victim>`" do
    # This is the driftwood/pawchart shape: the host `:browser` plug authenticates but never
    # checks WHICH org. Before the fix, `handle_params/3` handed the caller the victim's org.
    test "an authenticated member of org A asking for org B gets A's data, never B's", ctx do
      SecurityHost.arm!()
      SecurityHost.grant!("attacker-user", [ctx.attacker_org])

      html =
        signed_in_conn("attacker-user")
        |> get("/crm/contacts?org=#{ctx.victim_org}")
        |> html_response(200)

      refute html =~ @victim_name, "cross-tenant vaulted PII rendered in the clear"
      refute html =~ "VICTIM CONTACT"
      refute html =~ "vt_"

      # POSITIVE CONTROL (anti-tautology): the caller's OWN org still renders, in the clear.
      # (The list renders the vault-routed `full_name` — the 🔒 sentinel that matters here.)
      assert html =~ @attacker_name
    end

    test "POSITIVE CONTROL — the legitimate same-org path still works end-to-end", ctx do
      SecurityHost.arm!()
      SecurityHost.grant!("victim-user", [ctx.victim_org])

      html =
        signed_in_conn("victim-user")
        |> get("/crm/contacts?org=#{ctx.victim_org}")
        |> html_response(200)

      # The vault-routed 🔒 `full_name` resolves CLEAR on the tenant plane for its OWNER —
      # the `Samen.MaskingCase` tenant-green half, asserted on the DOM: the plaintext is
      # present, the mask is NOT standing in for it, and no `vt_*` vault token leaked.
      assert html =~ @victim_name,
             "the tenant plane must still resolve its OWN vaulted full_name in the clear"

      refute html =~ "#{mask()}#{mask()}", "the owner's own row must not be mask-substituted"
      refute html =~ "vt_"
    end

    test "a `?org=` INSIDE the principal's authorized set is still honoured (multi-org switch)",
         ctx do
      SecurityHost.arm!()
      SecurityHost.grant!("multi-user", [ctx.attacker_org, ctx.victim_org])

      html =
        signed_in_conn("multi-user")
        |> get("/crm/contacts?org=#{ctx.victim_org}")
        |> html_response(200)

      assert html =~ @victim_name,
             "a legitimate multi-org member must still be able to select among THEIR orgs"
    end
  end

  describe "S1 — the DISARMED dev posture is unchanged (no lockout)" do
    test "an unauthenticated `?org=` still resolves while the host is explicitly disarmed", ctx do
      SecurityHost.disarm!()

      html =
        build_conn()
        |> get("/crm/contacts?org=#{ctx.victim_org}")
        |> html_response(200)

      assert html =~ @victim_name,
             "the sanctioned ADR-031 dev/dogfood convenience must be preserved verbatim"
    end
  end

  # ==========================================================================
  # S2 — tenant IDENTITY from `params["user"]`
  # ==========================================================================

  describe "S2 — `?user=` may not name an identity" do
    test "armed + unauthenticated: the settings invitations surface is REFUSED", ctx do
      SecurityHost.arm!()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(
                 build_conn(),
                 "/settings/invitations?org=#{ctx.victim_org}&user=some-victim-admin"
               )
    end

    test "armed + authenticated: a `?user=` cannot re-derive identity", ctx do
      SecurityHost.arm!()
      SecurityHost.grant!("attacker-user", [ctx.attacker_org])

      assert Samen.Web.Settings.Reads.current_user_id(
               armed_settings_mount(),
               %{"user" => "some-victim-admin"},
               %{Auth.session_user_key() => "attacker-user"}
             ) == "attacker-user"

      # ...and the same holds on the REAL dead render, which is where `handle_params/3`
      # used to re-derive it from the param.
      html =
        signed_in_conn("attacker-user")
        |> get("/settings/invitations?org=#{ctx.attacker_org}&user=some-victim-admin")
        |> html_response(200)

      refute html =~ "some-victim-admin",
             "the client-supplied user id must not become the acting identity"
    end

    test "POSITIVE CONTROL — the disarmed dev `?user=` leg still resolves" do
      SecurityHost.disarm!()

      assert Samen.Web.Settings.Reads.current_user_id(
               armed_settings_mount(),
               %{"user" => "dev-user"},
               %{}
             ) == "dev-user"
    end
  end

  # ==========================================================================
  # S3 — TotpEnrollLive: unauthenticated 2FA strip on ANY credential
  # ==========================================================================

  describe "S3 — the TOTP enrollment surface is authenticated, always" do
    test "unauthenticated `?credential_id=<victim>` is REFUSED on an ARMED host" do
      SecurityHost.arm!()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), "/settings/security/2fa?credential_id=#{Ash.UUID.generate()}")
    end

    test "unauthenticated `?credential_id=<victim>` is REFUSED while DISARMED too" do
      # Unlike the tenant org gate, AUTHENTICATION here does not relax in dev: this surface
      # disables 2FA and re-enrolls secrets on a named credential.
      SecurityHost.disarm!()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), "/settings/security/2fa?credential_id=#{Ash.UUID.generate()}")
    end

    test "the dead render is refused too (no page, no credential id echoed)" do
      SecurityHost.arm!()
      victim_credential = Ash.UUID.generate()

      conn = get(build_conn(), "/settings/security/2fa?credential_id=#{victim_credential}")

      assert conn.status == 302
      assert redirected_to(conn) == "/login"
      refute response(conn, 302) =~ victim_credential
    end
  end

  # ==========================================================================
  # The gate itself — unit-level, so a regression names the cause
  # ==========================================================================

  describe "the route macros carry the gate" do
    test "every tenant live_session in the probe router declares :require_tenant" do
      sessions =
        Samen.WebTest.SecurityRouter
        |> Phoenix.Router.routes()
        |> Enum.map(& &1.metadata[:phoenix_live_view])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn lv -> elem(lv, 1) end)
        |> Enum.uniq()

      assert sessions != [], "route enumeration found no live_sessions — the guard is vacuous"

      for %{extra: %{on_mount: on_mount}} <- sessions do
        hooks = Enum.map(on_mount, & &1.id)

        assert Enum.any?(hooks, fn
                 {Samen.Web.TenantAuthz, :require_tenant} -> true
                 {Samen.Web.Auth, :ensure_authenticated} -> true
                 _ -> false
               end),
               "a tenant live_session carries no authz on_mount: #{inspect(hooks)}"
      end
    end
  end

  defp armed_settings_mount do
    Samen.Web.Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo,
      labels: %{
        otp_app: SecurityHost.otp_app(),
        authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
        authorized_orgs: {SecurityHost, :authorized_org_ids, []}
      }
    )
  end
end
