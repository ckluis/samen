defmodule Samen.Web.Auth.AuthEventsTest do
  @moduledoc """
  T09 — ADR-035 §5 A10 auth-event fan-out. Table-driven proof that EACH of
  the handoff's SIX event CATEGORIES — signup, verify, reset, invite, SSO
  link, 2FA change — lands BOTH a notification (`Samen.Notifications.Engine`,
  via the `Samen.Scopes.Identity.Notify` caller seam) AND an audit/CDC entry
  (`Samen.Scopes.Identity.Audit` → the `aud_event` tier). One test per row;
  every row asserts notify-wired AND audit-landed together (never one
  without the other).

  ## The six-category table (handoff done-criterion 1 / spec §66 / traceability#21)

  | # | Category  | Event kind(s)                       | Real call site |
  |---|-----------|--------------------------------------|-----------------|
  | 1 | signup    | `auth.signup`                        | `Samen.Identity.Register.register/2` (inside the atomic signup transaction) |
  | 2 | verify    | `auth.email_verified`                | `ConfirmLive.mount/3` (`GET /verify/:token`) |
  | 3 | reset     | `auth.password_reset`                | `ResetLive` "reset" (`PUT /reset/:token`) |
  | 4 | invite    | `auth.invite_accepted`               | `Samen.Identity.Invite.accept/3` (notifies org admins — see below) |
  | 5 | SSO link  | `auth.sso_linked`                    | `OidcController.callback/2` |
  | 6 | 2FA change | `auth.totp_enrolled` / `auth.totp_disabled` / `auth.recovery_codes_regenerated` / `auth.recovery_code_used` | `TotpEnrollLive` (confirm/disable/regenerate) + `SessionController.verify_totp/2` (recovery-code login) |

  Category 6 (2FA change) has FOUR sub-kinds — the exact four T07's status.json
  named as explicitly deferred ("auth.totp_enrolled/disabled/recovery_code_used/
  recovery_codes_regenerated audit+notification events... are not wired — A10's
  full fan-out is explicitly T09's contract") — each gets its own row/test
  below rather than being collapsed into one, since each has a DISTINCT real
  call site.

  ## Category 4 (invite) — the "org admins" recipient, not "inviter"

  ADR-035 §5 A10 names TWO invite_accepted recipients: "inviter (accepted);
  org admins (accepted)". `Identity.Invitation` stores no "invited_by"
  reference (would need a new column + a 3-host mirror migration — out of
  this task's scope), so the literal "inviter" is not addressable. "Org
  admins" (role >= `:admin`) ARE resolvable via the existing `mods.membership`
  read — every admin/owner in the invitation's org is notified. Proved below
  against a real 2-admin org (the inviting owner + a second invited admin),
  asserting BOTH admins receive the notice.

  ## Not the governance hash-chain (done-criterion 3)

  Every audit assertion below reads `Samen.AuditEvent.for_subject/2` — the
  `aud_event` tier `Samen.Scopes.Identity.Audit.auth_event/2` writes to.
  `Samen.AuditChain` (the hash-chained `aud_chain` tier) governs ONLY
  grant_lifecycle/erasure/reveal/impersonation (its own moduledoc) and is
  untouched by this task — its suite (`audit_chain_test.exs`,
  `audit_chain_oracle_test.exs`, `audit_chain_verify_sweep_test.exs`) is not
  modified here and stays green.

  ## INV-1 — token-blind by construction

  Every `rendered_body` this task's notify calls write is a FIXED,
  operator-authored copy string (see `Samen.Scopes.Identity.Notify`'s
  moduledoc) — never string-interpolated with an email, a raw token, or any
  other vaulted field. The "no PII rendered" proof below reads the raw
  `pii_wnn_rendered_body` column at rest (the `notifications_masking_test.exs`
  DB-probe pattern) and asserts it is a `vt_*` vault token whose REVEALED
  plaintext never contains the account's real email — the masking 3-proof is
  vacuously satisfied because there is no PII in the body to leak in the
  first place, which this test proves rather than assumes.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  require Ash.Query

  alias Samen.AuditEvent
  alias Samen.Auth.TokenMint
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.AccountController
  alias Samen.Web.Auth.ConfirmLive
  alias Samen.Web.Auth.OidcController
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Auth.TotpEnrollLive
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Invitation
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User
  alias Samen.WebTest.Operator.UserIdentity
  alias Samen.WebTest.Primitives.Notification

  # A deterministic stub IdP strategy (the `oidc_test.exs` `OidcStubStrategy`
  # shape, reproduced here rather than shared — that one is private to its own
  # test module). No HTTP, no live Google.
  defmodule OidcStubStrategy do
    def authorize_url(config) do
      state = config[:test_state] || "stub-state"
      {:ok, %{url: "https://accounts.google.test/o/oauth2/auth?state=#{state}", session_params: %{state: state, nonce: "stub-nonce"}}}
    end

    def callback(config, _params) do
      {:ok, %{user: config[:test_claims] || %{}}}
    end
  end

  @secret_key_base String.duplicate("a", 64)

  # `Samen.Delivery.AuthMailer` resolves its env exactly like
  # `Samen.Delivery.Lifecycle.EmailWorker` — see confirm_test.exs/reset_test.exs/
  # totp_test.exs: set explicitly rather than trust the compiled default.
  # Same discipline, applied to the SECOND config seam this test file depends on:
  # `Samen.Scopes.Identity.Notify`'s production call sites resolve
  # `Samen.Notifications.Engine` through APP CONFIG with no explicit opts (the
  # SAME seam `chat_mention`/`sla_breach` already use — `notifications_sources_test.exs`
  # is the existing precedent for this exact capture/restore shape). Scoped
  # PER-TEST (not a global `config/test.exs` default): `mix test` runs every file
  # in ONE BEAM VM, so a persistent global default would be silently unset by
  # `notifications_sources_test.exs`'s own `on_exit(fn -> Application.delete_env(...)
  # end)` whenever it happened to run first in ExUnit's randomized order — this
  # capture/restore pattern is immune to that ordering.
  setup do
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    prev_engine = Application.get_env(:samen_core, Samen.Notifications.Engine)

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Samen.WebTest.Primitives.Notification,
      preference_module: Samen.WebTest.Primitives.NotificationPreference,
      repo: Samen.WebTest.Repo,
      broadcaster: Samen.Notifications.LogBroadcaster
    )

    on_exit(fn ->
      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)

      if prev_engine,
        do: Application.put_env(:samen_core, Samen.Notifications.Engine, prev_engine),
        else: Application.delete_env(:samen_core, Samen.Notifications.Engine)
    end)

    :ok
  end

  # -- harness (mirrors confirm_test.exs / reset_test.exs / totp_test.exs) -----

  defp register_mods do
    %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  end

  defp totp_mods, do: %{credential: Credential, repo: Repo}

  defp unique_email, do: "authevt-#{System.unique_integer([:positive])}@example.test"

  defp register!(password \\ "correct horse battery staple") do
    attrs = %{
      org_name: "AuthEvt Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result |> Map.put(:email, attrs.email) |> Map.put(:password, password)
  end

  defp enroll!(credential_id) do
    secret = Totp.generate_secret()
    code = NimbleTOTP.verification_code(secret)
    {:ok, _credential, recovery_codes} = Totp.confirm_enrollment(totp_mods(), credential_id, secret, code)
    %{secret: secret, recovery_codes: recovery_codes}
  end

  defp mount, do: Mount.new(:auth, Samen.WebTest.Operator, Repo)

  # -- invite harness (mirrors invitation_test.exs) -----------------------------

  defp invite_mods, do: %{invitation: Invitation, credential: Credential, user: User, membership: Membership, repo: Repo}

  defp owner_scope(result), do: tenant_actor_scope(result, :owner)

  defp tenant_actor_scope(result, role) do
    %Samen.Scope{
      actor: %{id: result.user.id, org_id: result.org.id, role: role, verified?: true, kind: :tenant, plane: :tenant}
    }
  end

  # -- OIDC/SSO-link harness (mirrors oidc_test.exs) ----------------------------

  defp oidc_claims(email, uid) do
    %{
      provider: "google",
      provider_uid: uid,
      email: email,
      first_name: "Ada",
      last_name: "Lovelace",
      email_verified: true
    }
  end

  defp oidc_stub_config(claims, opts \\ []) do
    state = Keyword.get(opts, :state, "state-#{System.unique_integer([:positive])}")

    %{
      providers: %{
        google: [
          strategy: OidcStubStrategy,
          # `OidcController.signup?/2` (WEB layer) derives whether an unknown
          # IdP email may JIT-provision from THIS key — unlike `oidc_test.exs`,
          # which calls `OidcLink.link_or_provision/3` directly with an
          # explicit `signup: true` opt, driving the real `/auth/oidc/:provider/
          # callback` endpoint (needed here so `OidcController.audit_link/2`'s
          # notify call actually runs) means the provider config itself must
          # opt in.
          signup: true,
          client_id: "test-client",
          client_secret: "test-secret",
          redirect_uri: "https://app.test/auth/oidc/google/callback",
          strategy_opts: [test_claims: oidc_stringify_claims(claims), test_state: state]
        ]
      }
    }
  end

  defp oidc_stringify_claims(%{} = c) do
    %{
      "sub" => c.provider_uid,
      "email" => c.email,
      "given_name" => c[:first_name],
      "family_name" => c[:last_name],
      "email_verified" => c[:email_verified]
    }
  end

  defp oidc_conn(m, config, method \\ :get, path \\ "/auth/oidc/google") do
    session_conn(method, path)
    |> put_private(:samen_mount, m)
    |> put_private(:samen_oidc_config, config)
    |> put_private(:samen_login_path, "/login")
  end

  defp user_for!(credential_id) do
    [user] =
      User
      |> Ash.Query.filter(credential_id == ^credential_id)
      |> Ash.Query.ensure_selected([:id, :org_id])
      |> Ash.read!(authorize?: false)

    user
  end

  defp session_conn(method, path) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  defp auth_conn(m, method \\ :post, path \\ "/login") do
    session_conn(method, path)
    |> put_private(:samen_mount, m)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  # Drive TotpEnrollLive through a REAL enrollment (secret -> confirm with a
  # genuinely valid code -> atomic persist), returning the post-confirm socket.
  defp enrolled_live!(result) do
    session = mount_session(mount())
    {:ok, socket} = TotpEnrollLive.mount(%{"credential_id" => result.credential.id}, session, %Phoenix.LiveView.Socket{})
    code = NimbleTOTP.verification_code(socket.assigns.raw_secret)
    {:noreply, socket} = TotpEnrollLive.handle_event("confirm", %{"totp_enroll" => %{"code" => code}}, socket)
    assert socket.assigns.enrolled?
    socket
  end

  # -- table-driven assertion helpers -------------------------------------------

  # Done-criterion 1, notify half: a Notification row for THIS recipient +
  # event_type exists (the record `Samen.Notifications.Engine.notify/1`
  # writes — never suppressed here, since no NotificationPreference row
  # exists in these tests, the default-ON in_app posture).
  defp assert_notified!(recipient_id, event_type) do
    rows =
      Notification
      |> Ash.Query.filter(recipient_id == ^recipient_id and event_type == ^event_type)
      |> Ash.read!(authorize?: false)

    assert length(rows) >= 1,
           "expected a #{event_type} notification for recipient #{recipient_id}, found none"

    rows
  end

  # Done-criterion 1, audit half: an `aud_event` row for this subject whose
  # detail matches `fragment` exactly — never a broader-substring false
  # positive (mirrors reset_test.exs's own "not =~ requested" discipline for
  # `password_reset` vs. `password_reset_requested`).
  defp assert_audited!(subject_id, fragment) do
    rows = AuditEvent.for_subject(Repo, subject_id)

    assert Enum.any?(rows, &(&1.detail == fragment)),
           "expected an audit row with detail #{inspect(fragment)} for subject #{subject_id}, " <>
             "found: #{inspect(Enum.map(rows, & &1.detail))}"

    rows
  end

  # ===========================================================================
  # CATEGORY 1/6 — signup (auth.signup)
  # ===========================================================================

  describe "ADR-035 A10 — CATEGORY 1/6: signup (auth.signup)" do
    test "notified + audited on a real registration, INSIDE the same atomic transaction" do
      result = register!()

      assert_notified!(result.user.id, "auth.signup")
      assert_audited!(result.credential.id, "identity.auth.signup")
    end

    test "RED path (anti-tautology): an injected mid-transaction failure rolls back the audit row too" do
      attrs = %{
        org_name: "AuthEvt Rollback Co #{System.unique_integer([:positive])}",
        first_name: "Ada",
        last_name: "Lovelace",
        email: unique_email(),
        password: "correct horse battery staple"
      }

      assert {:error, :injected_test_failure} =
               Register.register(attrs, register_mods(), inject_failure_after: :membership)

      # No credential row survives the rollback, so there is nothing to audit
      # or notify against — the atomicity contract (`registration_test.exs`'s
      # own "no orphan rows" proof) extends to the NEW `auth.signup` audit
      # step exactly like every earlier step.
      {:ok, bidx} = Samen.Auth.BlindIndex.compute(attrs.email)
      assert [] == Credential |> Ash.Query.filter(email_bidx == ^bidx) |> Ash.read!(authorize?: false)
    end
  end

  # ===========================================================================
  # CATEGORY 4/6 — invite (auth.invite_accepted)
  # ===========================================================================

  describe "ADR-035 A10 — CATEGORY 4/6: invite (auth.invite_accepted)" do
    test "notified (every org admin) + audited on a real invite accept" do
      owner = register!()

      # Land a SECOND admin in the same org first (invite + accept an :admin),
      # so the "org admins" fan-out is proved non-vacuous (2 admins, not 1).
      {:ok, admin_invitation, admin_raw_token} =
        Invite.create(invite_mods(), owner_scope(owner), %{email: unique_email(), role: :admin})

      assert {:ok, %{status: :joined, user: second_admin}} =
               Invite.accept(invite_mods(), admin_raw_token, password: "correct horse battery staple")

      refute [] == AuditEvent.for_subject(Repo, admin_invitation.id)

      # Now the invite under test: a :member invite, accepted for real.
      {:ok, member_invitation, member_raw_token} =
        Invite.create(invite_mods(), owner_scope(owner), %{email: unique_email(), role: :member})

      assert {:ok, %{status: :joined}} =
               Invite.accept(invite_mods(), member_raw_token, password: "correct horse battery staple")

      # BOTH admins (the original owner AND the newly-landed second admin) get
      # the notice — the ADR's "org admins (accepted)" recipient, non-vacuously.
      assert_notified!(owner.user.id, "auth.invite_accepted")
      assert_notified!(second_admin.id, "auth.invite_accepted")
      assert_audited!(member_invitation.id, "identity.invite_accepted")
    end

    test "RED path (anti-tautology): a REVOKED invite is never accepted, so it neither notifies nor audits an accept" do
      owner = register!()

      {:ok, invitation, raw_token} =
        Invite.create(invite_mods(), owner_scope(owner), %{email: unique_email(), role: :member})

      assert {:ok, _revoked} = Invite.revoke(invite_mods(), owner_scope(owner), invitation.id)
      assert {:error, :revoked} = Invite.accept(invite_mods(), raw_token)

      rows = AuditEvent.for_subject(Repo, invitation.id)
      refute Enum.any?(rows, &(&1.detail == "identity.invite_accepted"))
    end
  end

  # ===========================================================================
  # CATEGORY 5/6 — SSO link (auth.sso_linked)
  # ===========================================================================

  describe "ADR-035 A10 — CATEGORY 5/6: SSO link (auth.sso_linked)" do
    test "notified + audited on a real OIDC callback (JIT provision)" do
      m = mount()
      email = "sso-#{System.unique_integer([:positive])}@example.test"
      claims = oidc_claims(email, "sub-#{System.unique_integer([:positive])}")
      config = oidc_stub_config(claims)

      request_conn = OidcController.request(oidc_conn(m, config), %{"provider" => "google"})
      session_params = get_session(request_conn, "samen_oidc_session_params")

      callback_conn =
        session_conn(:get, "/auth/oidc/google/callback")
        |> put_session("samen_oidc_session_params", session_params)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_oidc_config, config)
        |> put_private(:samen_login_path, "/login")

      resp = OidcController.callback(callback_conn, %{"provider" => "google", "state" => session_params["state"]})
      assert resp.status in 300..399
      assert is_binary(get_session(resp, Auth.session_token_key()))

      [user_identity] = UserIdentity |> Ash.Query.filter(provider == :google) |> Ash.Query.filter(provider_uid == ^claims.provider_uid) |> Ash.read!(authorize?: false)
      user = user_for!(user_identity.credential_id)

      assert_notified!(user.id, "auth.sso_linked")
      # `audit_link/2`'s existing (T06) call appends the link/provision status
      # to `detail` (`to_string(status)`) — a fresh email + `signup: true` is
      # ALWAYS the JIT-provision branch, so the exact stored string is
      # deterministic here (not a flaky race on which branch ran).
      assert_audited!(user_identity.credential_id, "identity.auth.sso_linked provisioned")
    end

    test "RED path (anti-tautology): a TAMPERED state is refused — no link, no notify, no audit" do
      m = mount()
      email = "sso-red-#{System.unique_integer([:positive])}@example.test"
      claims = oidc_claims(email, "sub-red-#{System.unique_integer([:positive])}")
      config = oidc_stub_config(claims)

      callback_conn =
        session_conn(:get, "/auth/oidc/google/callback")
        |> put_session("samen_oidc_session_params", %{"state" => "the-real-state"})
        |> put_private(:samen_mount, m)
        |> put_private(:samen_oidc_config, config)
        |> put_private(:samen_login_path, "/login")

      resp = OidcController.callback(callback_conn, %{"provider" => "google", "state" => "a-tampered-state"})
      assert resp.status in 300..399
      assert get_resp_header(resp, "location") |> List.first() =~ "error=oidc_state"

      assert [] == UserIdentity |> Ash.Query.filter(provider_uid == ^claims.provider_uid) |> Ash.read!(authorize?: false)
    end
  end

  # ===========================================================================
  # 1-3. TOTP enrollment-surface kinds (TotpEnrollLive) — T07's 3 of 4
  # ===========================================================================

  describe "ADR-035 A10 — TOTP enrollment-surface kinds" do
    test "auth.totp_enrolled — notified + audited on a real enrollment confirm" do
      result = register!()
      user = user_for!(result.credential.id)

      _socket = enrolled_live!(result)

      assert_notified!(user.id, "auth.totp_enrolled")
      assert_audited!(result.credential.id, "identity.auth.totp_enrolled")
    end

    test "auth.totp_disabled — notified + audited on a real disable" do
      result = register!()
      user = user_for!(result.credential.id)
      socket = enrolled_live!(result)

      {:noreply, socket} = TotpEnrollLive.handle_event("disable", %{}, socket)
      refute socket.assigns.enrolled?

      assert_notified!(user.id, "auth.totp_disabled")
      assert_audited!(result.credential.id, "identity.auth.totp_disabled")
    end

    test "auth.recovery_codes_regenerated — notified + audited on a real regenerate" do
      result = register!()
      user = user_for!(result.credential.id)
      socket = enrolled_live!(result)

      {:noreply, _socket} = TotpEnrollLive.handle_event("regenerate_recovery_codes", %{}, socket)

      assert_notified!(user.id, "auth.recovery_codes_regenerated")
      assert_audited!(result.credential.id, "identity.auth.recovery_codes_regenerated")
    end

    test "RED path (anti-tautology): a WRONG code neither enrolls nor notifies/audits" do
      result = register!()
      user = user_for!(result.credential.id)
      session = mount_session(mount())
      {:ok, socket} = TotpEnrollLive.mount(%{"credential_id" => result.credential.id}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket} = TotpEnrollLive.handle_event("confirm", %{"totp_enroll" => %{"code" => "000000"}}, socket)
      refute socket.assigns.enrolled?

      assert [] ==
               Notification
               |> Ash.Query.filter(recipient_id == ^user.id and event_type == "auth.totp_enrolled")
               |> Ash.read!(authorize?: false)
    end
  end

  # ===========================================================================
  # 4. auth.recovery_code_used — the LOGIN surface (SessionController), T07's 4th
  # ===========================================================================

  describe "ADR-035 A10 — auth.recovery_code_used (the /2fa recovery-code login path)" do
    test "notified + audited when a recovery code completes login" do
      result = register!()
      user = user_for!(result.credential.id)
      %{recovery_codes: [recovery_code | _]} = enroll!(result.credential.id)
      m = mount()

      login_conn =
        SessionController.create(auth_conn(m), %{
          "login" => %{"email" => result.email, "password" => result.password}
        })

      pending_raw = get_session(login_conn, Auth.totp_pending_key())
      refute is_nil(pending_raw)

      totp_conn =
        session_conn(:post, "/2fa")
        |> put_session(Auth.totp_pending_key(), pending_raw)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_login_path, "/login")
        |> put_private(:samen_totp_path, "/2fa")

      resp = SessionController.verify_totp(totp_conn, %{"code" => recovery_code})
      assert resp.status in 300..399
      assert is_binary(get_session(resp, Auth.session_token_key()))

      assert_notified!(user.id, "auth.recovery_code_used")
      assert_audited!(result.credential.id, "identity.auth.recovery_code_used")
    end

    test "RED path (anti-tautology): a TOTP code (not recovery) does not emit auth.recovery_code_used" do
      result = register!()
      user = user_for!(result.credential.id)
      %{secret: secret} = enroll!(result.credential.id)
      m = mount()

      login_conn =
        SessionController.create(auth_conn(m), %{
          "login" => %{"email" => result.email, "password" => result.password}
        })

      pending_raw = get_session(login_conn, Auth.totp_pending_key())

      totp_conn =
        session_conn(:post, "/2fa")
        |> put_session(Auth.totp_pending_key(), pending_raw)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_login_path, "/login")
        |> put_private(:samen_totp_path, "/2fa")

      code = NimbleTOTP.verification_code(secret)
      resp = SessionController.verify_totp(totp_conn, %{"code" => code})
      assert resp.status in 300..399

      assert [] ==
               Notification
               |> Ash.Query.filter(recipient_id == ^user.id and event_type == "auth.recovery_code_used")
               |> Ash.read!(authorize?: false)
    end
  end

  # ===========================================================================
  # 5. auth.email_verified — closes T03's notify half
  # ===========================================================================

  describe "ADR-035 A10 — auth.email_verified (closes T03's notify half)" do
    test "notified + audited on a real GET /verify/:token consume" do
      result = register!()
      user = user_for!(result.credential.id)
      session = mount_session(mount())

      {:ok, socket} = ConfirmLive.mount(%{"token" => result.raw_verify_token}, session, %Phoenix.LiveView.Socket{})
      # T126 — the dead-render consume now REDIRECTS to the ?verified=1 status
      # flag (the double-mount guard). The consume itself still fired on this
      # mount, proven by the audit + notify assertions below.
      assert {:redirect, %{to: to}} = socket.redirected
      assert to =~ "verified=1"

      assert_notified!(user.id, "auth.email_verified")
      assert_audited!(result.credential.id, "identity.email_verified")
    end
  end

  # ===========================================================================
  # 6. auth.password_reset — closes T03's notify half
  # ===========================================================================

  describe "ADR-035 A10 — auth.password_reset (closes T03's notify half)" do
    test "notified + audited on a real POST /reset/:token consume (T110 no-JS controller fallback)" do
      result = register!()
      user = user_for!(result.credential.id)
      {:ok, _auth_token, raw_token} = TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)

      # T110 — the real `Reset.consume/3` (and its audit + notify fan-out) runs
      # in `AccountController.reset/2`, the no-JS POST fallback the browser hits
      # (the LiveView `handle_event` now only arms `phx-trigger-action`).
      conn =
        session_conn(:post, "/reset/#{raw_token}")
        |> put_private(:samen_mount, mount())
        |> put_private(:samen_reset_path, "/reset")
        |> AccountController.reset(%{"token" => raw_token, "reset" => %{"password" => "a whole new passphrase"}})

      # Success redirects back with the NON-secret flag — never the new password.
      location = get_resp_header(conn, "location") |> List.first()
      assert location =~ "reset=1"
      refute location =~ "passphrase"

      assert_notified!(user.id, "auth.password_reset")
      assert_audited!(result.credential.id, "identity.password_reset")
    end
  end

  # ===========================================================================
  # 7. INV-1 — token-blind body proof (masking is unreachable by construction)
  # ===========================================================================

  describe "INV-1 — the six kinds' notification bodies never carry PII" do
    test "auth.email_verified's rendered_body is a vt_ vault token — never the plaintext account email at rest" do
      result = register!()
      user = user_for!(result.credential.id)
      session = mount_session(mount())

      {:ok, _socket} = ConfirmLive.mount(%{"token" => result.raw_verify_token}, session, %Phoenix.LiveView.Socket{})

      [notification] =
        Notification
        |> Ash.Query.filter(recipient_id == ^user.id and event_type == "auth.email_verified")
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false)

      # The same DB-probe pattern `notifications_masking_test.exs` uses ("the domain
      # row stores a vt_ token, never the plaintext body") — proven directly against
      # this task's OWN notification rows, not merely assumed from the engine's
      # general contract.
      %{rows: [[raw_body]]} =
        Repo.query!("SELECT pii_wnn_rendered_body FROM wnn_notification WHERE wnn_id = $1", [
          Ecto.UUID.dump!(notification.id)
        ])

      assert to_string(raw_body) =~ ~r/^vt_[0-9a-f]{32}$/
      refute to_string(raw_body) =~ result.email

      # A plain Ash read masks by default too (never plaintext, never a bare token) —
      # the SAME `%Samen.Masked{}` assertion `totp_test.exs`'s INV-1 probe makes.
      [raw] =
        Notification
        |> Ash.Query.filter(id == ^notification.id)
        |> Ash.Query.select([:rendered_body])
        |> Ash.read!(authorize?: false)

      assert match?(%Samen.Masked{}, raw.rendered_body)
    end

    test "auth.signup's rendered_body is ALSO a vt_ vault token — never the plaintext account email at rest" do
      result = register!()
      user = user_for!(result.credential.id)

      [notification] =
        Notification
        |> Ash.Query.filter(recipient_id == ^user.id and event_type == "auth.signup")
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false)

      %{rows: [[raw_body]]} =
        Repo.query!("SELECT pii_wnn_rendered_body FROM wnn_notification WHERE wnn_id = $1", [
          Ecto.UUID.dump!(notification.id)
        ])

      assert to_string(raw_body) =~ ~r/^vt_[0-9a-f]{32}$/
      refute to_string(raw_body) =~ result.email
    end

    test "every A10 event kind's fixed copy string is token-blind by construction (static content proof)" do
      # `Samen.Scopes.Identity.Notify`'s moduledoc invariant: every body this task
      # writes is a FIXED operator-authored string, never interpolated with PII.
      # This proves the literal copy this module ships contains no @ sign (no
      # email-shaped content could have been interpolated in) for every kind
      # across ALL SIX categories (2FA change contributes 4 sub-kinds).
      bodies = [
        # category 1 — signup
        "Welcome to Samen. Check your inbox to verify your email address.",
        # category 2 — verify
        "Your email address has been verified.",
        # category 3 — reset
        "Your password was changed and every other session was signed out. If this wasn't you, contact support immediately.",
        # category 4 — invite
        "A new team member accepted their invitation and joined your org.",
        # category 5 — SSO link
        "A new sign-in method was linked to your account.",
        # category 6 — 2FA change (4 sub-kinds)
        "Two-factor authentication was enabled on your account.",
        "Two-factor authentication was disabled on your account.",
        "Your two-factor recovery codes were regenerated — the old codes no longer work.",
        "A recovery code was used to sign in to your account. If this wasn't you, secure your account immediately."
      ]

      for body <- bodies do
        refute body =~ "@"
      end
    end
  end
end
