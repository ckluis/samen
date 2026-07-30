defmodule Samen.Web.Auth.RateLimitTest do
  @moduledoc """
  T103 — auth-surface rate limiting + non-PII key discipline (ADR-035 §4.5,
  ADR-037 §5.14, ADR-038 §6). Wires the ADOPTED-but-unwired limiter onto the four
  internet-facing auth surfaces via the ONE shared `Samen.Web.RateLimit` seam
  (never a parallel mechanism — the SAME seam T19's webhook ingress uses).

  Proves, against the samen_web test host's Operator Identity mount:

    1. RED per surface (table-driven, 4 rows): exceeding the configured limit on
       sign-in / registration / reset-request / 2FA-verify is REFUSED (429 or
       interstitial per §4.5), while the under-limit positive control succeeds.
    2. Both key axes INDEPENDENT (ADR-038 §6.3): an IP-rotating attacker is still
       limited per-account (`email_bidx`); an account-rotating attacker is still
       limited per-IP.
    3. Keys are non-PII (INV-1, ADR-038 §6.2): no plaintext email appears in any
       limiter bucket key at runtime; the sign-in account bucket is keyed on the
       `email_bidx` HMAC (grep + runtime inspection).
    4. Timing parity preserved (ADR-035 §4.4): the limit check is CONSTANT-SHAPE —
       a known vs unknown account get the identical outcome and both bump their
       own bucket, so the check adds no enumeration oracle.
    5. Deterministic backend, no sleeps: limits are injected via config and the
       counters reset per test; the Hammer fixed-window count is asserted within a
       single window (this file contains no `Process.sleep`).
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Auth.BlindIndex
  alias Samen.AuditEvent
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.AccountController
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Auth.Totp
  alias Samen.Web.Mount
  alias Samen.Web.RateLimit
  alias Samen.Web.RateLimit.Backend
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  @secret_key_base String.duplicate("a", 64)

  # Low, deterministic per-surface limits (the whole point of a config-tunable seam):
  # tiny numbers so a red-path trips in a handful of in-window hits — no sleeps.
  @limits %{
    signin_account: {3, 60_000},
    signin_ip: {5, 3_600_000},
    registration_ip: {2, 3_600_000},
    token_request_account: {2, 900_000},
    totp_verify_credential: {2, 60_000}
  }

  setup do
    prev = Application.get_env(:samen_web, RateLimit)
    Application.put_env(:samen_web, RateLimit, limits: @limits)
    RateLimit.reset()

    # Reset.request/2 dispatches through the Delivery chokepoint; pin the test env
    # (the house convention — see session_test.exs / reset_test.exs).
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_web, RateLimit, prev),
        else: Application.delete_env(:samen_web, RateLimit)

      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)

      RateLimit.reset()
    end)

    :ok
  end

  # ===========================================================================
  # 1. RED per surface — table-driven (4 rows), each with an under-limit control
  # ===========================================================================

  describe "each auth surface is rate-limited (ADR-035 §4.5 / ADR-038 §6.3)" do
    test "table-driven RED: exceeding the limit is refused; the under-limit control succeeds" do
      m = mount()

      # A known account for sign-in; a fixed email for reset-request (per-account
      # keyed — must stay fixed so the same bucket accumulates); an armed 2FA
      # interstitial. Each surface keys on a DISTINCT bucket, so the rows do not
      # cross-contaminate within this single (reset) window.
      known = register!()
      reset_email = unique_email()
      {totp_mount, pending} = arm_totp_pending!()

      surfaces = [
        {"sign-in (per-account #{elem(@limits.signin_account, 0)}/win)", elem(@limits.signin_account, 0),
         fn -> login_outcome(m, known.email, "wrong-password", {192, 0, 2, 1}) end},
        {"registration (per-IP #{elem(@limits.registration_ip, 0)}/win)", elem(@limits.registration_ip, 0),
         fn -> registration_outcome() end},
        {"reset-request (per-account #{elem(@limits.token_request_account, 0)}/win)",
         elem(@limits.token_request_account, 0), fn -> reset_request_outcome(reset_email) end},
        {"2FA-verify (per-credential #{elem(@limits.totp_verify_credential, 0)}/win)",
         elem(@limits.totp_verify_credential, 0), fn -> totp_verify_outcome(totp_mount, pending) end}
      ]

      for {label, limit, attempt} <- surfaces do
        # Positive control: every under-limit attempt is allowed.
        for n <- 1..limit do
          assert attempt.() == :allowed,
                 "#{label}: attempt #{n} (<= limit) should be ALLOWED"
        end

        # RED: the next attempt (limit + 1) is refused.
        assert attempt.() == :refused,
               "#{label}: attempt #{limit + 1} (> limit) must be REFUSED"
      end
    end
  end

  # ===========================================================================
  # 2. Both key axes are INDEPENDENT (ADR-038 §6.3)
  # ===========================================================================

  describe "per-IP AND per-account keys, proven independently" do
    test "an IP-ROTATING attacker on one account is still limited PER-ACCOUNT" do
      m = mount()
      acct = register!()
      {limit, _} = @limits.signin_account

      # Each attempt from a FRESH IP (so the per-IP axis never trips), same account.
      for i <- 1..limit do
        assert login_outcome(m, acct.email, "wrong", {10, 0, 0, i}) == :allowed
      end

      # A brand-new IP does NOT rescue the attacker — the per-account bucket is over.
      assert login_outcome(m, acct.email, "wrong", {10, 0, 0, 250}) == :refused

      # Positive control: a DIFFERENT account from a fresh IP is NOT limited.
      other = register!()
      assert login_outcome(m, other.email, "wrong", {10, 0, 0, 251}) == :allowed
    end

    test "an ACCOUNT-ROTATING attacker from one IP is still limited PER-IP" do
      m = mount()
      {limit, _} = @limits.signin_ip
      ip = {172, 16, 0, 1}

      # Each attempt a DIFFERENT (unknown) account (so no per-account bucket trips),
      # same IP.
      for _ <- 1..limit do
        assert login_outcome(m, unique_email(), "wrong", ip) == :allowed
      end

      # A brand-new account does NOT rescue the attacker — the per-IP bucket is over.
      assert login_outcome(m, unique_email(), "wrong", ip) == :refused

      # Positive control: the same fresh account from a DIFFERENT IP is NOT limited.
      assert login_outcome(m, unique_email(), "wrong", {172, 16, 0, 2}) == :allowed
    end
  end

  # ===========================================================================
  # 3. Keys are non-PII / bidx (INV-1, ADR-038 §6.2)
  # ===========================================================================

  describe "limiter keys carry no plaintext PII" do
    test "no plaintext email in any bucket key; the account bucket is keyed on email_bidx (grep + runtime)" do
      m = mount()
      acct = register!()

      _ = login_outcome(m, acct.email, "wrong", {203, 0, 113, 7})

      dump = inspect(:ets.tab2list(Backend), limit: :infinity)

      # RUNTIME: the plaintext email appears in NO limiter bucket key.
      refute dump =~ acct.email,
             "a plaintext email must never appear in a limiter bucket key"

      # RUNTIME positive: the sign-in account bucket IS present AND keyed on the
      # non-reversible email_bidx HMAC (proves it is genuinely keyed, on the bidx).
      {:ok, bidx} = BlindIndex.compute(acct.email)
      assert dump =~ "signin_account:email_bidx:#{bidx}"

      # GREP: the surface wires the bidx (never the raw email) into the account key.
      src = File.read!("lib/samen/web/auth/session_controller.ex")
      assert src =~ "RateLimit.check(:signin_account, :email_bidx, bidx)"
      refute src =~ ":signin_account, :email,"
    end
  end

  # ===========================================================================
  # 4. Timing parity — the limit check is constant-shape (ADR-035 §4.4)
  # ===========================================================================

  describe "the rate-limit check introduces no enumeration oracle" do
    test "a known and an unknown account get the identical outcome and both bump their bucket" do
      m = mount()
      known = register!()
      unknown = unique_email()

      c_known = do_login(m, known.email, "wrong", {198, 51, 100, 1})
      c_unknown = do_login(m, unknown, "wrong", {198, 51, 100, 2})

      # SAME generic outcome — no differential a probe could read.
      assert location(c_known) == "/login?error=1"
      assert location(c_unknown) == "/login?error=1"
      assert c_known.status == c_unknown.status

      # The check ran IDENTICALLY for both: each produced a signin_account bucket
      # keyed on its own bidx (constant-shape — an unknown email is not a fast path).
      {:ok, kb} = BlindIndex.compute(known.email)
      {:ok, ub} = BlindIndex.compute(unknown)
      dump = inspect(:ets.tab2list(Backend), limit: :infinity)
      assert dump =~ kb
      assert dump =~ ub
    end
  end

  # ===========================================================================
  # 4b. Bounded auth.login_failed audit (ADR-035 §5 taxonomy / ADR-038 §6.4)
  # ===========================================================================

  describe "auth.login_failed audit is BOUNDED under brute force" do
    test "N >> limit failed attempts produce O(window) edge rows, not O(N) — but the counter tracks the burst" do
      # High sign-in limits so every failed attempt REACHES the audit path (isolating
      # the audit-bounding from the rate-limit gate — otherwise 429s would also bound it).
      Application.put_env(:samen_web, RateLimit,
        limits: Map.merge(@limits, %{signin_account: {10_000, 60_000}, signin_ip: {10_000, 3_600_000}})
      )

      RateLimit.reset()

      m = mount()
      acct = register!()
      n = 15

      for _ <- 1..n do
        assert do_login(m, acct.email, "wrong", {192, 0, 2, 50}).status in 300..399
      end

      rows = AuditEvent.for_subject(Repo, acct.credential.id)
      login_failed = Enum.filter(rows, &(&1.detail == "identity.auth.login_failed"))

      # BOUNDED: a single window-edge row for #{n} attempts (not N unbounded rows) —
      # and NOT zero (the edge genuinely fired: T101 findability preserved).
      assert length(login_failed) == 1,
             "expected 1 bounded edge row for #{n} failed attempts, got #{length(login_failed)}"

      # Anti-tautology: the bidx-keyed failure counter DID track the burst (the single
      # audit row is an edge-gate, not a counter frozen at one).
      {:ok, bidx} = BlindIndex.compute(acct.email)
      dump = inspect(:ets.tab2list(Backend), limit: :infinity)
      assert dump =~ "login_failed_audit:email_bidx:#{bidx}"
      # the plaintext email is STILL absent from the failure-counter key (INV-1)
      refute dump =~ acct.email
    end
  end

  # ===========================================================================
  # 5. Shape probe — INV-4 dep topology (deps in samen_web only, absent from core)
  # ===========================================================================

  describe "INV-4 dependency topology" do
    test "ash_rate_limiter + hammer are declared in samen_web ONLY, and no resource-level DSL is used" do
      web = File.read!("mix.exs")
      assert web =~ "ash_rate_limiter"
      assert web =~ "hammer"

      core = File.read!("../samen_core/mix.exs")
      refute core =~ "ash_rate_limiter"
      refute core =~ "hammer"

      # The resource-level `rate_limit` DSL is deliberately NOT used (it would compile
      # into core resources); enforcement is the manual-plug seam only.
      refute File.read!("lib/samen/web/rate_limit.ex") =~ "use AshRateLimiter"
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp mount, do: Mount.new(:auth, Samen.WebTest.Operator, Repo)

  defp unique_email, do: "rl-#{System.unique_integer([:positive])}@example.test"

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp register!(email \\ nil) do
    email = email || unique_email()

    attrs = %{
      org_name: "RL Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: email,
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())

    result
    |> Map.put(:email, email)
    |> Map.put(:password, "correct horse battery staple")
  end

  # -- sign-in (controller) ----------------------------------------------------

  defp session_conn(method, path) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  defp login_conn(mount, ip) do
    session_conn(:post, "/login")
    |> Map.put(:remote_ip, ip)
    |> put_private(:samen_mount, mount)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  defp do_login(mount, email, password, ip) do
    SessionController.create(login_conn(mount, ip), %{"login" => %{"email" => email, "password" => password}})
  end

  # `:allowed` = the request was processed (wrong-password redirect back to login);
  # `:refused` = the limiter returned a 429 before processing.
  defp login_outcome(mount, email, password, ip) do
    conn = do_login(mount, email, password, ip)
    outcome(conn)
  end

  defp outcome(%{status: 429}), do: :refused
  defp outcome(%{status: status}) when status in 300..399, do: :allowed

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # -- 2FA-verify (controller) -------------------------------------------------

  # Register, enroll REAL 2FA, then sign in once (which detours to /2fa and arms the
  # shared :totp_pending token). Returns the mount + the pending raw token so the test
  # can hammer /2fa with wrong codes.
  defp arm_totp_pending! do
    m = mount()
    reg = register!()
    _secret = enroll_totp!(reg.credential.id)

    detour = do_login(m, reg.email, reg.password, {10, 0, 0, 9})
    pending = get_session(detour, Auth.totp_pending_key())
    assert is_binary(pending)
    {m, pending}
  end

  defp enroll_totp!(credential_id) do
    secret = Totp.generate_secret()
    code = NimbleTOTP.verification_code(secret)
    {:ok, _credential, _recovery} = Totp.confirm_enrollment(%{credential: Credential, repo: Repo}, credential_id, secret, code)
    secret
  end

  defp totp_conn(mount, pending) do
    session_conn(:post, "/2fa")
    |> put_session(Auth.totp_pending_key(), pending)
    |> put_private(:samen_mount, mount)
    |> put_private(:samen_login_path, "/login")
    |> put_private(:samen_totp_path, "/2fa")
  end

  # A WRONG code never consumes the pending token, so the same interstitial can be
  # replayed: under limit → /2fa?error=1 (302); over limit → 429.
  defp totp_verify_outcome(mount, pending) do
    conn = SessionController.verify_totp(totp_conn(mount, pending), %{"code" => "000000"})
    outcome(conn)
  end

  # -- registration (controller — T110: the rate limit moved to the
  # no-JS POST fallback, the authoritative enforcement point a no-JS submit
  # hits; the LiveView's `handle_event` no longer enforces) --------------------

  # A FIXED per-IP source so every attempt in one table row accumulates the same
  # `:registration_ip` bucket (registration keys per-IP, not per-account).
  @registration_ip {198, 51, 100, 7}

  defp registration_conn do
    session_conn(:post, "/signup")
    |> Map.put(:remote_ip, @registration_ip)
    |> put_private(:samen_mount, mount())
    |> put_private(:samen_signup_path, "/signup")
  end

  defp registration_outcome do
    params = %{
      "org_name" => "RL #{System.unique_integer([:positive])}",
      "first_name" => "Ada",
      "last_name" => "Lovelace",
      "email" => unique_email(),
      "password" => "correct horse battery staple"
    }

    conn = AccountController.register(registration_conn(), %{"registration" => params})
    if location(conn) =~ "error=rate_limited", do: :refused, else: :allowed
  end

  # -- reset-request (controller) ----------------------------------------------

  defp reset_request_conn do
    session_conn(:post, "/reset")
    |> put_private(:samen_mount, mount())
    |> put_private(:samen_reset_path, "/reset")
  end

  defp reset_request_outcome(email) do
    conn = AccountController.request_reset(reset_request_conn(), %{"reset" => %{"email" => email}})
    # Uniform no-oracle redirect either way; the limiter is observable via the
    # `?throttled=1` flag (keyed on the supplied email — no existence signal).
    if location(conn) =~ "throttled", do: :refused, else: :allowed
  end
end
