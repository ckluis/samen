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

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Flags.SettingsLive
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Primitives.FeatureFlag
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

    # S1a spine harness — invite/accept dispatches an invite email through the fail-honest
    # Delivery chokepoint; `:test` makes it a no-op (the invitation_test precedent).
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

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

  # ==========================================================================
  # S1a (ADR-045 §4.4) — the tenant write helpers no longer self-elevate a member
  # to :admin on an ARMED host: admin-rank writes require ACTUAL admin membership.
  # Driven end-to-end through the REAL flags LiveView + Identity spine.
  # ==========================================================================

  # ==========================================================================
  # A6 (ADR-047; the A5 verifier's R-A5-3 + its "could not prove here" #2) — the AGENT
  # surfaces now ride this LiveView-DRIVING harness, and the decision card's acting
  # principal is the AUTHENTICATED HUMAN rather than the synthetic per-org pseudo-id.
  # ==========================================================================

  describe "A6 — the agent surfaces are gated, and the deciding principal is a PERSON" do
    test "armed + unauthenticated: the agent run list AND detail are REFUSED (dead render + live)", ctx do
      SecurityHost.arm!()

      for path <- ["/ai/agents", "/ai/agents/#{Ash.UUID.generate()}"] do
        conn = get(build_conn(), "#{path}?org=#{ctx.victim_org}")
        assert conn.status == 302, "#{path} served an armed, unauthenticated dead render"
        assert redirected_to(conn) == "/login"

        assert {:error, {:redirect, %{to: "/login"}}} =
                 live(build_conn(), "#{path}?org=#{ctx.victim_org}")
      end
    end

    test "POSITIVE CONTROL: an authenticated member IS served the agent list for their own org" do
      SecurityHost.arm!()
      host = register_owner!()
      member = accept_into!(host, :member)

      html =
        session_conn(member.credential.id)
        |> get("/ai/agents?org=#{host.org.id}")
        |> html_response(200)

      assert html =~ "agent-run-list"
      assert html =~ "No agent runs yet"
    end

    test "the PRINCIPAL the decision card acts as is the authenticated human, not broker:<org_id>" do
      SecurityHost.arm!()
      host = register_owner!()
      member = accept_into!(host, :member)
      mount = ai_mount()

      # What A5 acted as — a per-ORG pseudo-principal, identical for every human in the org.
      broker = "broker:#{host.org.id}"
      assert %Samen.Scope{actor: %{id: ^broker}} = Mount.scope(mount, host.org.id)

      # What A6 acts as: the principal `Samen.Web.TenantAuthz` pins from the SIGNED session.
      session = %{Auth.session_token_key() => session_token!(member.credential.id)}
      {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, %{}, live_session(mount, session), fresh_socket())

      assert socket.assigns.samen_tenant_principal == member.credential.id
      refute socket.assigns.samen_tenant_principal == broker

      # FAIL-CLOSED: no principal in the session ⇒ nothing to decide as. (Armed hosts halt
      # outright; the assertion here is that nothing invents an identity.)
      disarmed_mount = disarmed_ai_mount()
      refute Samen.Web.CurrentOrg.tenant_gate_armed?(disarmed_mount)

      {:cont, disarmed} =
        Samen.Web.TenantAuthz.on_mount(:require_tenant, %{}, live_session(disarmed_mount, %{}), fresh_socket())

      assert disarmed.assigns.samen_tenant_principal == nil
    end

    test "the DISARMED dev posture still NAMES a signed-in human (it no longer discards the identity)" do
      SecurityHost.disarm!()
      host = register_owner!()
      member = accept_into!(host, :member)
      mount = disarmed_ai_mount()

      # NON-VACUITY: this leg must really be the DISARMED one (otherwise the armed branch
      # would assign the principal and the test would prove nothing about this fold).
      refute Samen.Web.CurrentOrg.tenant_gate_armed?(mount)

      session = %{Auth.session_token_key() => session_token!(member.credential.id)}

      {:cont, socket} =
        Samen.Web.TenantAuthz.on_mount(:require_tenant, %{}, live_session(mount, session), fresh_socket())

      # Unchanged: org authority stays unconstrained on the disarmed leg (byte-for-byte).
      assert socket.assigns.samen_authorized_orgs == :unconstrained
      # New: the human is named rather than discarded, so a CONSENT can be attributed.
      assert socket.assigns.samen_tenant_principal == member.credential.id
    end
  end

  describe "S1a — armed host, admin-rank write requires REAL admin membership" do
    test "the armed flags surface SERVES an authenticated member on the DEAD RENDER (TenantAuthz pins the principal)" do
      SecurityHost.arm!()
      host = register_owner!()
      member = accept_into!(host, :member)
      _flag = seed_flag(host.org.id)

      # The real endpoint + router + TenantAuthz on_mount: an armed, spine-authenticated member is
      # served (200), NOT halted — the flags MODULE surface is spine-capable via :identity_namespace.
      html =
        session_conn(member.credential.id)
        |> get("/flags?org=#{host.org.id}")
        |> html_response(200)

      assert html =~ "checkout.v2", "the member must see their own org's flags"
    end

    test "a NON-admin member's flag toggle is REFUSED (the DB row is unchanged)" do
      SecurityHost.arm!()
      host = register_owner!()
      member = accept_into!(host, :member)
      flag = seed_flag(host.org.id)

      _socket = toggle_flag(member.credential.id, host.org.id, flag.id)

      assert raw_flag(flag.id).enabled == true,
             "an armed member self-elevated to :admin and flipped the flag (S1a regression)"
    end

    test "POSITIVE CONTROL — an actual ADMIN member's toggle SUCCEEDS (anti-tautology)" do
      SecurityHost.arm!()
      host = register_owner!()
      admin = accept_into!(host, :admin)
      flag = seed_flag(host.org.id)

      _socket = toggle_flag(admin.credential.id, host.org.id, flag.id)

      assert raw_flag(flag.id).enabled == false,
             "a real admin member must still perform the admin-rank write on an armed host"
    end

    test "the DISARMED dev posture is UNCHANGED — a member's toggle still succeeds (byte-identical)" do
      SecurityHost.disarm!()
      host = register_owner!()
      member = accept_into!(host, :member)
      flag = seed_flag(host.org.id)

      _socket = toggle_flag(member.credential.id, host.org.id, flag.id)

      assert raw_flag(flag.id).enabled == false,
             "the sanctioned ADR-031 dev convenience (:admin) must be preserved verbatim"
    end

    test "TenantRole helper — real role, fail-CLOSED to :member, disarmed dev convenience" do
      host = register_owner!()
      admin = accept_into!(host, :admin)
      member = accept_into!(host, :member)
      mount = armed_flags_mount()

      # membership_role reads the REAL Identity.Membership through the ONE source of truth.
      assert TenantRole.membership_role(mount, host.org.id, admin.credential.id) == :admin
      assert TenantRole.membership_role(mount, host.org.id, member.credential.id) == :member
      # Fail-closed to least privilege (never :admin): no principal / no membership.
      assert TenantRole.membership_role(mount, host.org.id, nil) == :member
      assert TenantRole.membership_role(mount, host.org.id, Ash.UUID.generate()) == :member

      SecurityHost.arm!()
      assert TenantRole.admin_scope(mount, host.org.id, admin.credential.id).actor.role == :admin
      assert TenantRole.admin_scope(mount, host.org.id, member.credential.id).actor.role == :member

      SecurityHost.disarm!()
      # Disarmed → the byte-identical dev convenience, regardless of the caller's real role.
      assert TenantRole.admin_scope(mount, host.org.id, member.credential.id).actor.role == :admin
    end
  end

  # ==========================================================================
  # S1a (chat) — Chat.set_disclosure_setting/3's org-wide identity-exposure flip is
  # RoleAtLeast :admin-gated; the ThreadsLive "toggle_disclosure" event now enforces
  # real admin membership on an armed host (its "admin only" branch is reachable).
  # ==========================================================================

  describe "S1a (chat) — armed host, org-wide disclosure flip requires REAL admin membership" do
    test "a NON-admin member's toggle_disclosure is REFUSED (no ChatDisclosureSetting row written)" do
      SecurityHost.arm!()
      host = register_owner!()
      member = accept_into!(host, :member)

      _socket = toggle_disclosure(member.credential.id, host.org.id, true)

      refute disclosure_on?(host.org.id),
             "an armed member self-elevated to :admin and flipped org-wide identity disclosure (S1a)"
    end

    test "POSITIVE CONTROL — an actual ADMIN member's toggle_disclosure SUCCEEDS" do
      SecurityHost.arm!()
      host = register_owner!()
      admin = accept_into!(host, :admin)

      _socket = toggle_disclosure(admin.credential.id, host.org.id, true)

      assert disclosure_on?(host.org.id),
             "a real admin member must still flip org-wide disclosure on an armed host"
    end

    test "the DISARMED dev posture is UNCHANGED — a member's toggle_disclosure still succeeds" do
      SecurityHost.disarm!()
      host = register_owner!()
      member = accept_into!(host, :member)

      _socket = toggle_disclosure(member.credential.id, host.org.id, true)

      assert disclosure_on?(host.org.id),
             "the sanctioned dev convenience (:admin) must be preserved verbatim"
    end
  end

  # -- S1a spine harness --------------------------------------------------------

  defp register_mods,
    do: %{org: Op.Org, credential: Op.Credential, user: Op.User, membership: Op.Membership, auth_token: Op.AuthToken, repo: Samen.WebTest.Repo}

  defp invite_mods,
    do: %{invitation: Op.Invitation, credential: Op.Credential, user: Op.User, membership: Op.Membership, repo: Samen.WebTest.Repo}

  defp session_create_mods,
    do: %{session: Op.Session, org: Op.Org, membership: Op.Membership, user: Op.User}

  defp register_owner! do
    attrs = %{
      org_name: "S1a Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "s1a-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  # Land `invitee` into `host`'s org at `role` through the sanctioned invite/accept path — so
  # the acting principal holds a REAL `Identity.Membership` at exactly `role`.
  defp accept_into!(host, role) do
    invitee = register_owner!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    {:ok, _invitation, raw_token} =
      Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})

    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  defp session_conn(credential_id) do
    {:ok, _session, raw_session_token} = SessionCreate.create(session_create_mods(), credential_id)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(Auth.session_token_key(), raw_session_token)
  end

  defp seed_flag(org_id) do
    FeatureFlag
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "checkout.v2", enabled: true, rollout_pct: 100}, authorize?: false)
    |> Ash.create!()
  end

  defp raw_flag(id), do: Ash.get!(FeatureFlag, id, authorize?: false)

  # Drive the REAL flags LiveView at the callback level (the `flags_settings_crud_test` pattern —
  # a connected `live/2` socket needs the `lazy_html` test dep, ADR-045 §4.4 test-gap). The mount
  # is assigned through the REAL `Samen.Web.Live.assign_mount/2`, which stashes the principal (as
  # `Samen.Web.TenantAuthz`'s `on_mount` pins it) — so `write_scope/2` derives the REAL membership
  # role exactly as it does over the websocket.
  defp toggle_flag(principal, org_id, flag_id) do
    session = %{"samen_mount" => Mount.to_session(armed_flags_mount())}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_tenant_principal, principal)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Samen.Web.Live.assign_mount(session)
      |> SettingsLive.load(org_id)

    {:noreply, socket} = SettingsLive.handle_event("toggle_flag", %{"id" => flag_id}, socket)
    socket
  end

  # Drive the REAL ThreadsLive "toggle_disclosure" handle_event at the callback level (the same
  # pattern as `toggle_flag/3`) — proving the "admin only" error branch is now reachable for a
  # non-admin member on an armed host.
  defp toggle_disclosure(principal, org_id, expose?) do
    session = %{"samen_mount" => Mount.to_session(armed_chat_mount())}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_tenant_principal, principal)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Samen.Web.Live.assign_mount(session)
      |> Phoenix.Component.assign(:org_id, org_id)

    raw = if expose?, do: "on", else: "off"

    {:noreply, socket} =
      Samen.Web.Chat.ThreadsLive.handle_event("toggle_disclosure", %{"expose_identity" => raw}, socket)

    socket
  end

  # The org's persisted disclosure state, read through the framework's own OrgScope-gated read
  # (`Chat.disclosure_setting?/2`, role-agnostic) — the established verification path.
  defp disclosure_on?(org_id) do
    m = Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo)
    Samen.Web.Chat.disclosure_setting?(m, Mount.scope(m, org_id))
  end

  defp armed_chat_mount do
    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo,
      labels: %{
        otp_app: SecurityHost.otp_app(),
        authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
        identity_namespace: Samen.WebTest.Operator
      }
    )
  end

  defp ai_mount do
    Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
      labels: %{
        otp_app: SecurityHost.otp_app(),
        authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
        identity_namespace: Samen.WebTest.Operator
      }
    )
  end

  # The same AI mount with NO `:authn` seam — the explicitly disarmed dev/dogfood posture.
  defp disarmed_ai_mount do
    Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
      labels: %{identity_namespace: Samen.WebTest.Operator, param_trust: :disarmed}
    )
  end

  defp live_session(mount, session), do: Map.put(session, "samen_mount", Mount.to_session(mount))

  defp fresh_socket, do: %Phoenix.LiveView.Socket{}

  defp session_token!(credential_id) do
    {:ok, _session, raw} = SessionCreate.create(session_create_mods(), credential_id)
    raw
  end

  defp armed_flags_mount do
    Mount.new(:flags, Samen.WebTest.Primitives, Samen.WebTest.Repo,
      labels: %{
        otp_app: SecurityHost.otp_app(),
        authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
        identity_namespace: Samen.WebTest.Operator
      }
    )
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
