defmodule Driftwood.FleetWireTest do
  @moduledoc """
  T82 fix round — ADR-044 §9.3 row (a), the genuine two-vertical proof (was an
  undisclosed scope cut): "driftwood AND pawchart each mount
  samen_fleet_routes(), build a report from their own substrate, and
  GET /fleet/health returns a schema-valid, correctly-signed FleetReport for
  each ... two different domain shapes (freight, veterinary) through one
  wire." `samen_fleet_routes(otp_app: :driftwood)` is mounted in
  `driftwood_web/router.ex`; this proves it end to end at the Plug layer
  (no full Phoenix server needed — the same `Plug.Test.conn/2` +
  direct-controller-call shape `samen_web`'s own fleet ingress suite uses).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Fleet.{Crypto, LocalCredential}
  alias Samen.Web.Fleet.Ingress

  setup do
    LocalCredential.Agent.reset()
    :ok
  end

  test "GET /fleet/health returns a schema-valid, correctly-signed FleetReport (mode A)" do
    secret = :crypto.strong_rand_bytes(32)
    :ok = LocalCredential.put(:driftwood, %{kind: :shared_secret, secret: secret})

    ts = System.os_time(:second)
    nonce = Crypto.generate_nonce()
    input = Crypto.signing_input("GET", "/fleet/health", ts, nonce, Crypto.body_digest(""))
    sig = Crypto.sign_hmac(secret, input)
    header = Crypto.build_header("cockpit", 1, ts, nonce, sig)

    conn =
      conn(:get, "/fleet/health")
      |> put_req_header("authorization", header)
      |> Ingress.health(otp_app: :driftwood)

    assert conn.status == 200
    payload = Jason.decode!(conn.resp_body)
    assert :ok = Samen.Fleet.Report.Schema.validate(payload)
    # This is the FREIGHT domain shape — a real vertical, not a fixture.
    assert payload["app_id"]
  end

  test "RED (control): a wrong secret is rejected -> 401, empty body" do
    secret = :crypto.strong_rand_bytes(32)
    :ok = LocalCredential.put(:driftwood, %{kind: :shared_secret, secret: secret})

    wrong = :crypto.strong_rand_bytes(32)
    ts = System.os_time(:second)
    nonce = Crypto.generate_nonce()
    input = Crypto.signing_input("GET", "/fleet/health", ts, nonce, Crypto.body_digest(""))
    sig = Crypto.sign_hmac(wrong, input)
    header = Crypto.build_header("cockpit", 1, ts, nonce, sig)

    conn =
      conn(:get, "/fleet/health")
      |> put_req_header("authorization", header)
      |> Ingress.health(otp_app: :driftwood)

    assert conn.status == 401
    assert conn.resp_body == ""
  end

  test "zero config: no fleet credential configured -> 503, never a fabricated 200" do
    conn = conn(:get, "/fleet/health") |> Ingress.health(otp_app: :driftwood)
    assert conn.status == 503
    assert conn.resp_body == ""
  end
end
