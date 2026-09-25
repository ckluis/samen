defmodule Samen.Web.FleetIngressTest do
  @moduledoc """
  T82 HTTP-layer proof: the app-side probe/directive receiver
  (`Samen.Web.Fleet.Ingress`) and the cockpit-side enroll/heartbeat ingest
  (`Samen.Web.Fleet.CockpitIngress`) — RP-J-1/RP-J-2/RP-J-3/RP-J-10/RP-J-13
  groundwork at the ACTUAL HTTP response level (status + body), which is what
  the sabotage patches (204→200+body, etc.) flip against.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Fleet.{Crypto, LocalCredential, Registry}
  alias Samen.Web.Fleet.{CockpitIngress, Ingress}
  alias Samen.WebTest.Repo, as: TestRepo

  @ns Samen.WebTest.Fleet
  @admin Samen.Fleet.AdminActor.new("operator-1")
  @host :fleet_ingress_test_host

  # RP-J-13 (issue #36). `Hammer.ETS.FixWindow` indexes its counter by `div(now, window_ms)`
  # — a WALL-CLOCK aligned window, i.e. global state no test owns. A window WIDER THAN THE
  # EPOCH ITSELF (~1000 years in ms) makes that index a constant 0 for any `now` this
  # millennium, so the window cannot roll over mid-test. That is the whole of the fix for
  # RP-J-13's seed dependence, and the arm below ASSERTS the index rather than assuming it.
  @window_pinned_open_ms 31_536_000_000_000

  # The kid RP-J-13 plants its "another cockpit was here first" traffic under — deliberately
  # NOT the enrolled app's own kid, which is what makes the bucket-key isolation assertable.
  @prior_traffic_kid "rp-j-13-prior-traffic-kid"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Samen.Fleet.NonceCache.reset()
    Samen.Web.RateLimit.reset()
    Samen.Fleet.Attention.reset()
    LocalCredential.Agent.reset()
    :ok
  end

  # ---------------------------------------------------------------------------
  # GET /fleet/health — app side (RP-J-1, RP-J-10)
  # ---------------------------------------------------------------------------

  describe "GET /fleet/health — mode A" do
    test "RP-J-10: no local credential configured -> 503, empty body" do
      conn = conn(:get, "/fleet/health") |> Ingress.health(otp_app: @host)
      assert conn.status == 503
      assert conn.resp_body == ""
    end

    test "GREEN (control): correctly signed request -> 200 + schema-valid report" do
      secret = :crypto.strong_rand_bytes(32)
      :ok = LocalCredential.put(@host, %{kind: :shared_secret, secret: secret})

      conn = signed_get(secret)
      resp = Ingress.health(conn, otp_app: @host)

      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert :ok = Samen.Fleet.Report.Schema.validate(payload)
    end

    test "RP-J-1 RED: wrong secret -> 401" do
      secret = :crypto.strong_rand_bytes(32)
      :ok = LocalCredential.put(@host, %{kind: :shared_secret, secret: secret})

      wrong = :crypto.strong_rand_bytes(32)
      conn = signed_get(wrong)
      resp = Ingress.health(conn, otp_app: @host)

      assert resp.status == 401
      assert resp.resp_body == ""
    end

    test "RED: missing Authorization header -> 401" do
      secret = :crypto.strong_rand_bytes(32)
      :ok = LocalCredential.put(@host, %{kind: :shared_secret, secret: secret})

      conn = conn(:get, "/fleet/health")
      resp = Ingress.health(conn, otp_app: @host)
      assert resp.status == 401
    end

    test "fix round MED (ATK-7): an UNAUTHENTICATED request never consumes the anti-replay nonce budget" do
      secret = :crypto.strong_rand_bytes(32)
      :ok = LocalCredential.put(@host, %{kind: :shared_secret, secret: secret})

      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      # A garbage signature, but the SAME {kid, nonce} pair a legitimate
      # request would later present.
      header = Crypto.build_header("app-x", 1, ts, nonce, "00")

      bad_conn = conn(:get, "/fleet/health") |> put_req_header("authorization", header)
      bad_resp = Ingress.health(bad_conn, otp_app: @host)
      assert bad_resp.status == 401

      # THE PROOF: a request with the CORRECT signature over the SAME nonce
      # still succeeds — the forged attempt never wrote to NonceCache. Before
      # the fix, the forged request above would have consumed the nonce and
      # this second, genuinely valid request would incorrectly 401
      # (:replayed), a self-inflicted denial of service.
      input = Crypto.signing_input("GET", "/fleet/health", ts, nonce, Crypto.body_digest(""))
      sig = Crypto.sign_hmac(secret, input)
      good_header = Crypto.build_header("app-x", 1, ts, nonce, sig)

      good_conn = conn(:get, "/fleet/health") |> put_req_header("authorization", good_header)
      good_resp = Ingress.health(good_conn, otp_app: @host)
      assert good_resp.status == 200
    end

    defp signed_get(secret) do
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("GET", "/fleet/health", ts, nonce, Crypto.body_digest(""))
      sig = Crypto.sign_hmac(secret, input)
      header = Crypto.build_header("app-x", 1, ts, nonce, sig)

      conn(:get, "/fleet/health") |> put_req_header("authorization", header)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /fleet/heartbeat — cockpit side (RP-J-2, the load-bearing 204-empty proof)
  # ---------------------------------------------------------------------------

  describe "POST /fleet/heartbeat" do
    setup do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(
          @ns,
          %{app_slug: "hbhttp-#{System.unique_integer([:positive])}", display_name: "HBHTTP"},
          @admin
        )

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))
      %{app_id: app_id, priv: priv}
    end

    test "RP-J-2 GREEN: a valid heartbeat -> 204 No Content, EMPTY body", %{app_id: app_id, priv: priv} do
      conn = signed_heartbeat_conn(app_id, priv)
      resp = CockpitIngress.heartbeat(conn, namespace: @ns)

      assert resp.status == 204
      assert resp.resp_body == ""
    end

    test "RED: forged signature -> 401, empty body", %{app_id: app_id} do
      {_wrong_pub, wrong_priv} = Crypto.generate_ed25519_keypair()
      conn = signed_heartbeat_conn(app_id, wrong_priv)
      resp = CockpitIngress.heartbeat(conn, namespace: @ns)

      assert resp.status == 401
      assert resp.resp_body == ""
    end

    test "RED: an unknown kid -> 401, empty body, same shape as a forged one" do
      {_pub, priv} = Crypto.generate_ed25519_keypair()
      conn = signed_heartbeat_conn(Ash.UUID.generate(), priv)
      resp = CockpitIngress.heartbeat(conn, namespace: @ns)

      assert resp.status == 401
      assert resp.resp_body == ""
    end

    test "RP-J-13: over-limit is a byte-identical 429 for a KNOWN kid, GENUINELY VALID traffic only", %{
      app_id: app_id,
      priv: priv
    } do
      # The :fleet_heartbeat bucket is charged ONLY on a valid, stored
      # heartbeat (BLOCKER-1 fix) — so exhausting it requires genuinely valid
      # signed requests, never forged ones.
      {limit, _window} = Samen.Web.RateLimit.limit_for(:fleet_heartbeat)

      # ---------------------------------------------------------------------------------
      # ISSUE #36 — this arm was seed-dependent, and the dependence was NOT a shared bucket:
      # the key is `fleet_heartbeat:kid:<app_id>` on a per-test enrollment and `setup` above
      # already calls `RateLimit.reset/0`. What it shared was the WINDOW CLOCK.
      # `Hammer.ETS.FixWindow` counts against `div(now, window_ms)`, so all `limit + 1`
      # charges must land in ONE wall-clock window for ANY of them to be over limit. When a
      # 60s boundary fell inside this ~130ms loop the counter restarted mid-flight, nothing
      # exceeded the limit, and `over_limit` came back EMPTY. Whether the boundary fell there
      # depended on how long everything before this test took — the order/seed dependence.
      # Reproduced deterministically by parking the loop across a boundary: 123 requests,
      # 123 x 204, zero 429s, this exact assertion red.
      #
      # Fixed by construction — no sleep, no retry, no widened tolerance:
      #
      #   1. PIN THE WINDOW OPEN. The surface's window is scoped (config, restored on exit)
      #      to one wider than the epoch, so the window index is 0 before and after the loop
      #      and a mid-loop rollover is arithmetically impossible. Asserted below, both as
      #      the index itself and as before == after. The LIMIT is read from `limit_for/1`
      #      BEFORE the override and asserted unchanged after it; a wider window can only
      #      make the budget STRICTER, since what it removes is the refill that was letting
      #      over-limit traffic through.
      #
      #   2. OWN THE BUCKET, PROVABLY. The test plants exactly the prior traffic the old arm
      #      silently assumed away — another cockpit's kid driven PAST the limit inside this
      #      same window — and then asserts its OWN bucket is still below limit. That is the
      #      precondition control: every 429 below is charged by this test's own requests,
      #      and the per-kid key discipline (ADR-038 §6.2) is what makes it hold.
      # ---------------------------------------------------------------------------------
      original = Application.fetch_env(:samen_web, Samen.Web.RateLimit)
      base = case original do
               {:ok, config} -> config
               :error -> []
             end

      on_exit(fn ->
        case original do
          {:ok, config} -> Application.put_env(:samen_web, Samen.Web.RateLimit, config)
          :error -> Application.delete_env(:samen_web, Samen.Web.RateLimit)
        end

        Samen.Web.RateLimit.reset()
      end)

      pinned =
        base
        |> Keyword.get(:limits, %{})
        |> Map.put(:fleet_heartbeat, {limit, @window_pinned_open_ms})

      Application.put_env(:samen_web, Samen.Web.RateLimit, Keyword.put(base, :limits, pinned))

      assert Samen.Web.RateLimit.limit_for(:fleet_heartbeat) == {limit, @window_pinned_open_ms},
             "the pinned window must keep the SHIPPED limit — this test may not weaken it"

      window_index = fn -> div(System.system_time(:millisecond), @window_pinned_open_ms) end

      assert window_index.() == 0,
             "the pinned window must exceed the current epoch time, so that the fixed-window " <>
               "index cannot change while this test runs (issue #36's root cause)"

      index_before = window_index.()

      # PRIOR TRAFFIC, planted: another cockpit's kid PAST the limit, in this same window.
      for _ <- 1..(limit + 1) do
        Samen.Web.RateLimit.check(:fleet_heartbeat, :kid, @prior_traffic_kid)
      end

      assert Samen.Web.RateLimit.over_limit?(:fleet_heartbeat, :kid, @prior_traffic_kid),
             "the planted prior traffic did not drive its OWN bucket over limit, so the " <>
               "isolation control below would pass vacuously"

      # PRECONDITION CONTROL — the state the old arm silently assumed and never checked:
      # this test's own bucket is BELOW limit before this test issues a single request.
      refute Samen.Web.RateLimit.over_limit?(:fleet_heartbeat, :kid, app_id),
             "this app's own :fleet_heartbeat bucket was ALREADY over limit before the test " <>
               "sent anything — the 429s below would not be this test's own doing"

      responses =
        for _ <- 1..(limit + 3) do
          conn = signed_heartbeat_conn(app_id, priv, unique_nonce: true)
          CockpitIngress.heartbeat(conn, namespace: @ns)
        end

      assert window_index.() == index_before,
             "the fixed window rolled over mid-loop, so the counts below are split across " <>
               "two windows — the pinned window was supposed to make this impossible"

      over_limit = Enum.filter(responses, &(&1.status == 429))
      assert over_limit != []
      assert Enum.all?(over_limit, &(&1.resp_body == ""))

      # Exactly the budget was served and exactly the excess was refused — sharper than
      # `over_limit != []`, and only true when this test's own requests did all the charging.
      assert Enum.count(responses, &(&1.status == 204)) == limit
      assert length(over_limit) == 3

      # The planted traffic never mixed into this app's budget, in either direction.
      assert Samen.Web.RateLimit.over_limit?(:fleet_heartbeat, :kid, @prior_traffic_kid)
    end

    test "RP-J-13: an UNKNOWN kid can never reach 204, and its own (smaller) bad-sig bucket still 429s eventually" do
      {_pub, priv} = Crypto.generate_ed25519_keypair()
      unknown_kid = Ash.UUID.generate()

      # Unknown-kid traffic can NEVER charge :fleet_heartbeat (BLOCKER-1 fix —
      # it never reaches the {:ok, _} commit clause), so it is bounded by the
      # SEPARATE, much smaller :fleet_heartbeat_bad_sig budget instead.
      {limit, _window} = Samen.Web.RateLimit.limit_for(:fleet_heartbeat_bad_sig)

      responses =
        for _ <- 1..(limit + 3) do
          conn = signed_heartbeat_conn(unknown_kid, priv, unique_nonce: true)
          CockpitIngress.heartbeat(conn, namespace: @ns)
        end

      refute Enum.any?(responses, &(&1.status == 204))
      over_limit = Enum.filter(responses, &(&1.status == 429))
      assert over_limit != []
      assert Enum.all?(over_limit, &(&1.resp_body == ""))
    end

    test "BLOCKER-1 (§4.4a starvation, corrected): a signature-invalid flood PAST fleet_heartbeat's REAL limit does NOT prevent a subsequent VALID heartbeat, and raises :heartbeat_rejected",
         %{app_id: app_id, priv: priv} do
      {_wrong_pub, wrong_priv} = Crypto.generate_ed25519_keypair()

      # The regression-reproducing flood size: PAST :fleet_heartbeat's OWN
      # (real budget) limit, not the much-smaller bad-sig bucket's limit. The
      # pre-fix shipped test flooded only bad_sig_limit + 2 = 12 requests
      # against a fleet_heartbeat limit of 120 -- an order of magnitude below
      # the threshold that would have exposed the starvation bug. This test
      # floods fleet_heartbeat_limit + 1 forged-signature requests instead.
      {main_limit, _window} = Samen.Web.RateLimit.limit_for(:fleet_heartbeat)

      flood_responses =
        for _ <- 1..(main_limit + 1) do
          conn = signed_heartbeat_conn(app_id, wrong_priv, unique_nonce: true)
          CockpitIngress.heartbeat(conn, namespace: @ns)
        end

      # None of the flood responses is ever 204 -- every one of them was
      # rejected for cause (bad signature), never silently accepted.
      refute Enum.any?(flood_responses, &(&1.status == 204))
      assert Samen.Fleet.Attention.raised?(:heartbeat_rejected, app_id)

      # THE PROPERTY: the app's OWN valid heartbeat, sent immediately after a
      # flood sized to have exhausted the REAL budget if it had been charged,
      # STILL succeeds -- because bad-signature traffic never charges
      # :fleet_heartbeat at all (only the separate, much smaller
      # :fleet_heartbeat_bad_sig bucket, which the flood also long since
      # tripped -- asserted above via the attention entry).
      conn = signed_heartbeat_conn(app_id, priv, unique_nonce: true)
      resp = CockpitIngress.heartbeat(conn, namespace: @ns)
      assert resp.status == 204
      assert resp.resp_body == ""
    end

    test "L6 (Phase-6 EDGE-LOW, documented): a kid-holder flooding bad-sig heartbeats raises AT MOST ONE open :heartbeat_rejected entry -- never N growing entries -- and the starvation fix still holds",
         %{app_id: app_id, priv: priv} do
      {_wrong_pub, wrong_priv} = Crypto.generate_ed25519_keypair()
      {bad_sig_limit, _window} = Samen.Web.RateLimit.limit_for(:fleet_heartbeat_bad_sig)

      # A flood well past the bad-sig bucket's own (small) limit -- every
      # request AFTER the limit trips re-raises :heartbeat_rejected for the
      # SAME kid (handle_heartbeat_result/3's bad-sig clause calls
      # Attention.raise_entry/2 on every over-limit request, not just once).
      # An attacker holding only the victim's kid (not secret, per §4.4a) can
      # keep doing this indefinitely.
      responses =
        for _ <- 1..(bad_sig_limit + 15) do
          conn = signed_heartbeat_conn(app_id, wrong_priv, unique_nonce: true)
          CockpitIngress.heartbeat(conn, namespace: @ns)
        end

      refute Enum.any?(responses, &(&1.status == 204))
      assert Enum.any?(responses, &(&1.status == 429))

      # THE BOUND (documented, not fixed further -- see attention.ex's
      # raise_entry/3 comment): Samen.Fleet.Attention's ETS table is `:set`,
      # keyed on `{kind, key}`, so repeated raises for the SAME kid COALESCE
      # into exactly one entry, no matter how many bad-sig requests flooded in.
      entries_for_kid = Enum.filter(Samen.Fleet.Attention.list(:heartbeat_rejected), &(&1.key == app_id))
      assert length(entries_for_kid) == 1

      # A DIFFERENT kid's flood raises its OWN entry -- coalescing is per-key,
      # never a single shared/global entry that would misattribute one app's
      # flood to another (positive control: two entries exist in total, one
      # per distinct kid, still never N per kid).
      other_app_id = Ash.UUID.generate()

      for _ <- 1..(bad_sig_limit + 3) do
        conn = signed_heartbeat_conn(other_app_id, wrong_priv, unique_nonce: true)
        CockpitIngress.heartbeat(conn, namespace: @ns)
      end

      all_entries = Samen.Fleet.Attention.list(:heartbeat_rejected)
      assert length(Enum.filter(all_entries, &(&1.key == app_id))) == 1
      assert length(Enum.filter(all_entries, &(&1.key == other_app_id))) == 1

      # BLOCKER-1's starvation fix holds THROUGH the flood + the coalesced
      # noise: the victim's own genuine heartbeat still 204s.
      conn = signed_heartbeat_conn(app_id, priv, unique_nonce: true)
      resp = CockpitIngress.heartbeat(conn, namespace: @ns)
      assert resp.status == 204
      assert resp.resp_body == ""
    end

    defp signed_heartbeat_conn(app_id, priv, opts \\ []) do
      report = Samen.Fleet.Report.build(app_id: app_id)
      body = Samen.Fleet.Report.to_wire(report) |> Jason.encode!()
      ts = System.os_time(:second)

      nonce =
        if Keyword.get(opts, :unique_nonce, false),
          do: "n-#{System.unique_integer([:positive])}",
          else: Crypto.generate_nonce()

      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)
      header = Crypto.build_header(app_id, 1, ts, nonce, sig)

      conn(:post, "/fleet/heartbeat", body)
      |> put_req_header("authorization", header)
      |> assign(:raw_webhook_body, body)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /fleet/enroll — cockpit side
  # ---------------------------------------------------------------------------

  describe "POST /fleet/enroll" do
    test "GREEN: a valid token -> 200 + app_id" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(
          @ns,
          %{app_slug: "enrhttp-#{System.unique_integer([:positive])}", display_name: "EnrHttp"},
          @admin
        )

      {pub, _priv} = Crypto.generate_ed25519_keypair()

      conn =
        conn(:post, "/fleet/enroll", %{})
        |> Map.put(:body_params, %{"token" => raw_token, "public_key" => Base.encode64(pub)})

      resp = CockpitIngress.enroll(conn, namespace: @ns)
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert is_binary(body["app_id"])
    end

    test "RED: an invalid token -> 401" do
      conn =
        conn(:post, "/fleet/enroll", %{})
        |> Map.put(:body_params, %{"token" => "not-a-real-token", "public_key" => "pub"})

      resp = CockpitIngress.enroll(conn, namespace: @ns)
      assert resp.status == 401
    end
  end
end
