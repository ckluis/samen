defmodule Samen.Web.Auth.LoginEventsTest do
  @moduledoc """
  T101 — ADR-035 §5 A10, the login-family rows T09's verifier confirmed were
  ownerless (`_orch/verify/T09-verdict.json` scope_table row 8): `auth.login`,
  `auth.login_failed`, `auth.logout`, `auth.session_revoked`,
  `auth.sessions_revoked_all`. Sibling to `auth_events_test.exs` (T09's
  six-category table) rather than an extension of it — same helpers/harness
  shape, same `Samen.Scopes.Identity.{Audit,Notify}` seam, same `aud_event`
  tier, deliberately NOT touching T09's file.

  ## The five-row table (handoff done-criterion 1) + the ADR-035 §5 A10 notify
  ## policy read straight off the taxonomy table (§357-376 of the ADR):

  | # | Kind                       | Audit | Notify | Real call site (SessionController) |
  |---|----------------------------|-------|--------|--------------------------------------|
  | 1 | `auth.login`               | yes   | NO     | `finish_login/4` (the ONE session-mint chokepoint) |
  | 2 | `auth.login_failed`        | yes   | NO     | `create/2`'s failure branch; `complete_second_factor/5`'s failure branch |
  | 3 | `auth.logout`              | yes   | NO     | `delete/2` |
  | 4 | `auth.session_revoked`     | yes   | YES    | `revoke/2` |
  | 5 | `auth.sessions_revoked_all`| yes   | YES    | `revoke_others/2` |

  The ADR row for logout/session_revoked/sessions_revoked_all reads "✓ on
  revoke-by-another-session" — logout is a session ending ITSELF (never
  "another session" acting on it), so it stays notify-NO; the two
  Settings/Security controls (`revoke/2`, `revoke_others/2`) are BY
  CONSTRUCTION "the current session revoking a different one", so they are
  the notify-YES rows. See `session_controller.ex`'s own moduledoc for the
  full policy writeup this task documents at the wiring site.

  ## Not the governance hash-chain (mirrors `auth_events_test.exs`'s own note)

  Every audit assertion below reads `Samen.AuditEvent.for_subject/2` — the
  `aud_event` tier `Samen.Scopes.Identity.Audit.auth_event/2` writes to.
  `Samen.AuditChain` (the `aud_chain` hash-chain) is untouched by this task.

  ## INV-1 — token-blind, no account-existence oracle at audit time

  `auth.login_failed` against a KNOWN account sets `subject_id` (findable,
  the T09 `sso_linked` lesson); against an UNKNOWN email it does a read-only
  blind-index lookup (never a vault write — no new `Credential`/`User`/vault
  row appears) and leaves `subject_id` nil. Either way `detail` is the fixed
  string `Audit.auth_event/2` defaults to (`"identity.auth.login_failed"`) —
  never the attempted email.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Samen.Auth.SessionCreate
  alias Samen.AuditEvent
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User
  alias Samen.WebTest.Primitives.Notification

  @secret_key_base String.duplicate("a", 64)

  # Same capture/restore discipline `auth_events_test.exs` documents at length:
  # `Samen.Delivery.AuthMailer` AND `Samen.Scopes.Identity.Notify`'s production
  # call sites both resolve their env/engine config from application env with
  # no explicit opts, so both are set PER-TEST (immune to `mix test`'s
  # randomized file order clobbering a global default).
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

  # -- harness (mirrors auth_events_test.exs / session_test.exs) ---------------

  defp register_mods, do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  defp session_create_mods, do: %{session: Session, org: Org, membership: Membership, user: User}
  defp totp_mods, do: %{credential: Credential, repo: Repo}

  defp unique_email, do: "loginevt-#{System.unique_integer([:positive])}@example.test"

  defp register!(password \\ "correct horse battery staple") do
    attrs = %{
      org_name: "LoginEvt Co #{System.unique_integer([:positive])}",
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

  defp auth_conn(m), do: session_conn(:post, "/login") |> put_private(:samen_mount, m) |> put_private(:samen_login_path, "/login")

  defp totp_conn(m, pending_raw) do
    session_conn(:post, "/2fa")
    |> put_session(Auth.totp_pending_key(), pending_raw)
    |> put_private(:samen_mount, m)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  defp logged_in_conn(m, credential_id, path, method \\ :get) do
    {:ok, _session, raw} = SessionCreate.create(session_create_mods(), credential_id)

    session_conn(method, path)
    |> put_session(Auth.session_token_key(), raw)
    |> put_private(:samen_mount, m)
    |> put_private(:samen_login_path, "/login")
  end

  # Done-criterion 1, notify half.
  defp assert_notified!(recipient_id, event_type) do
    rows =
      Notification
      |> Ash.Query.filter(recipient_id == ^recipient_id and event_type == ^event_type)
      |> Ash.read!(authorize?: false)

    assert length(rows) >= 1,
           "expected a #{event_type} notification for recipient #{recipient_id}, found none"

    rows
  end

  defp refute_notified!(recipient_id, event_type) do
    rows =
      Notification
      |> Ash.Query.filter(recipient_id == ^recipient_id and event_type == ^event_type)
      |> Ash.read!(authorize?: false)

    assert rows == [],
           "expected NO #{event_type} notification for recipient #{recipient_id}, found #{length(rows)}"
  end

  # Done-criterion 1, audit half — findable via `for_subject/2` (subject_id set).
  defp assert_audited!(subject_id, fragment) do
    rows = AuditEvent.for_subject(Repo, subject_id)

    assert Enum.any?(rows, &(&1.detail == fragment)),
           "expected an audit row with detail #{inspect(fragment)} for subject #{subject_id}, " <>
             "found: #{inspect(Enum.map(rows, & &1.detail))}"

    rows
  end

  # ===========================================================================
  # 1/5 — auth.login: audited, NO notify
  # ===========================================================================

  describe "ADR-035 A10 — 1/5: auth.login" do
    test "a successful login is audited (subject_id set, findable) and NOT notified" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)

      conn = SessionController.create(auth_conn(m), %{"login" => %{"email" => result.email, "password" => result.password}})

      assert conn.status in 300..399
      assert is_binary(get_session(conn, Auth.session_token_key()))

      assert_audited!(result.credential.id, "identity.auth.login")
      refute_notified!(user.id, "auth.login")
    end

    test "the post-2FA login path ALSO lands auth.login (finish_login/4 is the single chokepoint)" do
      result = register!()
      user = user_for!(result.credential.id)
      %{secret: secret} = enroll!(result.credential.id)
      m = mount()

      login_conn = SessionController.create(auth_conn(m), %{"login" => %{"email" => result.email, "password" => result.password}})
      pending_raw = get_session(login_conn, Auth.totp_pending_key())
      refute is_nil(pending_raw)

      code = NimbleTOTP.verification_code(secret)
      resp = SessionController.verify_totp(totp_conn(m, pending_raw), %{"code" => code})

      assert resp.status in 300..399
      assert is_binary(get_session(resp, Auth.session_token_key()))

      assert_audited!(result.credential.id, "identity.auth.login")
      refute_notified!(user.id, "auth.login")
    end
  end

  # ===========================================================================
  # 2/5 — auth.login_failed: audited, NO notify, token-blind (INV-1)
  # ===========================================================================

  describe "ADR-035 A10 — 2/5: auth.login_failed" do
    test "a wrong-password attempt against a KNOWN account is audited (subject_id set) and NOT notified" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)
      before_sessions = Ash.count!(Session, authorize?: false)

      conn = SessionController.create(auth_conn(m), %{"login" => %{"email" => result.email, "password" => "totally-wrong"}})

      assert conn |> get_resp_header("location") |> List.first() == "/login?error=1"
      assert Ash.count!(Session, authorize?: false) == before_sessions

      assert_audited!(result.credential.id, "identity.auth.login_failed")
      refute_notified!(user.id, "auth.login_failed")
    end

    test "a wrong-code /2fa attempt against a RESOLVED pending login is ALSO auth.login_failed, subject_id set" do
      result = register!()
      user = user_for!(result.credential.id)
      enroll!(result.credential.id)
      m = mount()

      login_conn = SessionController.create(auth_conn(m), %{"login" => %{"email" => result.email, "password" => result.password}})
      pending_raw = get_session(login_conn, Auth.totp_pending_key())

      resp = SessionController.verify_totp(totp_conn(m, pending_raw), %{"code" => "000000"})

      assert resp |> get_resp_header("location") |> List.first() == "/2fa?error=1"
      refute is_binary(get_session(resp, Auth.session_token_key()))

      assert_audited!(result.credential.id, "identity.auth.login_failed")
      refute_notified!(user.id, "auth.login_failed")
    end

    test "RED (INV-1): a wrong-password attempt against an UNKNOWN email is audited token-blind, vault-writes NOTHING new" do
      m = mount()
      unknown_email = unique_email()
      before_credentials = Ash.count!(Credential, authorize?: false)
      before_sessions = Ash.count!(Session, authorize?: false)

      conn = SessionController.create(auth_conn(m), %{"login" => %{"email" => unknown_email, "password" => "whatever"}})

      # Same generic outcome as the known-account wrong-password case (no oracle).
      assert conn |> get_resp_header("location") |> List.first() == "/login?error=1"

      # No new Credential (or Session) row anywhere — the audit-time lookup is
      # a READ, never a write; failed attempts against unknown identifiers
      # must not vault-write anything new.
      assert Ash.count!(Credential, authorize?: false) == before_credentials
      assert Ash.count!(Session, authorize?: false) == before_sessions

      # The audit row for THIS attempt has subject_id nil (no credential to
      # key on) — not findable via for_subject/2, but it exists and is
      # token-blind: the fixed detail string, never the attempted email.
      rows =
        Repo.all(
          from(a in AuditEvent, where: a.detail == "identity.auth.login_failed" and is_nil(a.subject_id))
        )

      assert Enum.any?(rows), "expected at least one subject_id-less auth.login_failed row for the unknown-email attempt"
      refute Enum.any?(rows, &(&1.detail =~ unknown_email))
    end
  end

  # ===========================================================================
  # 3/5 — auth.logout: audited, NO notify
  # ===========================================================================

  describe "ADR-035 A10 — 3/5: auth.logout" do
    test "logging out is audited and NOT notified (self-ending session, not revoke-by-another-session)" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)

      conn = logged_in_conn(m, result.credential.id, "/logout")
      conn = SessionController.delete(conn, %{})

      assert conn.status in 300..399
      assert_audited!(result.credential.id, "identity.auth.logout")
      refute_notified!(user.id, "auth.logout")
    end
  end

  # ===========================================================================
  # 4/5 — auth.session_revoked: audited, notify YES
  # ===========================================================================

  describe "ADR-035 A10 — 4/5: auth.session_revoked (Settings/Security per-row revoke)" do
    test "revoking a NAMED session is audited AND notifies the credential owner" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)
      {:ok, _current, current_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, target, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn(:post, "/settings/security/sessions/#{target.id}/revoke")
        |> put_session(Auth.session_token_key(), current_raw)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.revoke(conn, %{"id" => target.id})
      assert conn.status in 300..399

      assert_audited!(result.credential.id, "identity.auth.session_revoked")
      assert_notified!(user.id, "auth.session_revoked")
    end

    test "RED (anti-tautology): revoking an already-gone/foreign session id neither audits nor notifies" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)
      {:ok, _current, current_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      fake_id = Ecto.UUID.generate()

      conn =
        session_conn(:post, "/settings/security/sessions/#{fake_id}/revoke")
        |> put_session(Auth.session_token_key(), current_raw)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.revoke(conn, %{"id" => fake_id})
      assert conn.status in 300..399

      refute Enum.any?(AuditEvent.for_subject(Repo, result.credential.id), &(&1.detail == "identity.auth.session_revoked"))
      refute_notified!(user.id, "auth.session_revoked")
    end
  end

  # ===========================================================================
  # 5/5 — auth.sessions_revoked_all: audited, notify YES
  # ===========================================================================

  describe "ADR-035 A10 — 5/5: auth.sessions_revoked_all (Settings/Security revoke-all-others)" do
    test "revoking every other session is audited AND notifies the credential owner" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)
      {:ok, _current, current_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, _other, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn(:post, "/settings/security/sessions/revoke_others")
        |> put_session(Auth.session_token_key(), current_raw)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.revoke_others(conn, %{})
      assert conn.status in 300..399

      assert_audited!(result.credential.id, "identity.auth.sessions_revoked_all")
      assert_notified!(user.id, "auth.sessions_revoked_all")
    end
  end

  # ===========================================================================
  # RED (anti-tautology) — the notify-absence assertions are refutable
  # ===========================================================================

  describe "RED (anti-tautology): notify-absence is refutable, not vacuous" do
    test "the SAME credential: logout does NOT notify while a session-revoke on it DOES" do
      result = register!()
      m = mount()
      user = user_for!(result.credential.id)

      # Leg 1: logout — audited, no notify.
      logout_conn = logged_in_conn(m, result.credential.id, "/logout")
      SessionController.delete(logout_conn, %{})
      refute_notified!(user.id, "auth.logout")

      # Leg 2: a DIFFERENT live session gets revoked from a THIRD session —
      # the exact same `assert_notified!/2` query that stayed empty above
      # DOES find a row here, proving leg 1's absence assertion could have
      # failed (it is not vacuously empty by construction of the query).
      {:ok, caller, caller_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, target, _} = SessionCreate.create(session_create_mods(), result.credential.id)
      refute caller.id == target.id

      revoke_conn =
        session_conn(:post, "/settings/security/sessions/#{target.id}/revoke")
        |> put_session(Auth.session_token_key(), caller_raw)
        |> put_private(:samen_mount, m)
        |> put_private(:samen_login_path, "/login")

      SessionController.revoke(revoke_conn, %{"id" => target.id})
      assert_notified!(user.id, "auth.session_revoked")
    end
  end
end
