defmodule Samen.Web.Auth.SessionTest do
  @moduledoc """
  T04 — A4 session management (ADR-035 §4.3/§5 A4; spec-questions c3), against
  the samen_web test host's Operator Identity mount. `Identity.Session` itself
  was built minimally by T03 (revoke-all-on-reset); this task EXTENDS that
  SAME resource — no second table.

  Proves:

    1. `Samen.Auth.SessionCreate.create/3` mints a live Session row (sliding
       60-day expiry, hashed-at-rest token, derived `device_label`).
    2. The remember-me cookie (`Samen.Web.Auth.write_remember_cookie/2`)
       carries `secure`/`http_only`/`same_site` flags + a 60-day max-age, and
       is SIGNED (a tampered value fails `read_remember_cookie/1`).
    3. `Samen.Auth.SessionList.list_live/2` shows device/created metadata.
    4. RED: revoking a session (`Samen.Auth.SessionRevoke.revoke_one/3`) makes
       its next `Samen.Web.Auth.resolve_principal/2` call fail. CONTROL: a
       sibling live session still resolves.
    5. `revoke_others/3` revokes every OTHER live session, keeping the current
       one alive (the c3 "revoke all other sessions" control, distinct from
       A3's revoke-ALL-including-current).
    6. The optional org-level concurrent-session cap (c3): unset → unlimited
       (no eviction); set → the credential's OLDEST live session(s) are
       evicted so the live count never exceeds the cap.
    7. `Samen.Web.Auth.SessionController` writes the cookies on a REAL HTTP
       response (login/logout/revoke), never inside a LiveView.
    8. `Samen.Web.Auth.LoginLive` renders + the timing-parity-safe validate.
    9. `Samen.Web.Settings.SecurityLive`'s `spine_sessions:` opt-in inversion
       (real controls) vs. the untouched default honesty red-path.
    10. INV-2: no PII on the Session row — a raw column probe.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  require Ash.Query

  alias Samen.Auth.DeviceLabel
  alias Samen.Auth.SessionCreate
  alias Samen.Auth.SessionList
  alias Samen.Auth.SessionRevoke
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.LoginLive
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Mount
  alias Samen.Web.Settings.SecurityLive
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User

  @secret_key_base String.duplicate("a", 64)

  # See reset_test.exs / confirm_test.exs — `Samen.Delivery.AuthMailer` resolves
  # its env the SAME way `Samen.Delivery.Lifecycle.EmailWorker` does; the house
  # convention (T03 addendum point 3, T04 addendum point 3) is to set it
  # explicitly rather than trust the compiled default (samen_core is compiled
  # as a path dep of multiple sibling hosts, where the fallback doesn't reliably
  # resolve to :test).
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
  defp session_mods, do: %{session: Session}

  defp unique_email, do: "session-#{System.unique_integer([:positive])}@example.test"

  defp register!(password \\ "correct horse battery staple") do
    attrs = %{
      org_name: "Session Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result |> Map.put(:email, attrs.email) |> Map.put(:password, password)
  end

  defp reread_session(id) do
    Session
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :credential_id, :device_label, :last_seen_at, :expires_at, :revoked_at, :inserted_at, :token_digest])
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # A directly-created live Session row with an explicit `inserted_at` (bypasses
  # `SessionCreate.create/3`'s real-clock timestamp for a deterministic ordering
  # proof) — the SAME "direct internal write" pattern `reset_test.exs`'s
  # `create_session!/2` helper uses.
  defp create_session_at!(credential_id, inserted_at) do
    Session
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
    |> Ash.Changeset.force_change_attribute(:token_digest, :crypto.strong_rand_bytes(16) |> Base.encode16())
    |> Ash.Changeset.force_change_attribute(:expires_at, DateTime.utc_now() |> DateTime.add(60, :day))
    |> Ash.Changeset.force_change_attribute(:inserted_at, inserted_at)
    |> Ash.create!()
  end

  defp live_session_ids(credential_id) do
    Session
    |> Ash.Query.filter(credential_id == ^credential_id and is_nil(revoked_at))
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  # A minimal conn with the session plug installed, as the host :browser pipeline
  # provides — the SAME harness `session_controller_test.exs` uses. `req_cookies`
  # (a `{key, value}` list) MUST be applied before `Plug.Session.call/2`/
  # `fetch_session/1` — both fetch the incoming cookie header internally, and
  # `Plug.Test.put_req_cookie/3` refuses to mutate request cookies afterward.
  defp session_conn(method \\ :get, path \\ "/", req_cookies \\ []) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> then(fn conn -> Enum.reduce(req_cookies, conn, fn {k, v}, acc -> put_req_cookie(acc, k, v) end) end)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  # ===========================================================================
  # 1. Samen.Auth.SessionCreate.create/3 — mint
  # ===========================================================================

  describe "Samen.Auth.SessionCreate.create/3" do
    test "mints a live session with a sliding ~60-day expiry, hashed-at-rest token" do
      result = register!()

      assert {:ok, session, raw_token} =
               SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Chrome on macOS")

      refute is_nil(session.id)
      assert session.revoked_at == nil
      assert session.device_label == "Chrome on macOS"

      row = reread_session(session.id)
      refute row.token_digest == raw_token
      refute row.token_digest =~ raw_token
      assert row.token_digest == Samen.Auth.TokenMint.digest(raw_token)

      days_until_expiry = DateTime.diff(row.expires_at, DateTime.utc_now(), :day)
      assert days_until_expiry in 58..60
    end

    test "default_ttl_seconds/0 is 60 days, and drives the same expiry SessionResolve.touch/2 slides to" do
      assert SessionCreate.default_ttl_seconds() == 60 * 24 * 60 * 60
    end
  end

  # ===========================================================================
  # 2. Remember-me cookie flags (Samen.Web.Auth)
  # ===========================================================================

  describe "remember-me cookie — secure/http_only/same_site (ASSERT, ADR-035 §4.3)" do
    test "write_remember_cookie/2 sets http_only, secure, SameSite=Lax, and a 60-day max_age" do
      conn = session_conn() |> Auth.write_remember_cookie("some-raw-session-token")

      cookie = conn.resp_cookies[Auth.remember_cookie_key()]
      refute is_nil(cookie)
      assert cookie.http_only == true
      assert cookie.secure == true
      assert cookie.same_site == "Lax"
      assert cookie.max_age == 60 * 24 * 60 * 60
    end

    test "the cookie's stored VALUE is signed, not the raw token in the clear" do
      conn = session_conn() |> Auth.write_remember_cookie("some-raw-session-token")
      cookie = conn.resp_cookies[Auth.remember_cookie_key()]

      refute cookie.value == "some-raw-session-token"
      assert {:ok, "some-raw-session-token"} = Plug.Crypto.verify(@secret_key_base, "samen.web.auth.remember_me", cookie.value)
    end

    test "read_remember_cookie/1 round-trips a cookie written by write_remember_cookie/2" do
      conn = session_conn() |> Auth.write_remember_cookie("round-trip-token")
      cookie = conn.resp_cookies[Auth.remember_cookie_key()]

      read_conn = session_conn(:get, "/", [{Auth.remember_cookie_key(), cookie.value}])
      assert Auth.read_remember_cookie(read_conn) == "round-trip-token"
    end

    test "RED PATH: a tampered cookie value fails verification (never resolves to a forged token)" do
      conn = session_conn() |> Auth.write_remember_cookie("real-token")
      cookie = conn.resp_cookies[Auth.remember_cookie_key()]

      # Flip the FIRST character of the signed value — a full-6-bit base64
      # position, so the tamper ALWAYS changes the decoded bytes. Flipping the
      # LAST char (the previous approach) could be a no-op when it encodes unused
      # trailing bits, which made this red-path FLAKY (a tampered value that
      # decoded identically still verified). The tamper must be deterministic for
      # the assertion to be genuinely refutable on every run.
      <<first, rest::binary>> = cookie.value
      tampered = <<if(first == ?A, do: ?B, else: ?A)>> <> rest
      refute tampered == cookie.value

      read_conn = session_conn(:get, "/", [{Auth.remember_cookie_key(), tampered}])
      assert Auth.read_remember_cookie(read_conn) == nil
    end

    test "a MISSING cookie reads as nil, never raises" do
      assert Auth.read_remember_cookie(session_conn()) == nil
    end

    test "clear_remember_cookie/1 expires the cookie" do
      conn = session_conn() |> Auth.write_remember_cookie("some-token") |> Auth.clear_remember_cookie()
      cookie = conn.resp_cookies[Auth.remember_cookie_key()]
      assert cookie.max_age == 0
    end
  end

  # ===========================================================================
  # 3. Session list — device/created metadata
  # ===========================================================================

  describe "Samen.Auth.SessionList.list_live/2" do
    test "shows device_label + created (inserted_at) metadata for every live session" do
      result = register!()

      {:ok, s1, _raw1} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Safari on macOS")
      {:ok, s2, _raw2} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Chrome on Windows")

      listed = SessionList.list_live(Session, result.credential.id)
      by_id = Map.new(listed, &{&1.id, &1})

      assert Enum.sort(Map.keys(by_id)) == Enum.sort([s1.id, s2.id])
      assert by_id[s1.id].device_label == "Safari on macOS"
      assert by_id[s2.id].device_label == "Chrome on Windows"

      for %{inserted_at: inserted_at} <- listed do
        assert %DateTime{} = inserted_at
      end
    end

    # `inserted_at` is second-precision (ADR-004 storage discipline) — two
    # sessions minted in the same wall-clock second would tie under
    # `SessionCreate.create/3`'s real timestamp. Prove the NEWEST-FIRST
    # ordering deterministically with directly-set `inserted_at` values
    # (the same "direct internal write" pattern `reset_test.exs`'s
    # `create_session!/2` helper uses).
    test "orders newest (inserted_at) first" do
      result = register!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      older = create_session_at!(result.credential.id, DateTime.add(now, -60, :second))
      newer = create_session_at!(result.credential.id, now)

      [first, second] = SessionList.list_live(Session, result.credential.id)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "excludes revoked sessions" do
      result = register!()
      {:ok, live, _} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, revoked, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      {:ok, :revoked} = SessionRevoke.revoke_one(Session, revoked.id, result.credential.id)

      ids = SessionList.list_live(Session, result.credential.id) |> Enum.map(& &1.id)
      assert live.id in ids
      refute revoked.id in ids
    end
  end

  # ===========================================================================
  # 4. Revoke ONE session — RED (revoked → unauthenticated) + CONTROL (survivor)
  # ===========================================================================

  describe "revoking a session makes its next request unauthenticated (RED) while a sibling still works (CONTROL)" do
    test "resolve_principal/2 fails for the revoked session's token, succeeds for the surviving one" do
      result = register!()

      {:ok, _s1, raw1} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Device A")
      {:ok, s2, raw2} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Device B")

      {:ok, :revoked} = SessionRevoke.revoke_one(Session, s2.id, result.credential.id)

      # CONTROL first (anti-tautology): the surviving session resolves fine.
      assert {:ok, %{credential_id: credential_id}} =
               Auth.resolve_principal(%{Auth.session_token_key() => raw1}, session_mods())

      assert credential_id == result.credential.id

      # RED: the revoked session's raw token now resolves to nothing.
      assert Auth.resolve_principal(%{Auth.session_token_key() => raw2}, session_mods()) == :error
    end

    test "Samen.Auth.SessionResolve.resolve/2 directly: a revoked/expired token is refused, the SAME generic :error" do
      result = register!()
      {:ok, session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)

      assert {:ok, _} = Samen.Auth.SessionResolve.resolve(Session, raw)

      {:ok, :revoked} = SessionRevoke.revoke_one(Session, session.id, result.credential.id)
      assert Samen.Auth.SessionResolve.resolve(Session, raw) == :error

      assert Samen.Auth.SessionResolve.resolve(Session, "totally-unknown-token") == :error
    end

    test "revoke_one/3 refuses a session belonging to a DIFFERENT credential (defense in depth)" do
      mine = register!()
      other = register!()

      {:ok, other_session, other_raw} = SessionCreate.create(session_create_mods(), other.credential.id)

      assert {:error, :not_found} = SessionRevoke.revoke_one(Session, other_session.id, mine.credential.id)

      # CONTROL: the other credential's session is untouched — still resolves.
      assert {:ok, _} = Samen.Auth.SessionResolve.resolve(Session, other_raw)
    end

    test "revoke_one/3 is idempotent for the caller's OWN session" do
      result = register!()
      {:ok, session, _raw} = SessionCreate.create(session_create_mods(), result.credential.id)

      assert {:ok, :revoked} = SessionRevoke.revoke_one(Session, session.id, result.credential.id)
      assert {:ok, :revoked} = SessionRevoke.revoke_one(Session, session.id, result.credential.id)
    end
  end

  # ===========================================================================
  # 5. Revoke-all-EXCEPT-current
  # ===========================================================================

  describe "Samen.Auth.SessionRevoke.revoke_others/3 — revoke-all-except-current" do
    test "revokes every OTHER live session; the current one survives" do
      result = register!()

      {:ok, current, current_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, other1, _} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, other2, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      :ok = SessionRevoke.revoke_others(Session, result.credential.id, current.id)

      live_ids = live_session_ids(result.credential.id)
      assert live_ids == [current.id]
      refute other1.id in live_ids
      refute other2.id in live_ids

      # CONTROL: the current session's token still resolves.
      assert {:ok, %{session_id: session_id}} =
               Auth.resolve_principal(%{Auth.session_token_key() => current_raw}, session_mods())

      assert session_id == current.id
    end
  end

  # ===========================================================================
  # 6. Org-level concurrent-session cap (spec-questions c3) — both states
  # ===========================================================================

  describe "org max-session setting — UNSET (unlimited, the c3 default)" do
    test "no eviction: five sequential sign-ins all stay live" do
      result = register!()

      ids =
        for _ <- 1..5 do
          {:ok, s, _raw} = SessionCreate.create(session_create_mods(), result.credential.id)
          s.id
        end

      live_ids = live_session_ids(result.credential.id)
      assert Enum.sort(ids) == Enum.sort(live_ids)
    end
  end

  describe "org max-session setting — SET (enforced: oldest evicted)" do
    test "a cap of 2 evicts the OLDEST live session once a third is minted" do
      result = register!()

      result.org
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:max_concurrent_sessions, 2)
      |> Ash.update!()

      {:ok, s1, _} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Oldest")
      {:ok, s2, _} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Middle")
      {:ok, s3, _} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Newest")

      live_ids = live_session_ids(result.credential.id)

      assert Enum.sort(live_ids) == Enum.sort([s2.id, s3.id])
      refute s1.id in live_ids

      s1_row = reread_session(s1.id)
      refute is_nil(s1_row.revoked_at)
    end

    # ADR-035 §4.3 A4 (T104) — DETERMINISTIC oldest-eviction regression pinning the
    # second-precision `inserted_at` tie bug (the T04 TOCTOU / T09-attempt-1 flake,
    # root-caused in T102). Constructs FOUR sessions in the SAME wall-clock second
    # but with DISTINCT microsecond `inserted_at`, INSERTED newest-first so physical
    # heap order is the INVERSE of creation order. Pre-fix (`sort(inserted_at: :asc)`
    # over a second-precision column, no tiebreak) the four collapse to one tied
    # value and eviction removes the arbitrary heap-order rows — the WRONG ones.
    # With the usec column + `{inserted_at, id}` total order, the genuinely-oldest
    # are evicted and the newest cap-many survive. RED-on-revert is deterministic:
    # the sub-second probe fails outright at second precision, and the newest-first
    # insertion makes the tie evict the newest. No sleep/seed/tag — ordering is
    # constructed, not raced.
    test "cap of 2: the genuinely-oldest same-second sessions are evicted; the newest cap-many survive" do
      result = register!()

      result.org
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:max_concurrent_sessions, 2)
      |> Ash.update!()

      base = DateTime.utc_now() |> DateTime.truncate(:second)
      at = fn micros -> %{base | microsecond: {micros, 6}} end

      # Newest-first insertion (heap order = inverse of creation order): s1 oldest.
      s4 = create_session_at!(result.credential.id, at.(4000))
      s3 = create_session_at!(result.credential.id, at.(3000))
      s2 = create_session_at!(result.credential.id, at.(2000))
      s1 = create_session_at!(result.credential.id, at.(1000))

      # Premise of the fix: the four inserted_at values PERSIST distinct (sub-second
      # resolution). At second precision they collapse to one — RED on the revert.
      persisted = for s <- [s1, s2, s3, s4], do: reread_session(s.id).inserted_at
      assert persisted |> Enum.uniq() |> length() == 4,
             "session inserted_at must carry sub-second (µs) resolution for a total eviction order"

      # A fresh sign-in trips the cap (5 live → prune to 2).
      {:ok, s5, _} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Trigger")

      live = live_session_ids(result.credential.id) |> MapSet.new()

      # Survivor set is EXACTLY the newest cap-many: the just-minted s5 + the newest
      # pre-existing (s4). The three genuinely-older (s1, s2, s3) are all evicted —
      # never an arbitrary pick.
      assert live == MapSet.new([s4.id, s5.id]),
             "expected the newest cap-many to survive; got #{inspect(MapSet.to_list(live))}"

      for older <- [s1, s2, s3] do
        refute older.id in live
        refute is_nil(reread_session(older.id).revoked_at)
      end
    end

    # ADR-035 §4.3 A4 (T104) — the total-order sort-key probe (done-criterion 2):
    # the EXACT key `evict_to_cap` orders by — `{inserted_at, id}` — is strictly
    # unique across a same-second live set, AND the primary (`inserted_at`)
    # component alone already separates them, so eviction can never tie into an
    # arbitrary row. RED at second precision (the inserted_at component collapses).
    test "the eviction sort key {inserted_at, id} is a strict total order over same-second sessions" do
      result = register!()
      base = DateTime.utc_now() |> DateTime.truncate(:second)
      at = fn micros -> %{base | microsecond: {micros, 6}} end

      created = for m <- [1000, 2000, 3000, 4000], do: create_session_at!(result.credential.id, at.(m))

      rows =
        Session
        |> Ash.Query.filter(credential_id == ^result.credential.id and is_nil(revoked_at))
        |> Ash.Query.select([:id, :inserted_at])
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.read!(authorize?: false)

      # Composite key is unique per session (strict total order).
      keys = for r <- rows, do: {r.inserted_at, r.id}
      assert keys |> Enum.uniq() |> length() == length(created)

      # The sub-second primary component alone already separates them (the fix's
      # premise) — this is what collapses, and fails RED, at second precision.
      stamps = Enum.map(rows, & &1.inserted_at)
      assert stamps |> Enum.uniq() |> length() == length(created)

      # Ordered oldest → newest by true creation time.
      assert stamps == Enum.sort(stamps, DateTime)
    end

    test "a cap of 1 evicts EVERY prior session — the newest sign-in is the sole survivor" do
      result = register!()

      result.org
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:max_concurrent_sessions, 1)
      |> Ash.update!()

      {:ok, _s1, _} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, _s2, _} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, s3, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      assert live_session_ids(result.credential.id) == [s3.id]
    end

    test "CONTROL: a DIFFERENT credential's cap-less org is unaffected by a capped sibling" do
      capped = register!()
      uncapped = register!()

      capped.org
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:max_concurrent_sessions, 1)
      |> Ash.update!()

      for _ <- 1..4, do: SessionCreate.create(session_create_mods(), uncapped.credential.id)
      for _ <- 1..4, do: SessionCreate.create(session_create_mods(), capped.credential.id)

      assert length(live_session_ids(uncapped.credential.id)) == 4
      assert length(live_session_ids(capped.credential.id)) == 1
    end
  end

  # ===========================================================================
  # 7. Samen.Web.Auth.SessionController — cookies on a REAL HTTP response
  # ===========================================================================

  describe "Samen.Web.Auth.SessionController.create/2 — login" do
    defp auth_conn(mount) do
      session_conn(:post, "/login")
      |> put_private(:samen_mount, mount)
        |> put_private(:samen_login_path, "/login")
    end

    test "valid credentials mint a session, write the token, and redirect to a sanitized return_to" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)

      conn =
        SessionController.create(
          auth_conn(mount),
          %{"login" => %{"email" => result.email, "password" => result.password}, "return_to" => "/dashboard"}
        )

      assert conn.status in 300..399
      assert conn |> get_resp_header("location") |> List.first() == "/dashboard"
      assert is_binary(get_session(conn, Auth.session_token_key()))

      # The token really does resolve to a live session for this credential.
      raw = get_session(conn, Auth.session_token_key())
      assert {:ok, %{credential_id: credential_id}} = Auth.resolve_principal(%{Auth.session_token_key() => raw}, session_mods())
      assert credential_id == result.credential.id
    end

    test "remember_me: \"true\" ALSO writes the signed remember-me cookie carrying the SAME raw token" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)

      conn =
        SessionController.create(
          auth_conn(mount),
          %{"login" => %{"email" => result.email, "password" => result.password, "remember_me" => "true"}}
        )

      raw = get_session(conn, Auth.session_token_key())
      cookie = conn.resp_cookies[Auth.remember_cookie_key()]
      refute is_nil(cookie)
      assert cookie.secure == true
      assert cookie.http_only == true
      assert {:ok, ^raw} = Plug.Crypto.verify(@secret_key_base, "samen.web.auth.remember_me", cookie.value)
    end

    test "without remember_me, no remember-me cookie is written" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)

      conn = SessionController.create(auth_conn(mount), %{"login" => %{"email" => result.email, "password" => result.password}})
      assert conn.resp_cookies[Auth.remember_cookie_key()] == nil
    end

    test "RED: bad credentials redirect back to login with ?error=1, mint NO session" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      before = Ash.count!(Session, authorize?: false)

      conn =
        SessionController.create(
          auth_conn(mount),
          %{"login" => %{"email" => result.email, "password" => "totally-wrong"}}
        )

      assert conn |> get_resp_header("location") |> List.first() == "/login?error=1"
      assert Ash.count!(Session, authorize?: false) == before
    end
  end

  describe "Samen.Web.Auth.SessionController.delete/2 — logout" do
    test "revokes the current session and clears both the token key and remember cookie" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      {:ok, session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn(:get, "/logout")
        |> put_session(Auth.session_token_key(), raw)
        |> Auth.write_remember_cookie(raw)
        |> put_private(:samen_mount, mount)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.delete(conn, %{})

      assert conn.status in 300..399
      assert get_session(conn, Auth.session_token_key()) == nil
      assert conn.resp_cookies[Auth.remember_cookie_key()].max_age == 0

      row = reread_session(session.id)
      refute is_nil(row.revoked_at)
    end
  end

  describe "Samen.Web.Auth.SessionController.revoke/2 and revoke_others/2 — settings/security controls" do
    test "revoke/2 revokes exactly the named session, scoped to the CALLER's own credential" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      {:ok, current, current_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, target, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn(:post, "/settings/security/sessions/#{target.id}/revoke")
        |> put_session(Auth.session_token_key(), current_raw)
        |> put_private(:samen_mount, mount)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.revoke(conn, %{"id" => target.id})
      assert conn.status in 300..399

      live_ids = live_session_ids(result.credential.id)
      assert current.id in live_ids
      refute target.id in live_ids
    end

    test "revoke_others/2 keeps the requester's own session live" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      {:ok, current, current_raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, other, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn(:post, "/settings/security/sessions/revoke_others")
        |> put_session(Auth.session_token_key(), current_raw)
        |> put_private(:samen_mount, mount)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.revoke_others(conn, %{})
      assert conn.status in 300..399

      live_ids = live_session_ids(result.credential.id)
      assert live_ids == [current.id]
      refute other.id in live_ids
    end

    test "an UNAUTHENTICATED request revokes nothing and is redirected to login" do
      result = register!()
      mount = Mount.new(:auth, Samen.WebTest.Operator, Repo)
      {:ok, target, _} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn(:post, "/settings/security/sessions/#{target.id}/revoke")
        |> put_private(:samen_mount, mount)
        |> put_private(:samen_login_path, "/login")

      conn = SessionController.revoke(conn, %{"id" => target.id})

      assert conn |> get_resp_header("location") |> List.first() == "/login"
      assert target.id in live_session_ids(result.credential.id)
    end
  end

  # ===========================================================================
  # 8. Samen.Web.Auth.LoginLive
  # ===========================================================================

  describe "Samen.Web.Auth.LoginLive" do
    test "renders the sign-in form (pre-actor, no org data)" do
      mount = build_mount(:auth)
      html = mount_smoke(LoginLive, mount)

      assert html =~ "Sign in"
      assert html =~ "login-form"
      assert html =~ "login-submit"
      assert html =~ "login-remember-me"
    end

    test "valid credentials arm phx-trigger-action (the LiveView never sets the cookie itself)" do
      result = register!()
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = LoginLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket} =
        LoginLive.handle_event("login", %{"login" => %{"email" => result.email, "password" => result.password}}, socket)

      assert socket.assigns.trigger_submit == true
      assert socket.assigns.error == nil
    end

    test "RED: wrong password shows the generic error, never arms the trigger — SAME message as an unknown email" do
      result = register!()
      mount = build_mount(:auth)
      session = mount_session(mount)

      {:ok, socket1} = LoginLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket1} =
        LoginLive.handle_event("login", %{"login" => %{"email" => result.email, "password" => "wrong"}}, socket1)

      {:ok, socket2} = LoginLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket2} =
        LoginLive.handle_event("login", %{"login" => %{"email" => unique_email(), "password" => "whatever"}}, socket2)

      refute socket1.assigns.trigger_submit
      refute socket2.assigns.trigger_submit
      assert socket1.assigns.error == socket2.assigns.error
    end
  end

  # ===========================================================================
  # 9. Samen.Web.Settings.SecurityLive — the ADR-035 §4.3 explicit opt-in
  # ===========================================================================

  describe "SecurityLive DEFAULT (no spine_sessions: opt-in) — the RP-ST-4 honesty red-path is UNTOUCHED" do
    test "still shows the honest placeholder, still has NO phx-click/phx-submit" do
      org_id = Ash.UUID.generate()
      {user, _membership} = seed_user!(org_id)

      mount = build_mount(:settings)
      html = render_live(SecurityLive, mount, [org_id, user.id])

      assert html =~ "Managed by your identity provider"
      refute html =~ "phx-click"
      refute html =~ "phx-submit"
      refute html =~ "security-login-sessions"
    end
  end

  describe "SecurityLive with spine_sessions: true — the REAL session list + revoke controls" do
    test "renders device/created metadata and a plain-HTML (non-phx) revoke form" do
      result = register!()
      org_id = result.org.id
      user_id = result.user.id

      {:ok, _s, _raw} = SessionCreate.create(session_create_mods(), result.credential.id, device_label: "Firefox on Linux")

      mount = spine_settings_mount()
      html = render_live(SecurityLive, mount, [org_id, user_id])

      assert html =~ "security-login-sessions"
      assert html =~ "Firefox on Linux"
      assert html =~ ~s(action="/settings/security/sessions/)
      assert html =~ "Revoke"
      # Still no LiveView-driven auth mutation — the honesty structural
      # invariant holds even in real mode (a plain HTML form POST, never a
      # phx-click/phx-submit).
      refute html =~ "phx-click"
      refute html =~ "phx-submit"
    end

    test "an empty session list renders honestly (\"No active sessions\"), never a fake row" do
      result = register!()

      mount = spine_settings_mount()
      html = render_live(SecurityLive, mount, [result.org.id, result.user.id])

      assert html =~ "No active sessions."
    end
  end

  defp seed_user!(org_id) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "secuser#{System.unique_integer([:positive])}"}, authorize?: false)
      |> Ash.create!()

    membership =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: :admin}, authorize?: false)
      |> Ash.create!()

    {user, membership}
  end

  defp spine_settings_mount do
    Mount.new(:settings, Samen.WebTest.Operator, Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{spine_sessions: true, settings_path: "/settings"}
    )
  end

  # ===========================================================================
  # 10. INV-2 — no PII on the Session row (structural column probe)
  # ===========================================================================

  describe "INV-2: no PII in session rows" do
    test "the wos_session table carries ONLY the declared non-PII columns — no raw user-agent, no IP" do
      %{rows: rows} =
        Repo.query!("SELECT column_name FROM information_schema.columns WHERE table_name = 'wos_session'", [])

      columns = rows |> List.flatten() |> MapSet.new()

      expected =
        MapSet.new(~w(
          wos_id wos_org_id wos_inserted_at wos_updated_at
          wos_token_digest wos_last_seen_at wos_expires_at wos_revoked_at
          wos_device_label wos_credential_id
        ))

      assert columns == expected

      refute Enum.any?(columns, &(&1 =~ "ip"))
      refute Enum.any?(columns, &(&1 =~ "agent"))
      refute Enum.any?(columns, &(&1 =~ "email"))
    end

    test "device_label values never look like a raw user-agent or an IP address" do
      result = register!()

      for ua <- [
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
            nil
          ] do
        {:ok, session, _raw} =
          SessionCreate.create(session_create_mods(), result.credential.id, device_label: DeviceLabel.from_user_agent(ua))

        refute session.device_label =~ ~r/\d+\.\d+\.\d+\.\d+/
        refute session.device_label =~ "AppleWebKit"
        refute session.device_label =~ "537.36"
      end
    end
  end

  # ===========================================================================
  # 11. Samen.Web.Auth.Plug + on_mount {Samen.Web.Auth, :ensure_authenticated}
  # ===========================================================================

  describe "Samen.Web.Auth.Plug — remember-me cookie resurrection on the browser pipeline" do
    test "a session-token-carrying request passes through unchanged" do
      result = register!()
      {:ok, _session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)

      conn =
        session_conn()
        |> put_session(Auth.session_token_key(), raw)
        |> Samen.Web.Auth.Plug.call(session_mod: Session)

      assert get_session(conn, Auth.session_token_key()) == raw
    end

    test "a valid remember-me cookie (no session token) RESURRECTS the token into the Plug session" do
      result = register!()
      {:ok, _session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      remembered = Plug.Crypto.sign(@secret_key_base, "samen.web.auth.remember_me", raw)

      conn =
        session_conn(:get, "/", [{Auth.remember_cookie_key(), remembered}])
        |> Samen.Web.Auth.Plug.call(session_mod: Session)

      assert get_session(conn, Auth.session_token_key()) == raw
    end

    test "RED: a revoked session's remember-me cookie resurrects NOTHING" do
      result = register!()
      {:ok, session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, :revoked} = SessionRevoke.revoke_one(Session, session.id, result.credential.id)
      remembered = Plug.Crypto.sign(@secret_key_base, "samen.web.auth.remember_me", raw)

      conn =
        session_conn(:get, "/", [{Auth.remember_cookie_key(), remembered}])
        |> Samen.Web.Auth.Plug.call(session_mod: Session)

      assert get_session(conn, Auth.session_token_key()) == nil
    end

    test "no session token, no remember cookie: passes through unauthenticated (never raises)" do
      conn = session_conn() |> Samen.Web.Auth.Plug.call(session_mod: Session)
      assert get_session(conn, Auth.session_token_key()) == nil
    end
  end

  describe "on_mount {Samen.Web.Auth, :ensure_authenticated}" do
    test "CONTROL: a live session token assigns samen_credential_id/samen_session_id and :cont" do
      result = register!()
      {:ok, session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      mount = build_mount(:auth)

      session_map = mount_session(mount) |> Map.put(Auth.session_token_key(), raw)

      assert {:cont, socket} = Auth.on_mount(:ensure_authenticated, %{}, session_map, %Phoenix.LiveView.Socket{})
      assert socket.assigns.samen_credential_id == result.credential.id
      assert socket.assigns.samen_session_id == session.id
    end

    test "RED: a revoked session token :halts + redirects to /login" do
      result = register!()
      {:ok, session, raw} = SessionCreate.create(session_create_mods(), result.credential.id)
      {:ok, :revoked} = SessionRevoke.revoke_one(Session, session.id, result.credential.id)
      mount = build_mount(:auth)

      session_map = mount_session(mount) |> Map.put(Auth.session_token_key(), raw)

      assert {:halt, socket} = Auth.on_mount(:ensure_authenticated, %{}, session_map, %Phoenix.LiveView.Socket{})
      assert socket.redirected == {:redirect, %{status: 302, to: "/login"}}
    end

    test "RED: no session token at all :halts + redirects to /login" do
      mount = build_mount(:auth)
      session_map = mount_session(mount)

      assert {:halt, socket} = Auth.on_mount(:ensure_authenticated, %{}, session_map, %Phoenix.LiveView.Socket{})
      assert socket.redirected == {:redirect, %{status: 302, to: "/login"}}
    end
  end
end
