defmodule Samen.Web.Auth.LoginFailureDurableTest do
  @moduledoc """
  T109 — ADR-038 §6.4: the DURABLE `Identity.LoginFailure` brute-force counter,
  closing T103's named mechanism gap (the count was ETS-ephemeral, reset on
  restart; `_orch/verify/T103-verdict.json` `mechanism_deviation_ruling`).

  Proves, against the samen_web test host's Operator Identity mount:

    1. Accumulate/reset: `bump!/4` accumulates under concurrent-shaped repeated
       calls; `reset!/3` clears exactly the targeted key (paired positive
       control: an unrelated key is unaffected either way) — the RED/positive-
       control discipline `Samen.RedPath`'s moduledoc mandates, hand-written
       here (like the sibling org-less/default-deny resources Credential/
       Session/AuthToken/UserIdentity, `Samen.RedPath`'s POLICY-matrix macros
       assume org-scoped PII resources and do not fit this org-less,
       PII-free, always-`forbid_if`-policy counter).
    2. Window-expiry reset: an expired window resets to 1 instead of
       incrementing (deterministic — no sleeps, the row's clock is backdated
       instead, mirroring `rate_limit_test.exs`'s no-sleep discipline).
    3. `over_limit?/5` — the restart-survival enforcement primitive.
    4. Restart survival through the REAL sign-in controller path: accumulated
       failures survive an ETS wipe (`RateLimit.reset()` — exactly what a node
       restart loses, the Hammer table is in-memory-only) and the LOCKOUT
       DECISION is re-derived from the durable row, not just the count.
    5. "successful login -> reset" through the real controller path.
    6. Non-PII key discipline (INV-1): the durable row never carries a
       plaintext email.
    7. 30-day retention prune (`Samen.Retention.sweep/2` +
       `LoginFailure.retention_spec/2`).
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  require Ash.Query

  alias Samen.Auth.BlindIndex
  alias Samen.Identity.LoginFailure
  alias Samen.Identity.Register
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Mount
  alias Samen.Web.RateLimit
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  @resource Samen.WebTest.Operator.LoginFailure

  @secret_key_base String.duplicate("a", 64)

  # High enough that the ETS gate itself never trips before `signin_account`
  # does in the tests that need multiple real attempts to pass through.
  @limits %{
    signin_account: {3, 60_000},
    signin_ip: {50, 3_600_000},
    registration_ip: {50, 3_600_000},
    token_request_account: {50, 900_000},
    totp_verify_credential: {50, 60_000}
  }

  setup do
    prev = Application.get_env(:samen_web, RateLimit)
    Application.put_env(:samen_web, RateLimit, limits: @limits)
    RateLimit.reset()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_web, RateLimit, prev),
        else: Application.delete_env(:samen_web, RateLimit)

      RateLimit.reset()
    end)

    :ok
  end

  # ===========================================================================
  # 1. Accumulate / reset, paired with a positive control
  # ===========================================================================

  describe "bump!/4 accumulates; reset!/3 clears exactly the targeted key" do
    test "counts accumulate across repeated bumps; an unrelated key is unaffected" do
      bidx_a = unique_key("a")
      bidx_b = unique_key("b")

      assert LoginFailure.count(@resource, :email_bidx, bidx_a) == 0

      assert LoginFailure.bump!(@resource, :email_bidx, bidx_a, 900) == 1
      assert LoginFailure.bump!(@resource, :email_bidx, bidx_a, 900) == 2
      assert LoginFailure.bump!(@resource, :email_bidx, bidx_a, 900) == 3
      assert LoginFailure.count(@resource, :email_bidx, bidx_a) == 3

      # Positive control: a DIFFERENT key is untouched by bidx_a's bumps.
      assert LoginFailure.count(@resource, :email_bidx, bidx_b) == 0

      # reset! clears exactly the targeted key.
      :ok = LoginFailure.reset!(@resource, :email_bidx, bidx_a)
      assert LoginFailure.count(@resource, :email_bidx, bidx_a) == 0

      # reset! on an absent key is a safe no-op.
      :ok = LoginFailure.reset!(@resource, :email_bidx, unique_key("absent"))
    end

    test "the two key_kind axes are independent rows even for the same value" do
      shared_value = unique_key("shared")

      assert LoginFailure.bump!(@resource, :email_bidx, shared_value, 900) == 1
      assert LoginFailure.bump!(@resource, :credential, shared_value, 900) == 1
      assert LoginFailure.bump!(@resource, :email_bidx, shared_value, 900) == 2

      assert LoginFailure.count(@resource, :email_bidx, shared_value) == 2
      assert LoginFailure.count(@resource, :credential, shared_value) == 1
    end

    test "an expired window resets the count to 1 instead of incrementing (deterministic, no sleep)" do
      bidx = unique_key("expiry")

      assert LoginFailure.bump!(@resource, :email_bidx, bidx, 900) == 1
      assert LoginFailure.bump!(@resource, :email_bidx, bidx, 900) == 2

      backdate_window!(bidx, 10)

      # window_seconds: 1 — the backdated (10s-old) window has expired -> resets to 1.
      assert LoginFailure.bump!(@resource, :email_bidx, bidx, 1) == 1
    end
  end

  # ===========================================================================
  # 2. over_limit?/5 — the restart-survival enforcement primitive
  # ===========================================================================

  describe "over_limit?/5" do
    test "true once failure_count >= limit within a live window; a fresh key is not over" do
      bidx = unique_key("limit")

      refute LoginFailure.over_limit?(@resource, :email_bidx, bidx, 3, 900)

      LoginFailure.bump!(@resource, :email_bidx, bidx, 900)
      LoginFailure.bump!(@resource, :email_bidx, bidx, 900)
      refute LoginFailure.over_limit?(@resource, :email_bidx, bidx, 3, 900)

      LoginFailure.bump!(@resource, :email_bidx, bidx, 900)
      assert LoginFailure.over_limit?(@resource, :email_bidx, bidx, 3, 900)

      # Positive control: a fresh key at the SAME limit is not over.
      other = unique_key("limit-other")
      refute LoginFailure.over_limit?(@resource, :email_bidx, other, 3, 900)
    end

    test "a stale (window-expired) row is never over-limit" do
      bidx = unique_key("stale-limit")

      LoginFailure.bump!(@resource, :email_bidx, bidx, 900)
      LoginFailure.bump!(@resource, :email_bidx, bidx, 900)
      LoginFailure.bump!(@resource, :email_bidx, bidx, 900)
      assert LoginFailure.over_limit?(@resource, :email_bidx, bidx, 3, 900)

      backdate_window!(bidx, 1000)
      refute LoginFailure.over_limit?(@resource, :email_bidx, bidx, 3, 900)
    end
  end

  # ===========================================================================
  # 3. Restart survival through the REAL sign-in controller path
  # ===========================================================================

  describe "restart survival through the real sign-in path (ADR-038 §6.4 done-criterion 1)" do
    test "accumulated failures survive an ETS wipe and the lockout decision is re-derived from the durable row" do
      m = mount()
      acct = register!()
      {limit, _} = @limits.signin_account

      for _ <- 1..limit do
        assert login_outcome(m, acct.email, "wrong", {203, 0, 113, 1}) == :allowed
      end

      # Sanity: the ETS gate itself is now refusing (matches rate_limit_test.exs).
      assert login_outcome(m, acct.email, "wrong", {203, 0, 113, 1}) == :refused

      # SIMULATE A NODE RESTART: wipe the ETS table — `RateLimit.reset()` clears
      # exactly what a BEAM restart loses (the Hammer table is in-memory only).
      RateLimit.reset()

      {:ok, bidx} = BlindIndex.compute(acct.email)
      # The durable row is UNAFFECTED by the ETS wipe — a fresh read proves it
      # persisted independently of the process/table that was just cleared.
      assert LoginFailure.count(@resource, :email_bidx, bidx) >= limit

      # The LOCKOUT DECISION survives: a fresh attempt is STILL refused, even
      # though the ETS table alone (now empty) would say :ok.
      assert login_outcome(m, acct.email, "wrong", {203, 0, 113, 2}) == :refused

      # Positive control: a DIFFERENT account (never attempted) is allowed
      # post-restart — the durable re-check is scoped to the offending key only.
      other = register!()
      assert login_outcome(m, other.email, "wrong", {203, 0, 113, 3}) == :allowed
    end

    test "a successful login resets the durable row (ADR-038 §6.4 'successful login -> reset')" do
      m = mount()
      acct = register!()

      assert login_outcome(m, acct.email, "wrong", {198, 51, 100, 10}) == :allowed
      assert login_outcome(m, acct.email, "wrong", {198, 51, 100, 10}) == :allowed

      {:ok, bidx} = BlindIndex.compute(acct.email)
      assert LoginFailure.count(@resource, :email_bidx, bidx) == 2

      conn = do_login(m, acct.email, acct.password, {198, 51, 100, 10})
      assert conn.status in 300..399
      refute (get_resp_header(conn, "location") |> List.first()) =~ "error"

      assert LoginFailure.count(@resource, :email_bidx, bidx) == 0
    end
  end

  # ===========================================================================
  # 4. Non-PII key discipline (INV-1)
  # ===========================================================================

  describe "non-PII key discipline (INV-1)" do
    test "the durable row's key_value is the bidx, never the plaintext email" do
      m = mount()
      acct = register!()

      _ = login_outcome(m, acct.email, "wrong", {192, 0, 2, 40})

      {:ok, bidx} = BlindIndex.compute(acct.email)

      row =
        @resource
        |> Ash.Query.filter(key_kind == :email_bidx and key_value == ^bidx)
        |> Ash.read!(authorize?: false)
        |> List.first()

      assert row.key_value == bidx
      refute row.key_value =~ acct.email
    end
  end

  # ===========================================================================
  # 5. 30-day retention prune (ADR-038 §6.4)
  # ===========================================================================

  describe "30-day retention prune" do
    test "an idle (31d-old) row is pruned; a fresh row is retained" do
      stale = unique_key("stale")
      fresh = unique_key("fresh")

      LoginFailure.bump!(@resource, :email_bidx, stale, 900)
      LoginFailure.bump!(@resource, :email_bidx, fresh, 900)

      old =
        DateTime.utc_now()
        |> DateTime.add(-31 * 24 * 60 * 60, :second)
        |> DateTime.truncate(:microsecond)

      backdate_last_failed_at!(stale, old)

      spec = LoginFailure.retention_spec(@resource)
      result = Samen.Retention.sweep([spec])

      assert result.swept == 1
      assert LoginFailure.count(@resource, :email_bidx, stale) == 0
      # Positive control: the fresh row survives the SAME sweep pass.
      assert LoginFailure.count(@resource, :email_bidx, fresh) == 1
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp unique_key(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp row!(bidx) do
    @resource
    |> Ash.Query.filter(key_kind == :email_bidx and key_value == ^bidx)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp backdate_window!(bidx, seconds_ago) do
    old = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)

    row!(bidx)
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:window_started_at, old)
    |> Ash.update!()
  end

  defp backdate_last_failed_at!(bidx, dt) do
    row!(bidx)
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:last_failed_at, dt)
    |> Ash.update!()
  end

  defp mount, do: Mount.new(:auth, Samen.WebTest.Operator, Repo)
  defp unique_email, do: "lfd-#{System.unique_integer([:positive])}@example.test"

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp register!(email \\ nil) do
    email = email || unique_email()

    attrs = %{
      org_name: "LFD Co #{System.unique_integer([:positive])}",
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

  defp login_outcome(mount, email, password, ip) do
    mount |> do_login(email, password, ip) |> outcome()
  end

  defp outcome(%{status: 429}), do: :refused
  defp outcome(%{status: status}) when status in 300..399, do: :allowed
end
