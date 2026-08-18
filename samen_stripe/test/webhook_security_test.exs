defmodule SamenStripe.WebhookSecurityTest do
  @moduledoc """
  T19/B9 — the Stripe adapter's webhook SIGNATURE-VERIFICATION path, proven for real
  (ADR-038 §5.2 / §7.3 signed-webhook simulator, billing side).

  `SamenStripe.Provider.verify_and_parse_event/3` verifies a Stripe-shape signature by
  delegating to the vendor-generic core primitive `Samen.Webhook.Signer` (ADR-038 §5 —
  "delegating verification primitives"), then maps the vendor event to a normalized
  `Samen.Billing.ProviderEvent` with the payload ALREADY redacted (INV-1, §5.4).

  This is the KEYLESS lane-0 proof (§7.1): the test constructs the provider-correct
  `Stripe-Signature` header over a fixture body with a KNOWN test secret via
  `Samen.Webhook.Signer.sign/3` (Stripe's `t=<ts>,v1=HMAC-SHA256("<ts>.<body>")`
  scheme — byte-identical to what the core Signer produces), so the FULL verification
  code path runs with no network and no real Stripe credential.

  Anti-tautology throughout: every red case (bad sig / tampered body / stale ts /
  missing header) is paired with the green control that would be broken by a
  mask-everything or accept-everything implementation.
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.ProviderEvent
  alias Samen.Webhook.Signer
  alias SamenStripe.Provider

  @secret "whsec_test_5f3a9c2b1d4e6f8a0c2e4b6d8f0a1c3e"
  @config %{secret_key: "sk_test_123", webhook_secret: @secret}

  # A realistic Stripe `checkout.session.completed` event body carrying PII in the
  # object (customer_email / customer_details) that redaction MUST strip.
  @pii_email "buyer-jane@example.com"
  @pii_name "Jane Buyer"

  defp event_body(overrides \\ %{}) do
    base = %{
      "id" => "evt_test_#{System.unique_integer([:positive])}",
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "cs_test_abc123",
          "customer" => "cus_test_xyz",
          "subscription" => "sub_test_123",
          "customer_email" => @pii_email,
          "customer_details" => %{"email" => @pii_email, "name" => @pii_name},
          "amount_total" => 4900,
          "currency" => "usd"
        }
      }
    }

    Map.merge(base, overrides) |> Jason.encode!()
  end

  # Build the Stripe-Signature header over `body` at `ts` using the core Signer (the
  # signed-webhook simulator). A DIFFERENT secret yields an invalid signature.
  defp signed_headers(body, opts \\ []) do
    ts = Keyword.get(opts, :ts, System.os_time(:second))
    secret = Keyword.get(opts, :secret, @secret)
    [{"stripe-signature", Signer.sign(body, ts, secret)}, {"content-type", "application/json"}]
  end

  # ---------------------------------------------------------------------------
  # GREEN control (anti-tautology partner for every red case below)
  # ---------------------------------------------------------------------------

  describe "valid signature (green control)" do
    test "a correctly-signed body parses to a normalized ProviderEvent" do
      body = event_body()
      assert {:ok, %ProviderEvent{} = event} = Provider.verify_and_parse_event(body, signed_headers(body), @config)

      assert event.provider == :stripe
      assert event.kind == :checkout_completed
      assert String.starts_with?(event.event_id, "evt_test_")
      assert %DateTime{} = event.occurred_at
      assert event.provider_refs[:customer_id] == "cus_test_xyz"
      assert event.provider_refs[:subscription_id] == "sub_test_123"
    end

    test "maps each known vendor event type to its bounded kind, unknown -> :unhandled" do
      cases = [
        {"customer.subscription.deleted", :subscription_deleted},
        {"invoice.payment_failed", :invoice_payment_failed},
        {"payment_method.attached", :payment_method_attached},
        {"some.unmapped.event", :unhandled}
      ]

      for {type, expected_kind} <- cases do
        body = event_body(%{"type" => type})
        assert {:ok, event} = Provider.verify_and_parse_event(body, signed_headers(body), @config)
        assert event.kind == expected_kind, "#{type} should map to #{expected_kind}"
      end
    end

    test "the parsed payload is redacted — no plaintext email/name survives (INV-1, §5.4)" do
      body = event_body()
      # Sanity: the raw body genuinely contains the PII we expect to be stripped.
      assert body =~ @pii_email
      assert body =~ @pii_name

      assert {:ok, event} = Provider.verify_and_parse_event(body, signed_headers(body), @config)

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @pii_email, "redacted payload must not contain the customer email"
      refute serialized =~ @pii_name, "redacted payload must not contain the customer name"
      # Positive control: non-PII object fields ARE retained (redaction is surgical).
      assert event.payload["amount_total"] == 4900
      assert event.payload["id"] == "cs_test_abc123"
    end
  end

  # ---------------------------------------------------------------------------
  # T24 hardening — ALLOWLIST redaction of free-form `metadata.*` (ADR-038
  # §5.4 / INV-1). Dunning consumes `invoice.payment_failed` webhooks, which
  # carry customer/invoice data — a merchant's Stripe `metadata` bag is
  # free-form and can carry PII under ANY key name a plain denylist would
  # never enumerate. This is the red test the T19 verifier named + its
  # positive control.
  # ---------------------------------------------------------------------------

  describe "T24: metadata.* PII never survives redaction (red) + a whitelisted field survives (control)" do
    test "an invoice.payment_failed event with PII under an UNENUMERATED metadata key is redacted" do
      # `account_holder_ssn` is NOT one of the ~8 literal keys the OLD denylist
      # enumerated (`email name phone address billing_details shipping
      # receipt_email customer_email`) — the exact shape of free-form Stripe
      # `metadata` a merchant can populate with ANYTHING. A denylist can only
      # strip keys it already knows about; this is the gap the allowlist closes.
      novel_pii_ssn = "123-45-6789"
      # `customer_email` WAS one of the old denylist's literal keys — kept here
      # as a control proving the fix is not narrower than before, not a
      # regression on the one case the denylist used to catch.
      enumerated_pii_email = "hidden-in-metadata@example.com"

      body =
        Jason.encode!(%{
          "id" => "evt_test_#{System.unique_integer([:positive])}",
          "type" => "invoice.payment_failed",
          "created" => System.os_time(:second),
          "data" => %{
            "object" => %{
              "id" => "in_test_dunning_1",
              "object" => "invoice",
              "customer" => "cus_test_xyz",
              "subscription" => "sub_test_123",
              "amount_due" => 4900,
              "currency" => "usd",
              "attempt_count" => 1,
              # A free-form Stripe metadata bag — the org can stash ANYTHING
              # under ANY key here, including a key no denylist enumerates.
              "metadata" => %{
                "account_holder_ssn" => novel_pii_ssn,
                "customer_email" => enumerated_pii_email,
                "internal_note" => "VIP account — do not lose"
              }
            }
          }
        })

      # Sanity: the raw body genuinely contains the PII we expect stripped.
      assert body =~ novel_pii_ssn
      assert body =~ enumerated_pii_email

      assert {:ok, event} = Provider.verify_and_parse_event(body, signed_headers(body), @config)
      assert event.kind == :invoice_payment_failed

      serialized = Jason.encode!(event.payload)

      refute serialized =~ novel_pii_ssn,
             "PII under a key NO denylist ever enumerated must not survive redaction"

      refute serialized =~ enumerated_pii_email,
             "PII under a key the OLD denylist happened to enumerate must still not survive"

      refute Map.has_key?(event.payload, "metadata"),
             "metadata is dropped wholesale — even its non-PII sibling keys never survive"

      # Positive control: genuinely whitelisted TOP-LEVEL fields still survive
      # (redaction is surgical, not a wipe-everything no-op) — including the
      # dunning retry-schedule field this same webhook carries.
      assert event.payload["id"] == "in_test_dunning_1"
      assert event.payload["amount_due"] == 4900
      assert event.payload["attempt_count"] == 1
      assert event.payload["customer"] == "cus_test_xyz"
    end
  end

  # ---------------------------------------------------------------------------
  # RED paths — attacker-first
  # ---------------------------------------------------------------------------

  describe "signature forgery / tampering (red) -> refused, parses NOTHING" do
    test "a tampered body (signature computed over the original) is invalid_signature" do
      original = event_body()
      headers = signed_headers(original)
      tampered = String.replace(original, "4900", "1")

      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(tampered, headers, @config)
    end

    test "a signature made with the WRONG secret is invalid_signature" do
      body = event_body()
      headers = signed_headers(body, secret: "whsec_attacker_key")

      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(body, headers, @config)
    end

    test "a stripped signature header is malformed (fail-closed, no default-accept)" do
      body = event_body()
      headers = [{"content-type", "application/json"}]

      assert {:error, :malformed} = Provider.verify_and_parse_event(body, headers, @config)
    end
  end

  describe "replay window (red)" do
    test "a valid signature outside the tolerance window is stale_timestamp (anti-replay)" do
      body = event_body()
      old_ts = System.os_time(:second) - 3600
      headers = signed_headers(body, ts: old_ts)

      assert {:error, :stale_timestamp} = Provider.verify_and_parse_event(body, headers, @config)
    end
  end

  describe "fail-honest gate (red)" do
    test "unconfigured provider refuses verification (never attempts crypto)" do
      body = event_body()
      assert {:error, :not_configured} = Provider.verify_and_parse_event(body, signed_headers(body), %{})
    end

    test "configured-but-no-webhook-secret is the honest :not_implemented, never a fake accept" do
      body = event_body()
      assert {:error, :not_implemented} =
               Provider.verify_and_parse_event(body, signed_headers(body), %{secret_key: "sk_test_123"})
    end
  end
end
