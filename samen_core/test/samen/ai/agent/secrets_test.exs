defmodule Samen.AI.Agent.SecretsTest do
  @moduledoc """
  T184 — the secrets-redaction lane's own contract (unit floor), distinct from `pii_*`
  (ADR-047 §4.3b, PROPOSED). Mirrors `Samen.AI.Agent.IngressTest`'s discipline: every red
  pairs with a positive control, and non-reversibility is proven by exhibiting a collision,
  never asserted.
  """
  use ExUnit.Case, async: true

  alias Samen.AI.Agent.Secrets

  describe "known vendor-shaped prefixes redact" do
    test "AWS access key id" do
      assert redacted?("aws_access_key_id=AKIAIOSFODNN7EXAMPLE")
    end

    test "AWS STS temporary session key id" do
      assert redacted?("temp key ASIAABCDEFGHIJKLMNOP in the log line")
    end

    test "GitHub classic personal access token" do
      assert redacted?("token: ghp_" <> String.duplicate("a", 36))
    end

    test "GitHub fine-grained personal access token" do
      assert redacted?("github_pat_" <> String.duplicate("a", 30))
    end

    test "Slack bot token" do
      assert redacted?("xoxb-111111111111-222222222222-abcdefghijklmnopqrstuvwx")
    end

    test "Stripe live secret key" do
      assert redacted?("sk_live_" <> String.duplicate("a", 24))
    end

    test "generic sk- bearer-style secret key" do
      assert redacted?("sk-" <> String.duplicate("a", 30))
    end

    test "npm publish token" do
      assert redacted?("npm_" <> String.duplicate("a", 36))
    end

    test "Google API key" do
      assert redacted?("AIza" <> String.duplicate("a", 35))
    end

    test "PEM private-key header" do
      assert redacted?("-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----")
    end

    test "a JWT" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
      assert redacted?(jwt)
    end

    test "an Authorization Bearer header value" do
      assert redacted?("Authorization: Bearer " <> String.duplicate("a", 30))
    end

    test "a Postgres connection string carrying embedded credentials" do
      assert redacted?("postgres://appuser:s3cr3t-pw@db.internal:5432/prod")
    end

    test "a MongoDB SRV connection string carrying embedded credentials" do
      assert redacted?("mongodb+srv://svc:hunter2@cluster0.example.mongodb.net/app")
    end

    test "POSITIVE CONTROL: a bare connection string with NO embedded credential passes through" do
      value = "postgres://db.internal:5432/prod"
      assert Secrets.redact(value) == value
    end
  end

  describe "the fail-closed generic labeled fallback: unrecognized-but-secret-shaped still redacts" do
    test "a labeled api_key with NO known vendor prefix redacts" do
      assert redacted?("internal_service api_key=zzqq11837462meliorplatformvalue")
    end

    test "a labeled secret_key with NO known vendor prefix redacts" do
      assert redacted?(~s(secret_key: "n0tAKnownVendorFormatButStillASecret123"))
    end

    test "a labeled password redacts" do
      assert redacted?("password=Tr0ub4dor&3xtraLongEnough")
    end

    test "a labeled client_secret redacts" do
      assert redacted?("client_secret=abcXYZ0129384756LongEnoughValue")
    end
  end

  describe "false-positive guard: ordinary business data is NOT secret-shaped" do
    test "a UUID passes through untouched" do
      value = "record_id: 123e4567-e89b-12d3-a456-426614174000"
      assert Secrets.redact(value) == value
    end

    test "plain business text passes through untouched" do
      value = "Pallet 12 arrived at Acme Freight; the driver signed for record 44."
      assert Secrets.redact(value) == value
    end

    test "a bare word 'password' with no assigned value passes through untouched" do
      value = "please reset your password before Friday"
      assert Secrets.redact(value) == value
    end

    test "a short/trivial value after a secret-shaped label is NOT flagged (below the length floor)" do
      value = "api_key=abc"
      assert Secrets.redact(value) == value
    end
  end

  describe "NOT REVERSIBLE, proven by collision" do
    test "two DIFFERENT vendor secrets redact to the SAME marker" do
      aws = Secrets.redact("AKIAIOSFODNN7EXAMPLE")
      gh = Secrets.redact("ghp_" <> String.duplicate("b", 36))
      assert aws == gh
      assert aws == Secrets.marker()
    end

    test "a vendor secret and a generic labeled secret redact to the SAME marker" do
      vendor = Secrets.redact("sk_live_" <> String.duplicate("c", 24))
      generic = Secrets.redact("api_key=unrecognizedButLongEnoughValue123")
      assert vendor == generic
    end

    test "idempotent: a second pass changes nothing" do
      for value <- [
            "AKIAIOSFODNN7EXAMPLE",
            "api_key=unrecognizedButLongEnoughValue123",
            "Pallet 12 arrived at Acme Freight."
          ] do
        once = Secrets.redact(value)
        assert Secrets.redact(once) == once
      end
    end
  end

  describe "total on binaries, never raises" do
    test "empty string" do
      assert Secrets.redact("") == ""
    end

    test "invalid-UTF-8-adjacent-but-still-a-binary content does not raise" do
      # Secrets.redact/1 is a plain regex pass over a binary; it must not raise even on a
      # binary that is not valid UTF-8 (Ingress.sanitize/1, run AFTER this in the call sites,
      # is the module responsible for refusing invalid UTF-8 wholesale).
      assert is_binary(Secrets.redact(<<0xFF, 0xFE, "ok">>))
    end
  end

  defp redacted?(value) do
    result = Secrets.redact(value)
    result != value and result =~ Secrets.marker()
  end
end
