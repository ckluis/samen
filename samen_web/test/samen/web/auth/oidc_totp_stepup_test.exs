defmodule Samen.Web.Auth.OidcTotpStepUpTest do
  @moduledoc """
  T100 — A6+A7 interaction (ADR-035 §5 A6+A7, §10 addendum): the FEDERATED
  (OIDC) login of a credential whose `totp_enabled_at` is set MUST detour
  through the SAME `/2fa` interstitial the password login uses, minting NO
  `Identity.Session` until the second factor verifies. Closes the gap T07's
  verifier surfaced: `OidcController` minted a full session with no TOTP check,
  so an attacker who compromised the linked IdP account could skip 2FA.

  Proves (against the samen_web test host's Operator Identity mount, with a
  STUBBED IdP — no live Google, no HTTP):

    1. RED: OIDC callback for a TOTP-enrolled credential WITHOUT the second
       factor mints ZERO Session rows and lands on `/2fa` with a `:totp_pending`
       token that authenticates NOBODY (resolves against AuthToken, not Session).
    2. POSITIVE CONTROL: the SAME credential completing `/2fa` after the callback
       gets exactly ONE session via the shared `finish_login` (the sole mint).
    3. UNCHANGED CONTROL: a credential WITHOUT `totp_enabled_at` logs in via OIDC
       exactly as before — one session minted directly, no detour.
    4. Mechanism reuse: the OIDC-originated detour uses the SAME
       `samen_totp_pending_token` / `verify_totp` / `finish_login` path — a wrong
       code and a replayed pending token both fail closed (the T07 red pattern
       holds on this origin too), and the OidcController routes TOTP-enrolled
       credentials through the shared step-up, never a direct `SessionCreate`.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Identity.OidcLink
  alias Samen.Web.Auth
  alias Samen.Web.Auth.OidcController
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User
  alias Samen.WebTest.Operator.UserIdentity

  @secret_key_base String.duplicate("a", 64)
  @session_params_key "samen_oidc_session_params"

  # A deterministic stub IdP strategy (assent's `authorize_url/1` + `callback/2`
  # shape) — the SAME stub oidc_test.exs uses, so the controller flow runs with
  # no live Google and no HTTP.
  defmodule OidcStubStrategy do
    def authorize_url(config) do
      state = config[:test_state] || "stub-state"

      {:ok,
       %{
         url: "https://accounts.google.test/o/oauth2/auth?state=#{state}",
         session_params: %{state: state, nonce: "stub-nonce"}
       }}
    end

    def callback(config, _params) do
      {:ok, %{user: config[:test_claims] || %{}}}
    end
  end

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  # -- mods / fixtures ---------------------------------------------------------

  defp link_mods,
    do: %{
      org: Org,
      credential: Credential,
      user: User,
      membership: Membership,
      user_identity: UserIdentity,
      repo: Repo
    }

  defp totp_mods, do: %{credential: Credential, repo: Repo}

  defp unique_email, do: "oidc-totp-#{System.unique_integer([:positive])}@example.test"
  defp unique_uid, do: "google-sub-#{System.unique_integer([:positive])}"

  defp claims(email, uid) do
    %{
      provider: "google",
      provider_uid: uid,
      email: email,
      first_name: "Ada",
      last_name: "Lovelace",
      email_verified: true
    }
  end

  defp stringify_claims(%{} = c) do
    %{
      "sub" => c.provider_uid,
      "email" => c.email,
      "given_name" => c[:first_name],
      "family_name" => c[:last_name],
      "email_verified" => c[:email_verified]
    }
  end

  defp stub_config(claims, state) do
    %{
      providers: %{
        google: [
          strategy: OidcStubStrategy,
          client_id: "test-client",
          client_secret: "test-secret",
          redirect_uri: "https://app.test/auth/oidc/google/callback",
          strategy_opts: [test_claims: stringify_claims(claims), test_state: state]
        ]
      }
    }
  end

  # Provision an SSO credential (org + passwordless credential + user + owner
  # membership + the UserIdentity link) for `claims`, returning its id.
  defp provision!(claims) do
    {:ok, %{credential_id: cid}} = OidcLink.link_or_provision(claims, link_mods(), signup: true)
    cid
  end

  # Enroll 2FA for real (secret -> confirm with a genuinely valid code -> atomic
  # persist), returning the raw secret so a test can compute further codes.
  defp enroll_totp!(credential_id) do
    secret = Totp.generate_secret()
    code = NimbleTOTP.verification_code(secret)
    {:ok, _credential, _recovery} = Totp.confirm_enrollment(totp_mods(), credential_id, secret, code)
    secret
  end

  # -- conns -------------------------------------------------------------------

  defp session_conn(method, path) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  # The callback conn: the OIDC session-params already stashed (as `request/2`
  # would have), plus the controller's `private` seam (mount + provider config +
  # login/totp paths).
  defp callback_conn(mount, config, state) do
    session_conn(:get, "/auth/oidc/google/callback")
    |> put_session(@session_params_key, %{"state" => state, "nonce" => "stub-nonce"})
    |> put_private(:samen_mount, mount)
    |> put_private(:samen_oidc_config, config)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  defp run_callback(mount, config, state) do
    OidcController.callback(
      callback_conn(mount, config, state),
      %{"provider" => "google", "state" => state, "code" => "abc"}
    )
  end

  # The /2fa conn: the SAME shape totp_test.exs uses — the pending token in the
  # signed session, the controller's private seam set.
  defp totp_conn(mount, pending_raw) do
    session_conn(:post, "/2fa")
    |> put_session(Auth.totp_pending_key(), pending_raw)
    |> put_private(:samen_mount, mount)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  defp mount, do: Mount.new(:auth, Samen.WebTest.Operator, Repo)

  # ===========================================================================
  # 1. RED — a TOTP-enrolled credential is NOT signed in by the federated flow
  # ===========================================================================

  describe "OIDC login honors TOTP step-up (ADR-035 §5 A6+A7)" do
    test "RED: an OIDC callback for a TOTP-enrolled credential mints NO session and detours to /2fa" do
      c = claims(unique_email(), unique_uid())
      cid = provision!(c)
      _secret = enroll_totp!(cid)

      state = "state-#{System.unique_integer([:positive])}"
      before = Ash.count!(Session, authorize?: false)

      conn = run_callback(mount(), stub_config(c, state), state)

      # No Identity.Session row minted on the federated leg.
      assert Ash.count!(Session, authorize?: false) == before

      # Detour to the SAME interstitial the password path uses.
      assert conn |> get_resp_header("location") |> List.first() == "/2fa"

      # A :totp_pending token exists; the authenticated-principal key does NOT.
      pending = get_session(conn, Auth.totp_pending_key())
      assert is_binary(pending)
      assert is_nil(get_session(conn, Auth.session_token_key()))

      # Fail-closed: even if the pending token were coerced into the session-token
      # slot, it authenticates NOBODY (it resolves against AuthToken, not Session).
      assert :error ==
               Auth.resolve_principal(%{Auth.session_token_key() => pending}, %{session: Session})
    end

    test "POSITIVE CONTROL: presenting the second factor after the detour mints exactly ONE session via finish_login" do
      c = claims(unique_email(), unique_uid())
      cid = provision!(c)
      secret = enroll_totp!(cid)
      m = mount()

      # The federated leg detours (no session yet)…
      state = "state-#{System.unique_integer([:positive])}"
      detour = run_callback(m, stub_config(c, state), state)
      pending = get_session(detour, Auth.totp_pending_key())
      assert is_binary(pending)

      # …then /2fa verifies and performs the sole Session mint.
      before = Ash.count!(Session, authorize?: false)
      code = NimbleTOTP.verification_code(secret)
      conn = SessionController.verify_totp(totp_conn(m, pending), %{"code" => code})

      assert conn.status in 300..399
      assert Ash.count!(Session, authorize?: false) == before + 1

      raw = get_session(conn, Auth.session_token_key())
      assert is_binary(raw)

      assert {:ok, %{credential_id: resolved}} =
               Auth.resolve_principal(%{Auth.session_token_key() => raw}, %{session: Session})

      assert resolved == cid
      assert get_session(conn, Auth.totp_pending_key()) == nil
    end

    test "UNCHANGED CONTROL: a credential WITHOUT totp_enabled_at logs in via OIDC, minting a session directly" do
      c = claims(unique_email(), unique_uid())
      _cid = provision!(c)

      state = "state-#{System.unique_integer([:positive])}"
      before = Ash.count!(Session, authorize?: false)

      conn = run_callback(mount(), stub_config(c, state), state)

      # One session minted directly (the pre-T100 path) — no /2fa detour.
      assert Ash.count!(Session, authorize?: false) == before + 1
      assert conn |> get_resp_header("location") |> List.first() == "/"
      assert is_binary(get_session(conn, Auth.session_token_key()))
      assert is_nil(get_session(conn, Auth.totp_pending_key()))
    end
  end

  # ===========================================================================
  # 2. Mechanism reuse — the T07 red pattern holds on the OIDC-originated detour
  # ===========================================================================

  describe "the OIDC detour reuses the shared :totp_pending mechanism" do
    test "RED: a WRONG code mints no session and does not burn the pending token — CONTROL: retry works" do
      c = claims(unique_email(), unique_uid())
      cid = provision!(c)
      secret = enroll_totp!(cid)
      m = mount()

      state = "state-#{System.unique_integer([:positive])}"
      detour = run_callback(m, stub_config(c, state), state)
      pending = get_session(detour, Auth.totp_pending_key())

      before = Ash.count!(Session, authorize?: false)

      wrong = SessionController.verify_totp(totp_conn(m, pending), %{"code" => "000000"})
      assert wrong |> get_resp_header("location") |> List.first() == "/2fa?error=1"
      assert Ash.count!(Session, authorize?: false) == before

      # The pending token was NOT burned — a retry with the right code succeeds.
      code = NimbleTOTP.verification_code(secret)
      retry = SessionController.verify_totp(totp_conn(m, pending), %{"code" => code})
      assert retry.status in 300..399
      assert Ash.count!(Session, authorize?: false) == before + 1
    end

    test "RED: replaying an ALREADY-CONSUMED pending token from an OIDC detour mints no second session" do
      c = claims(unique_email(), unique_uid())
      cid = provision!(c)
      secret = enroll_totp!(cid)
      m = mount()

      state = "state-#{System.unique_integer([:positive])}"
      detour = run_callback(m, stub_config(c, state), state)
      pending = get_session(detour, Auth.totp_pending_key())

      code = NimbleTOTP.verification_code(secret)
      first = SessionController.verify_totp(totp_conn(m, pending), %{"code" => code})
      assert first.status in 300..399

      before = Ash.count!(Session, authorize?: false)

      second = SessionController.verify_totp(totp_conn(m, pending), %{"code" => code})
      assert second |> get_resp_header("location") |> List.first() == "/2fa?error=1"
      assert Ash.count!(Session, authorize?: false) == before
    end

    test "module probe: the OIDC path routes TOTP-enrolled credentials through the shared step-up, no parallel mechanism" do
      src = File.read!("lib/samen/web/auth/oidc_controller.ex")

      # The account-property fork is the shared step-up seam, not a direct mint.
      assert src =~ "TotpStepUp.enrolled?"
      assert src =~ "TotpStepUp.challenge"

      # No parallel pending-token context and no second interstitial were introduced.
      refute src =~ ":oidc_totp_pending"
      refute src =~ "OidcTotpChallenge"

      # The shared module mints the SAME :totp_pending context both entrypoints use.
      stepup = File.read!("lib/samen/web/auth/totp_step_up.ex")
      assert stepup =~ ":totp_pending"
    end
  end
end
