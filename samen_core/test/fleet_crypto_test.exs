defmodule Samen.Fleet.CryptoTest do
  use ExUnit.Case, async: true

  alias Samen.Fleet.Crypto

  describe "signing input + header round-trip" do
    test "build_header/parse_header round-trips" do
      header = Crypto.build_header("app-1", 1, 1_700_000_000, "nonce123", "deadbeef")
      assert {:ok, %{kid: "app-1", v: 1, ts: 1_700_000_000, nonce: "nonce123", sig: "deadbeef"}} =
               Crypto.parse_header(header)
    end

    test "a malformed header is rejected, never raises" do
      assert {:error, :malformed_header} = Crypto.parse_header("garbage")
      assert {:error, :malformed_header} = Crypto.parse_header("Samen-Fleet-v1 kid=x")
    end
  end

  describe "mode A — HMAC (RP-J-1 groundwork)" do
    test "GREEN: correct secret verifies" do
      secret = :crypto.strong_rand_bytes(32)
      input = Crypto.signing_input("GET", "/fleet/health", 1_700_000_000, "n1", Crypto.body_digest(""))
      sig = Crypto.sign_hmac(secret, input)
      assert Crypto.verify_hmac(secret, input, sig)
    end

    test "RED: wrong secret fails, with a positive control on the right one" do
      secret = :crypto.strong_rand_bytes(32)
      wrong = :crypto.strong_rand_bytes(32)
      input = Crypto.signing_input("GET", "/fleet/health", 1_700_000_000, "n1", Crypto.body_digest(""))
      sig = Crypto.sign_hmac(secret, input)

      refute Crypto.verify_hmac(wrong, input, sig)
      assert Crypto.verify_hmac(secret, input, sig)
    end

    test "dummy_verify_hmac/1 always returns false (the unknown-kid oracle mitigation)" do
      input = Crypto.signing_input("GET", "/fleet/health", 1_700_000_000, "n1", Crypto.body_digest(""))
      refute Crypto.dummy_verify_hmac(input)
    end

    test "secure_compare/2 rejects a length mismatch and a content mismatch" do
      refute Crypto.secure_compare("abc", "abcd")
      refute Crypto.secure_compare("abc", "abd")
      assert Crypto.secure_compare("abc", "abc")
    end
  end

  describe "mode B — Ed25519" do
    test "GREEN: correct keypair verifies" do
      {pub, priv} = Crypto.generate_ed25519_keypair()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", 1_700_000_000, "n2", Crypto.body_digest("{}"))
      sig = Crypto.sign_ed25519(priv, input)
      assert Crypto.verify_ed25519(pub, input, sig)
    end

    test "RED: wrong public key fails, with a positive control on the right one" do
      {pub, priv} = Crypto.generate_ed25519_keypair()
      {wrong_pub, _} = Crypto.generate_ed25519_keypair()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", 1_700_000_000, "n2", Crypto.body_digest("{}"))
      sig = Crypto.sign_ed25519(priv, input)

      refute Crypto.verify_ed25519(wrong_pub, input, sig)
      assert Crypto.verify_ed25519(pub, input, sig)
    end

    test "a malformed signature never raises, just fails" do
      {pub, _priv} = Crypto.generate_ed25519_keypair()
      refute Crypto.verify_ed25519(pub, "input", "not-a-real-signature")
    end

    test "dummy_verify_ed25519/1 always returns false" do
      input = Crypto.signing_input("POST", "/fleet/heartbeat", 1_700_000_000, "n2", Crypto.body_digest("{}"))
      refute Crypto.dummy_verify_ed25519(input)
    end
  end

  describe "replay-bound timestamp (§4.4)" do
    test "fresh timestamp passes, stale one fails" do
      now = System.os_time(:second)
      assert Crypto.fresh_timestamp?(now)
      refute Crypto.fresh_timestamp?(now - 301)
      refute Crypto.fresh_timestamp?(now + 301)
    end
  end
end
