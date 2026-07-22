defmodule Samen.Web.Auth.TotpTest do
  @moduledoc """
  T07 — A7 TOTP 2FA + vaulted recovery codes (ADR-035 §5 A7), against the
  samen_web test host's Operator Identity mount.

  Proves:

    1. Enrollment (`Samen.Web.Auth.Totp.confirm_enrollment/4`): secret + QR
       provisioning URI generated, confirmed by a valid code, atomically
       persisted (`totp_secret` + `recovery_codes` + `totp_enabled_at`
       together — `Samen.Identity.Totp.enroll/4`).
    2. INV-1: the credential row holds ONLY `vt_*` vault tokens for
       `totp_secret`/`recovery_codes` — never the plaintext secret or codes.
    3. TOTP verify with a drift window (±30s); RED: a code two steps outside
       the window (clock-skew boundary) is rejected.
    4. RED: replaying an already-verified TOTP code within its window fails —
       the SAME code cannot verify twice (anti-replay watermark).
    5. RED: TOTP verify attempted before enrollment completes is refused.
    6. Recovery codes: single-use (a second consume of the SAME code fails,
       a SIBLING code still works); regeneration invalidates the entire old
       set.
    7. Login gate (`Samen.Web.Auth.SessionController`): a credential with 2FA
       enabled is NOT signed in by password alone — RED: no `Identity.Session`
       row is minted, the request detours to `/2fa`; POSITIVE CONTROL: the
       SAME flow for a non-2FA credential mints a session immediately. The
       full `/2fa` round trip (correct code, wrong code + retry, recovery
       code + other-session revocation, replayed pending token) all pair a
       red test with a positive control.
    8. `Samen.Web.Auth.TotpChallengeLive` / `Samen.Web.Auth.TotpEnrollLive`
       render + drive the atomic core through the SAME LiveView lifecycle the
       other A1–A6 auth surfaces are tested with.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  require Ash.Query

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Auth.TotpChallengeLive
  alias Samen.Web.Auth.TotpEnrollLive
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User

  @secret_key_base String.duplicate("a", 64)

  # See session_test.exs / reset_test.exs — set explicitly rather than trust
  # the compiled default (samen_core is a path dep of multiple sibling hosts).
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

  defp register_mods, do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  defp session_create_mods, do: %{session: Session, org: Org, membership: Membership, user: User}
  defp totp_mods, do: %{credential: Credential, repo: Repo}

  defp unique_email, do: "totp-#{System.unique_integer([:positive])}@example.test"

  defp register!(password \\ "correct horse battery staple") do
    attrs = %{
      org_name: "Totp Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result |> Map.put(:email, attrs.email) |> Map.put(:password, password)
  end

  # Enroll 2FA for real (secret -> confirm with a genuinely valid code ->
  # atomic persist), returning the raw secret + the one-time recovery codes
  # so a test can compute further codes / consume codes against them.
  defp enroll!(credential_id) do
    secret = Totp.generate_secret()
    code = NimbleTOTP.verification_code(secret)
    {:ok, _credential, recovery_codes} = Totp.confirm_enrollment(totp_mods(), credential_id, secret, code)
    %{secret: secret, recovery_codes: recovery_codes}
  end

  defp reread_credential(id) do
    Credential
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :totp_enabled_at, :totp_last_verified_at])
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp reread_session(id) do
    Session
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :revoked_at])
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # Same harness `session_test.exs`/`session_controller_test.exs` use for a
  # conn with the session plug installed.
  defp session_conn(method, path) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  defp auth_conn(mount, method \\ :post, path \\ "/login") do
    session_conn(method, path)
    |> put_private(:samen_mount, mount)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  # ===========================================================================
  # 1. Enrollment — QR/secret + confirm-by-code, atomic (no half-enrolled state)
  # ===========================================================================

  describe "Samen.Web.Auth.Totp.confirm_enrollment/4 — enrollment" do
    test "generate_secret/0 + provisioning_uri/3 produce a QR-ready otpauth:// URI" do
      secret = Totp.generate_secret()
      uri = Totp.provisioning_uri(secret, "Samen:someone@example.test", "Samen")

      assert byte_size(secret) == 20
      assert uri =~ "otpauth://totp/"
      assert uri =~ "issuer=Samen"
    end

    test "a valid code confirms enrollment: secret + recovery codes + totp_enabled_at land together" do
      result = register!()
      secret = Totp.generate_secret()
      code = NimbleTOTP.verification_code(secret)

      before = reread_credential(result.credential.id)
      assert is_nil(before.totp_enabled_at)

      assert {:ok, _credential, recovery_codes} = Totp.confirm_enrollment(totp_mods(), result.credential.id, secret, code)
      assert length(recovery_codes) == 10
      assert length(Enum.uniq(recovery_codes)) == 10

      after_ = reread_credential(result.credential.id)
      refute is_nil(after_.totp_enabled_at)
    end

    test "RED: a WRONG code does not enroll — POSITIVE control: retrying with the right code does" do
      result = register!()
      secret = Totp.generate_secret()

      assert {:error, :invalid_code} = Totp.confirm_enrollment(totp_mods(), result.credential.id, secret, "000000")
      assert is_nil(reread_credential(result.credential.id).totp_enabled_at)

      code = NimbleTOTP.verification_code(secret)
      assert {:ok, _, _} = Totp.confirm_enrollment(totp_mods(), result.credential.id, secret, code)
      refute is_nil(reread_credential(result.credential.id).totp_enabled_at)
    end
  end

  # ===========================================================================
  # 2. INV-1 — DB probe: no plaintext at rest
  # ===========================================================================

  describe "INV-1: no plaintext TOTP secret or recovery codes at rest" do
    test "the credential row holds ONLY vt_* vault tokens — never the plaintext secret or codes" do
      result = register!()
      %{secret: secret, recovery_codes: codes} = enroll!(result.credential.id)

      %{rows: [[stored_secret, stored_codes]]} =
        Repo.query!("SELECT pii_woc_totp_secret, pii_woc_recovery_codes FROM woc_credential WHERE woc_id = $1", [
          Ecto.UUID.dump!(result.credential.id)
        ])

      assert to_string(stored_secret) =~ ~r/^vt_[0-9a-f]{32}$/
      assert to_string(stored_codes) =~ ~r/^vt_[0-9a-f]{32}$/

      encoded_secret = Totp.encode_secret(secret)
      refute to_string(stored_secret) =~ encoded_secret
      refute to_string(stored_secret) == inspect(secret)

      for code <- codes do
        refute to_string(stored_codes) =~ code
      end

      # A plain Ash read masks by default too (never plaintext, never a bare token).
      [raw] =
        Credential
        |> Ash.Query.filter(id == ^result.credential.id)
        |> Ash.Query.select([:totp_secret, :recovery_codes])
        |> Ash.read!(authorize?: false)

      assert match?(%Samen.Masked{}, raw.totp_secret)
      assert match?(%Samen.Masked{}, raw.recovery_codes)
    end
  end

  # ===========================================================================
  # 3. Drift window + clock-skew boundary
  # ===========================================================================

  describe "Samen.Web.Auth.Totp.valid_code?/3 — drift window" do
    test "a code from the CURRENT step is valid" do
      secret = Totp.generate_secret()
      now = System.os_time(:second)
      code = NimbleTOTP.verification_code(secret, time: now)

      assert Totp.valid_code?(secret, code, now: now)
    end

    test "a code from ONE step (30s) ago is valid — the drift tolerance" do
      secret = Totp.generate_secret()
      now = System.os_time(:second)
      code = NimbleTOTP.verification_code(secret, time: now - 30)

      assert Totp.valid_code?(secret, code, now: now)
    end

    test "RED: a code from TWO steps (60s) ago is rejected — clock-skew boundary; POSITIVE control: one step ago still passes" do
      secret = Totp.generate_secret()
      now = System.os_time(:second)

      too_old = NimbleTOTP.verification_code(secret, time: now - 60)
      refute Totp.valid_code?(secret, too_old, now: now)

      one_step_old = NimbleTOTP.verification_code(secret, time: now - 30)
      assert Totp.valid_code?(secret, one_step_old, now: now)
    end

    test "RED: a wrong code is rejected — CONTROL: the real current code is accepted" do
      secret = Totp.generate_secret()
      real = NimbleTOTP.verification_code(secret)
      wrong = if real == "000000", do: "111111", else: "000000"

      refute Totp.valid_code?(secret, wrong)
      assert Totp.valid_code?(secret, real)
    end
  end

  # ===========================================================================
  # 4. Anti-replay — a used TOTP code cannot verify twice
  # ===========================================================================

  describe "anti-replay watermark (Samen.Web.Auth.Totp.verify_login_code/3)" do
    test "POSITIVE CONTROL: the current code verifies once" do
      result = register!()
      %{secret: secret} = enroll!(result.credential.id)
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, _} = Totp.verify_login_code(totp_mods(), result.credential.id, code)
      refute is_nil(reread_credential(result.credential.id).totp_last_verified_at)
    end

    test "RED: replaying the SAME code immediately after is rejected" do
      result = register!()
      %{secret: secret} = enroll!(result.credential.id)
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, _} = Totp.verify_login_code(totp_mods(), result.credential.id, code)
      assert {:error, :invalid_code} = Totp.verify_login_code(totp_mods(), result.credential.id, code)
    end

    test "sanity (anti-tautology): a code from a genuinely LATER window still verifies after a prior use" do
      secret = Totp.generate_secret()
      now = System.os_time(:second)
      since = DateTime.utc_now()

      same_window = NimbleTOTP.verification_code(secret, time: now)
      refute Totp.valid_code?(secret, same_window, now: now, since: since)

      later = now + 30
      later_code = NimbleTOTP.verification_code(secret, time: later)
      assert Totp.valid_code?(secret, later_code, now: later, since: since)
    end
  end

  # ===========================================================================
  # 5. Verify attempted before enrollment complete
  # ===========================================================================

  describe "RED: TOTP verify before enrollment is refused" do
    test "verify_login_code/3 on a never-enrolled credential is :not_enrolled — POSITIVE control: after enroll it works" do
      result = register!()

      assert {:error, :not_enrolled} = Totp.verify_login_code(totp_mods(), result.credential.id, "123456")

      %{secret: secret} = enroll!(result.credential.id)
      code = NimbleTOTP.verification_code(secret)
      assert {:ok, _} = Totp.verify_login_code(totp_mods(), result.credential.id, code)
    end

    test "verify_recovery_code/3 on a never-enrolled credential is :not_enrolled" do
      result = register!()
      assert {:error, :not_enrolled} = Totp.verify_recovery_code(totp_mods(), result.credential.id, "AAAA-BBBB")
    end
  end

  # ===========================================================================
  # 6. Recovery codes — single-use + regeneration
  # ===========================================================================

  describe "recovery codes — single-use (Samen.Web.Auth.Totp.verify_recovery_code/3)" do
    test "an unused code is consumed successfully" do
      result = register!()
      %{recovery_codes: [code | _]} = enroll!(result.credential.id)

      assert {:ok, _} = Totp.verify_recovery_code(totp_mods(), result.credential.id, code)
    end

    test "RED: consuming the SAME code twice fails — POSITIVE control: a SIBLING code still works" do
      result = register!()
      %{recovery_codes: [code1, code2 | _]} = enroll!(result.credential.id)

      assert {:ok, _} = Totp.verify_recovery_code(totp_mods(), result.credential.id, code1)
      assert {:error, :invalid_code} = Totp.verify_recovery_code(totp_mods(), result.credential.id, code1)
      assert {:ok, _} = Totp.verify_recovery_code(totp_mods(), result.credential.id, code2)
    end

    test "RED: an unknown/garbage code is rejected — CONTROL: a real code from the set is accepted" do
      result = register!()
      %{recovery_codes: [code | _]} = enroll!(result.credential.id)

      assert {:error, :invalid_code} = Totp.verify_recovery_code(totp_mods(), result.credential.id, "ZZZZ-9999")
      assert {:ok, _} = Totp.verify_recovery_code(totp_mods(), result.credential.id, code)
    end
  end

  describe "recovery codes — regeneration invalidates the ENTIRE old set" do
    test "an old code fails after regeneration; a new code succeeds" do
      result = register!()
      %{recovery_codes: old_codes} = enroll!(result.credential.id)

      assert {:ok, _, new_codes} = Totp.regenerate_recovery_codes(totp_mods(), result.credential.id)
      refute Enum.any?(old_codes, &(&1 in new_codes))

      [old_code | _] = old_codes
      assert {:error, :invalid_code} = Totp.verify_recovery_code(totp_mods(), result.credential.id, old_code)

      [new_code | _] = new_codes
      assert {:ok, _} = Totp.verify_recovery_code(totp_mods(), result.credential.id, new_code)
    end
  end

  # ===========================================================================
  # 7. Login gate — 2FA enabled requires a second factor
  # ===========================================================================

  describe "Samen.Web.Auth.SessionController.create/2 — the 2FA gate" do
    test "RED: password alone does NOT mint a session for a 2FA-enabled credential — detours to /2fa" do
      result = register!()
      enroll!(result.credential.id)
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      before = Ash.count!(Session, authorize?: false)

      conn =
        SessionController.create(
          auth_conn(mount),
          %{"login" => %{"email" => result.email, "password" => result.password}}
        )

      assert conn |> get_resp_header("location") |> List.first() == "/2fa"
      assert Ash.count!(Session, authorize?: false) == before
      assert is_binary(get_session(conn, Auth.totp_pending_key()))
    end

    test "POSITIVE CONTROL: the SAME credential WITHOUT 2FA mints a session immediately" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      before = Ash.count!(Session, authorize?: false)

      conn =
        SessionController.create(
          auth_conn(mount),
          %{"login" => %{"email" => result.email, "password" => result.password}}
        )

      refute conn |> get_resp_header("location") |> List.first() == "/2fa"
      assert Ash.count!(Session, authorize?: false) == before + 1
      assert is_binary(get_session(conn, Auth.session_token_key()))
    end
  end

  describe "Samen.Web.Auth.SessionController.verify_totp/2 — the /2fa round trip" do
    defp start_challenge(mount, result) do
      conn = SessionController.create(auth_conn(mount), %{"login" => %{"email" => result.email, "password" => result.password}})
      get_session(conn, Auth.totp_pending_key())
    end

    defp totp_conn(mount, pending_raw) do
      session_conn(:post, "/2fa")
      |> put_session(Auth.totp_pending_key(), pending_raw)
      |> put_private(:samen_mount, mount)
      |> put_private(:samen_login_path, "/login")
      |> put_private(:samen_totp_path, "/2fa")
    end

    test "the CORRECT code mints the session, clears the pending token" do
      result = register!()
      %{secret: secret} = enroll!(result.credential.id)
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)

      pending_raw = start_challenge(mount, result)
      refute is_nil(pending_raw)

      code = NimbleTOTP.verification_code(secret)
      conn = SessionController.verify_totp(totp_conn(mount, pending_raw), %{"code" => code})

      assert conn.status in 300..399
      raw_session_token = get_session(conn, Auth.session_token_key())
      assert is_binary(raw_session_token)

      assert {:ok, %{credential_id: credential_id}} =
               Auth.resolve_principal(%{Auth.session_token_key() => raw_session_token}, %{session: Session})

      assert credential_id == result.credential.id
      assert get_session(conn, Auth.totp_pending_key()) == nil
    end

    test "RED: a WRONG code mints no session AND does not burn the pending token — POSITIVE control: retry with the right code works" do
      result = register!()
      %{secret: secret} = enroll!(result.credential.id)
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      before = Ash.count!(Session, authorize?: false)

      pending_raw = start_challenge(mount, result)

      wrong_conn = SessionController.verify_totp(totp_conn(mount, pending_raw), %{"code" => "000000"})
      assert wrong_conn |> get_resp_header("location") |> List.first() == "/2fa?error=1"
      assert Ash.count!(Session, authorize?: false) == before

      code = NimbleTOTP.verification_code(secret)
      retry_conn = SessionController.verify_totp(totp_conn(mount, pending_raw), %{"code" => code})
      assert retry_conn.status in 300..399
      assert Ash.count!(Session, authorize?: false) == before + 1
    end

    test "RED: no pending token at all is refused, mints no session" do
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      before = Ash.count!(Session, authorize?: false)

      conn = SessionController.verify_totp(auth_conn(mount, :post, "/2fa"), %{"code" => "123456"})

      assert conn |> get_resp_header("location") |> List.first() == "/2fa?error=1"
      assert Ash.count!(Session, authorize?: false) == before
    end

    test "RED: reusing an ALREADY-CONSUMED pending token mints no second session" do
      result = register!()
      %{secret: secret} = enroll!(result.credential.id)
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)

      pending_raw = start_challenge(mount, result)
      code = NimbleTOTP.verification_code(secret)

      first = SessionController.verify_totp(totp_conn(mount, pending_raw), %{"code" => code})
      assert first.status in 300..399
      before = Ash.count!(Session, authorize?: false)

      second = SessionController.verify_totp(totp_conn(mount, pending_raw), %{"code" => code})
      assert second |> get_resp_header("location") |> List.first() == "/2fa?error=1"
      assert Ash.count!(Session, authorize?: false) == before
    end

    test "a recovery code completes login AND revokes every OTHER live session (c3)" do
      result = register!()
      %{recovery_codes: [recovery_code | _]} = enroll!(result.credential.id)
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)

      {:ok, other_session, _raw} =
        SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Other device")

      pending_raw = start_challenge(mount, result)
      conn = SessionController.verify_totp(totp_conn(mount, pending_raw), %{"code" => recovery_code})

      assert conn.status in 300..399
      assert is_binary(get_session(conn, Auth.session_token_key()))

      row = reread_session(other_session.id)
      refute is_nil(row.revoked_at)
    end
  end

  # ===========================================================================
  # 8. Samen.Web.Auth.TotpChallengeLive
  # ===========================================================================

  describe "Samen.Web.Auth.TotpChallengeLive" do
    test "renders the code-entry form" do
      mount = build_mount(:auth)
      html = mount_smoke(TotpChallengeLive, mount)

      assert html =~ "Two-factor verification"
      assert html =~ "totp-form"
      assert html =~ "totp-submit"
    end

    test "with no pending token, pending? is false and the notice renders" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = TotpChallengeLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      assert socket.assigns.pending? == false
    end

    test "with a pending token present, pending? is true" do
      mount = build_mount(:auth)
      session = mount_session(mount) |> Map.put(Auth.totp_pending_key(), "some-raw-token")
      {:ok, socket} = TotpChallengeLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      assert socket.assigns.pending? == true
    end

    test "submitting arms phx-trigger-action — the LiveView never verifies the code itself" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = TotpChallengeLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket} = TotpChallengeLive.handle_event("verify", %{"totp" => %{"code" => "123456"}}, socket)
      assert socket.assigns.trigger_submit == true
    end
  end

  # ===========================================================================
  # 9. Samen.Web.Auth.TotpEnrollLive
  # ===========================================================================

  describe "Samen.Web.Auth.TotpEnrollLive" do
    test "mount generates a fresh secret + provisioning URI, not yet enrolled" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = TotpEnrollLive.mount(%{"credential_id" => Ash.UUID.generate()}, session, %Phoenix.LiveView.Socket{})

      refute socket.assigns.enrolled?
      assert is_binary(socket.assigns.raw_secret)
      assert socket.assigns.provisioning_uri =~ "otpauth://totp/"
    end

    test "confirming with the CORRECT code enrolls and shows recovery codes once" do
      result = register!()
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = TotpEnrollLive.mount(%{"credential_id" => result.credential.id}, session, %Phoenix.LiveView.Socket{})

      code = NimbleTOTP.verification_code(socket.assigns.raw_secret)
      {:noreply, socket} = TotpEnrollLive.handle_event("confirm", %{"totp_enroll" => %{"code" => code}}, socket)

      assert socket.assigns.enrolled?
      assert length(socket.assigns.recovery_codes) == 10
      refute is_nil(reread_credential(result.credential.id).totp_enabled_at)
    end

    test "RED: a WRONG code does not enroll — POSITIVE control: retry with the right code does" do
      result = register!()
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = TotpEnrollLive.mount(%{"credential_id" => result.credential.id}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket} = TotpEnrollLive.handle_event("confirm", %{"totp_enroll" => %{"code" => "000000"}}, socket)
      refute socket.assigns.enrolled?
      assert is_nil(reread_credential(result.credential.id).totp_enabled_at)

      code = NimbleTOTP.verification_code(socket.assigns.raw_secret)
      {:noreply, socket} = TotpEnrollLive.handle_event("confirm", %{"totp_enroll" => %{"code" => code}}, socket)
      assert socket.assigns.enrolled?
    end

    test "disable clears enrollment" do
      result = register!()
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = TotpEnrollLive.mount(%{"credential_id" => result.credential.id}, session, %Phoenix.LiveView.Socket{})

      code = NimbleTOTP.verification_code(socket.assigns.raw_secret)
      {:noreply, socket} = TotpEnrollLive.handle_event("confirm", %{"totp_enroll" => %{"code" => code}}, socket)
      assert socket.assigns.enrolled?

      {:noreply, socket} = TotpEnrollLive.handle_event("disable", %{}, socket)
      refute socket.assigns.enrolled?
      assert is_nil(reread_credential(result.credential.id).totp_enabled_at)
    end
  end
end
