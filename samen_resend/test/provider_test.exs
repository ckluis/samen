defmodule SamenResend.ProviderTest do
  @moduledoc """
  `SamenResend.Provider`-specific coverage beyond the shared conformance
  harness: the layered fail-honest gates, real Svix signature verification
  (bad-sig red + control), timestamp-tolerance replay protection, multiple
  signature candidates (secret rotation), and the T95 allowlist-redaction
  red+control pair (ADR-038 §5.4 / INV-1).
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Message
  alias SamenResend.{Provider, SvixSignature}

  defp msg do
    %Message{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil}
  end

  defp base_config do
    %{api_key: "fixture-key", from: "sender@example.test"}
  end

  @secret "whsec_" <> Base.encode64("provider-test-fixture-secret-32bytes!!")

  defp sign(svix_id, timestamp, body, secret \\ @secret) do
    signed_content = svix_id <> "." <> timestamp <> "." <> body
    {:ok, key} = secret |> String.trim_leading("whsec_") |> Base.decode64()
    sig = :crypto.mac(:hmac, :sha256, key, signed_content) |> Base.encode64()

    [
      {"svix-id", svix_id},
      {"svix-timestamp", timestamp},
      {"svix-signature", "v1," <> sig}
    ]
  end

  defp now_ts, do: System.system_time(:second) |> Integer.to_string()

  defp bounce_body do
    Jason.encode!(%{
      "type" => "email.bounced",
      "created_at" => "2026-07-22T00:00:00.000Z",
      "data" => %{"email_id" => "resend-msg-1", "to" => ["bounced@example.test"]}
    })
  end

  # ---------------------------------------------------------------------------
  # configured?/1

  describe "configured?/1" do
    test "false with no keys" do
      refute Provider.configured?(%{})
    end

    test "false missing either required key" do
      base = base_config()

      for key <- Map.keys(base) do
        refute Provider.configured?(Map.delete(base, key)),
               "configured?/1 must be false when #{inspect(key)} is missing"
      end
    end

    test "true with both present" do
      assert Provider.configured?(base_config())
    end
  end

  # ---------------------------------------------------------------------------
  # deliver/2 — layered fail-honest gates

  describe "deliver/2 fail-honest layering" do
    test "unconfigured (no creds) refuses :not_configured" do
      assert {:error, :not_configured} = Provider.deliver(msg(), %{})
    end

    test "configured but no :resolve_recipient wired refuses :not_implemented (operator TODO, never a fake ok)" do
      assert {:error, :not_implemented} = Provider.deliver(msg(), base_config())
    end

    test "resolve_recipient error is surfaced as-is" do
      config = Map.put(base_config(), :resolve_recipient, fn _ -> {:error, :vault_locked} end)
      assert {:error, :vault_locked} = Provider.deliver(msg(), config)
    end

    test "an invalid resolve_recipient result is surfaced honestly, never {:ok, _}" do
      config = Map.put(base_config(), :resolve_recipient, fn _ -> :bogus end)
      assert {:error, {:invalid_resolve_recipient_result, :bogus}} = Provider.deliver(msg(), config)
    end

    test "configured + resolve_recipient + transport genuinely dispatches (anti-tautology)" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn request ->
          assert request.to_email == "to@example.test"
          {:ok, %{status: 200, body: %{"id" => "real-id-1"}}}
        end)

      assert {:ok, %{provider_message_id: "real-id-1"}} = Provider.deliver(msg(), config)
    end

    test "a Resend-side error response is surfaced, never {:ok, _}" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn _req ->
          {:ok, %{status: 422, body: %{"message" => "Invalid `from` field", "name" => "validation_error"}}}
        end)

      assert {:error, {:resend_error, 422, "validation_error", "Invalid `from` field"}} =
               Provider.deliver(msg(), config)
    end

    test "a transport-level failure (network) is surfaced, never {:ok, _}" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn _req -> {:error, :timeout} end)

      assert {:error, :timeout} = Provider.deliver(msg(), config)
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3 — the cheap layered gates (no crypto involved)

  describe "verify_and_parse_event/3 fail-honest layering" do
    test "unconfigured refuses :not_configured" do
      assert {:error, :not_configured} = Provider.verify_and_parse_event("{}", [], %{})
    end

    test "configured but no :webhook_secret wired refuses :not_implemented (capability-specific gate)" do
      assert {:error, :not_implemented} = Provider.verify_and_parse_event("{}", [], base_config())
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3 — real Svix signature verification

  describe "verify_and_parse_event/3 — real Svix HMAC-SHA256 signature verification" do
    defp config_with_secret, do: Map.put(base_config(), :webhook_secret, @secret)

    test "a validly-signed Bounce webhook parses to :bounce" do
      body = bounce_body()
      headers = sign("msg-1", now_ts(), body)

      assert {:ok, event} = Provider.verify_and_parse_event(body, headers, config_with_secret())
      assert event.kind == :bounce
      assert event.provider == :resend
      assert event.provider_message_id == "resend-msg-1"
      assert event.event_id == "msg-1"
    end

    test "RED: a tampered svix-signature is rejected, vs the CONTROL of the identical valid body" do
      body = bounce_body()
      headers = sign("msg-2", now_ts(), body)

      # CONTROL — the real signature verifies.
      assert {:ok, _} = Provider.verify_and_parse_event(body, headers, config_with_secret())

      # RED — same body, same id/timestamp, signature value corrupted.
      tampered_headers =
        Enum.map(headers, fn
          {"svix-signature", _} -> {"svix-signature", "v1,dGhpcyBpcyBub3QgYSByZWFsIHNpZ25hdHVyZQ=="}
          other -> other
        end)

      assert {:error, :invalid_signature} =
               Provider.verify_and_parse_event(body, tampered_headers, config_with_secret())
    end

    test "RED: a tampered BODY (valid headers for the original body) is rejected" do
      body = bounce_body()
      headers = sign("msg-3", now_ts(), body)
      tampered_body = String.replace(body, "resend-msg-1", "resend-msg-EVIL")

      assert {:error, :invalid_signature} =
               Provider.verify_and_parse_event(tampered_body, headers, config_with_secret())
    end

    test "RED: signed with the WRONG secret is rejected" do
      body = bounce_body()
      wrong_secret = "whsec_" <> Base.encode64("a-totally-different-secret-32byte")
      headers = sign("msg-4", now_ts(), body, wrong_secret)

      assert {:error, :invalid_signature} =
               Provider.verify_and_parse_event(body, headers, config_with_secret())
    end

    test "missing svix headers are rejected (fail closed, never raises)" do
      body = bounce_body()
      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(body, [], config_with_secret())
    end

    test "a malformed (non-JSON) body with a validly-signed envelope is :malformed" do
      body = "not actually json"
      headers = sign("msg-5", now_ts(), body)

      assert {:error, :malformed} = Provider.verify_and_parse_event(body, headers, config_with_secret())
    end

    test "unknown notification types map to :unhandled (stored replay-safe, not dispatched)" do
      body = Jason.encode!(%{"type" => "email.delivery_delayed", "data" => %{"email_id" => "m1"}})
      headers = sign("msg-6", now_ts(), body)

      assert {:ok, %{kind: :unhandled}} = Provider.verify_and_parse_event(body, headers, config_with_secret())
    end

    test "multiple space-separated signature candidates (secret rotation): any match is accepted" do
      body = bounce_body()
      timestamp = now_ts()
      real_headers = sign("msg-7", timestamp, body)
      [{_, svix_id}, {_, ^timestamp}, {"svix-signature", real_sig}] = real_headers

      rotated_headers = [
        {"svix-id", svix_id},
        {"svix-timestamp", timestamp},
        {"svix-signature", "v1,dGhpcyBpcyBhIGRlY295IHNpZ25hdHVyZQ== " <> real_sig}
      ]

      assert {:ok, %{kind: :bounce}} = Provider.verify_and_parse_event(body, rotated_headers, config_with_secret())
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3 — timestamp-tolerance replay protection

  describe "verify_and_parse_event/3 — timestamp-tolerance replay protection" do
    test "RED: a svix-timestamp far outside the tolerance window is rejected (stale, even with a valid signature)" do
      body = bounce_body()
      stale_ts = (System.system_time(:second) - 10_000) |> Integer.to_string()
      headers = sign("msg-stale-1", stale_ts, body)

      assert {:error, :stale_timestamp} =
               Provider.verify_and_parse_event(body, headers, config_with_secret())
    end

    test "CONTROL: the SAME payload with a fresh timestamp is accepted" do
      body = bounce_body()
      headers = sign("msg-stale-2", now_ts(), body)

      assert {:ok, _} = Provider.verify_and_parse_event(body, headers, config_with_secret())
    end

    test "a custom :tolerance_seconds config narrows the window" do
      body = bounce_body()
      # 100 seconds old, with a 50s tolerance configured -> rejected.
      old_ts = (System.system_time(:second) - 100) |> Integer.to_string()
      headers = sign("msg-tol-1", old_ts, body)

      config = config_with_secret() |> Map.put(:tolerance_seconds, 50)
      assert {:error, :stale_timestamp} = Provider.verify_and_parse_event(body, headers, config)
    end

    test "SvixSignature.verify/4 rejects a future timestamp outside tolerance too (bidirectional skew guard)" do
      body = bounce_body()
      future_ts = (System.system_time(:second) + 10_000) |> Integer.to_string()
      headers = sign("msg-future-1", future_ts, body)

      assert {:error, :stale_timestamp} = SvixSignature.verify(body, headers, @secret)
    end
  end

  # ---------------------------------------------------------------------------
  # capabilities/0 — no :inbound (ADR-038 §4.5 adapter split: "samen_resend ... no inbound")

  test "capabilities/0 declares deliverability_webhooks + tracking, NOT inbound" do
    assert Enum.sort(Provider.capabilities()) == Enum.sort([:deliverability_webhooks, :tracking])
  end

  test "parse_inbound/3 always refuses :not_implemented (undeclared capability, honest `use` default)" do
    assert {:error, :not_implemented} = Provider.parse_inbound("{}", [], base_config())
    assert {:error, :not_implemented} = Provider.parse_inbound("{}", [], %{})
  end

  # ---------------------------------------------------------------------------
  # redact_payload/1 — ships as an ALLOWLIST from the start (T95; mirrors the
  # T24/T30 denylist->allowlist hardening line samen_postmark/samen_stripe
  # had to retrofit, and the from-day-one allowlist samen_ses/T94 shipped —
  # see the Provider moduledoc for why Resend's nested real payload shape
  # makes the rule bind hard here too.

  describe "redact_payload/1" do
    test "strips a flat top-level PII field, retains a safe top-level field" do
      payload = %{"type" => "email.bounced", "someTopLevelEmail" => "person@example.test"}
      redacted = Provider.redact_payload(payload)

      assert redacted["type"] == "email.bounced"
      refute Map.has_key?(redacted, "someTopLevelEmail")
    end

    test "RED: PII under an unenumerated NESTED field never survives redaction (control: safe field survives)" do
      # `data` is the REAL Resend nested container; `extraDebugInfo` is an
      # INVENTED field no allowlist enumerates — the same free-form-PII-
      # container risk `Metadata`/`metadata` posed for samen_postmark/
      # samen_stripe, just standing in for "any future/unknown nested field".
      novel_pii_ssn = "123-45-6789"

      payload = %{
        "type" => "email.bounced",
        "data" => %{"to" => ["leak@example.test"], "subject" => "Hi Jane Doe"},
        "extraDebugInfo" => %{"customerSsn" => novel_pii_ssn}
      }

      redacted = Provider.redact_payload(payload)
      serialized = Jason.encode!(redacted)

      refute serialized =~ novel_pii_ssn,
             "PII under an unenumerated nested key must not survive redaction"

      refute serialized =~ "leak@example.test"
      refute Map.has_key?(redacted, "data")
      refute Map.has_key?(redacted, "extraDebugInfo")

      # CONTROL: redaction is surgical, not a wipe — the safe top-level field survives.
      assert redacted["type"] == "email.bounced"
    end

    test "an allowlisted key whose VALUE is a nested map is dropped too (not assumed safe by name)" do
      payload = %{
        "type" => %{"unexpected" => "nested-shape", "email" => "sneaky@example.test"},
        "created_at" => "2026-07-22T00:00:00.000Z"
      }

      redacted = Provider.redact_payload(payload)

      refute Map.has_key?(redacted, "type"),
             "an allowlisted key with a non-scalar value must still be dropped"

      assert redacted["created_at"] == "2026-07-22T00:00:00.000Z"
    end
  end
end
