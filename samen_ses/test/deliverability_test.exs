defmodule SamenSes.DeliverabilityTest do
  @moduledoc """
  C4 (T30) — SES/SNS REFERENCE fixtures for every deliverability event kind
  (ADR-038 §4.4; T94 handoff done-criterion 2). Hermetic, ADAPTER-side-only:
  proves `SamenSes.Provider.verify_and_parse_event/3` correctly (a) verifies
  the real SNS envelope RSA signature, (b) maps each real SES `eventType` to
  the bounded, samen-owned `ProviderEvent.kind` enum, (c) extracts
  `provider_message_id` from `mail.messageId` — the token-blind join key
  ADR-038 §4.1 requires — and (d) redacts PII (allowlist).

  `samen_core` is vendor-free (INV-4) and therefore CANNOT depend on this
  package, so — exactly as `samen_postmark`/T27 established for the SAME
  split — the DOMAIN-side half of C4 (matching a `ProviderEvent` to a send
  receipt, writing `Samen.Delivery.EmailEvent`/`Samen.Delivery.Suppression`
  via `Samen.Delivery.Deliverability.handle_event/2`, and the
  `Samen.Delivery.Chokepoint` suppression integration) is proven ONCE,
  generically, in `samen_core/test/delivery/deliverability_test.exs` against a
  hand-built `ProviderEvent`. `Samen.Delivery.ProviderEvent` is
  provider-agnostic by construction (a `provider: atom` label plus
  `kind`/`provider_message_id`/`payload`; `Deliverability.handle_event/2`
  never branches on `provider`), so the SAME domain logic that file proves for
  a `:postmark`-labeled event applies verbatim to the `:ses`-labeled events
  THIS file proves this adapter genuinely produces from real SNS-wrapped SES
  fixture bodies — together the two files (across two packages, per the
  established split, never a parallel pipeline in this one) prove the FULL C4
  pipeline for SES.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.ProviderEvent
  alias SamenSes.{Provider, SnsSignature}

  setup_all do
    test_certs =
      %{root: [{:key, {:rsa, 2048, 65537}}], intermediates: [], peer: [{:key, {:rsa, 2048, 65537}}]}
      |> :public_key.pkix_test_data()
      |> Map.new()

    {:RSAPrivateKey, key_der} = test_certs.key
    priv_key = :public_key.der_decode(:RSAPrivateKey, key_der)
    pem = :public_key.pem_encode([{:Certificate, test_certs.cert, :not_encrypted}])

    %{priv_key: priv_key, pem: pem}
  end

  defp config(pem), do: %{access_key_id: "AKIA_X", secret_access_key: "s", region: "us-east-1", from: "sender@example.test", cert_fetcher: fn _ -> {:ok, pem} end}

  defp sign(envelope, priv_key, digest \\ :sha) do
    signable = SnsSignature.canonical_string(envelope)
    sig = :public_key.sign(signable, digest, priv_key)
    Map.put(envelope, "Signature", Base.encode64(sig))
  end

  defp envelope(message_id, inner_json) do
    %{
      "Type" => "Notification",
      "MessageId" => message_id,
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:fixture-ses-events",
      "Message" => inner_json,
      "Timestamp" => "2026-07-22T00:00:01.000Z",
      "SignatureVersion" => "1",
      "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/fixture-cert.pem"
    }
  end

  @bounce_pii_email "bounced-recipient@example.test"

  defp bounce_inner do
    Jason.encode!(%{
      "eventType" => "Bounce",
      "bounce" => %{
        "bounceType" => "Permanent",
        "bounceSubType" => "General",
        "bouncedRecipients" => [%{"emailAddress" => @bounce_pii_email, "status" => "5.1.1"}],
        "timestamp" => "2026-07-22T00:00:00.000Z",
        "feedbackId" => "fixture-feedback-id-1"
      },
      "mail" => %{"messageId" => "ses-bounce-msg-1", "timestamp" => "2026-07-21T23:59:00.000Z", "destination" => [@bounce_pii_email]}
    })
  end

  @complaint_pii_email "complainer@example.test"

  defp complaint_inner do
    Jason.encode!(%{
      "eventType" => "Complaint",
      "complaint" => %{
        "complainedRecipients" => [%{"emailAddress" => @complaint_pii_email}],
        "timestamp" => "2026-07-22T01:00:00.000Z",
        "feedbackId" => "fixture-feedback-id-2",
        "complaintFeedbackType" => "abuse"
      },
      "mail" => %{"messageId" => "ses-complaint-msg-1", "timestamp" => "2026-07-21T23:59:00.000Z", "destination" => [@complaint_pii_email]}
    })
  end

  defp delivery_inner do
    Jason.encode!(%{
      "eventType" => "Delivery",
      "delivery" => %{"timestamp" => "2026-07-22T02:00:00.000Z", "recipients" => ["delivered-to@example.test"]},
      "mail" => %{"messageId" => "ses-delivery-msg-1", "destination" => ["delivered-to@example.test"]}
    })
  end

  defp open_inner do
    Jason.encode!(%{
      "eventType" => "Open",
      "open" => %{"timestamp" => "2026-07-22T03:00:00.000Z"},
      "mail" => %{"messageId" => "ses-open-msg-1", "destination" => ["opener@example.test"]}
    })
  end

  defp click_inner do
    Jason.encode!(%{
      "eventType" => "Click",
      "click" => %{"timestamp" => "2026-07-22T04:00:00.000Z", "link" => "https://example.test/promo"},
      "mail" => %{"messageId" => "ses-click-msg-1", "destination" => ["clicker@example.test"]}
    })
  end

  describe "bounce fixture -> :bounce ProviderEvent (handoff done-criterion 1+2)" do
    test "kind, provider_message_id, and redaction are all correct", %{priv_key: priv_key, pem: pem} do
      signed = sign(envelope("sns-bounce-1", bounce_inner()), priv_key)

      assert {:ok, %ProviderEvent{} = event} =
               Provider.verify_and_parse_event(Jason.encode!(signed), [], config(pem))

      assert event.kind == :bounce
      assert event.provider == :ses
      assert event.provider_message_id == "ses-bounce-msg-1"

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @bounce_pii_email
      # Only the top-level `eventType` scalar survives — the entire nested
      # `bounce`/`mail` structure (where the PII actually lives) is dropped.
      assert event.payload["eventType"] == "Bounce"
    end
  end

  describe "complaint fixture -> :complaint ProviderEvent (handoff done-criterion 1+2)" do
    test "kind, provider_message_id, and redaction are all correct", %{priv_key: priv_key, pem: pem} do
      signed = sign(envelope("sns-complaint-1", complaint_inner()), priv_key)

      assert {:ok, %ProviderEvent{} = event} =
               Provider.verify_and_parse_event(Jason.encode!(signed), [], config(pem))

      assert event.kind == :complaint
      assert event.provider_message_id == "ses-complaint-msg-1"

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @complaint_pii_email
      assert event.payload["eventType"] == "Complaint"
    end
  end

  describe "delivered/open/click fixtures -> the remaining bounded ProviderEvent kinds" do
    test "Delivery -> :delivered", %{priv_key: priv_key, pem: pem} do
      signed = sign(envelope("sns-delivery-1", delivery_inner()), priv_key)

      assert {:ok, %ProviderEvent{kind: :delivered, provider_message_id: "ses-delivery-msg-1"}} =
               Provider.verify_and_parse_event(Jason.encode!(signed), [], config(pem))
    end

    test "Open -> :open", %{priv_key: priv_key, pem: pem} do
      signed = sign(envelope("sns-open-1", open_inner()), priv_key)

      assert {:ok, %ProviderEvent{kind: :open, provider_message_id: "ses-open-msg-1"}} =
               Provider.verify_and_parse_event(Jason.encode!(signed), [], config(pem))
    end

    test "Click -> :click", %{priv_key: priv_key, pem: pem} do
      signed = sign(envelope("sns-click-1", click_inner()), priv_key)

      assert {:ok, %ProviderEvent{kind: :click, provider_message_id: "ses-click-msg-1"}} =
               Provider.verify_and_parse_event(Jason.encode!(signed), [], config(pem))
    end

    test "every fixture's recipient address is redacted", %{priv_key: priv_key, pem: pem} do
      for {inner, pii} <- [
            {delivery_inner(), "delivered-to@example.test"},
            {open_inner(), "opener@example.test"},
            {click_inner(), "clicker@example.test"}
          ] do
        signed = sign(envelope("sns-redact-check-#{System.unique_integer([:positive])}", inner), priv_key)

        assert {:ok, %ProviderEvent{} = event} =
                 Provider.verify_and_parse_event(Jason.encode!(signed), [], config(pem))

        refute Jason.encode!(event.payload) =~ pii,
               "#{pii} must not survive redact_payload/1 for kind #{inspect(event.kind)}"
      end
    end
  end

  describe "replay-dedup key (handoff §5.3): event_id is the SNS envelope's own MessageId" do
    test "the SAME SNS envelope re-delivered produces the SAME event_id (idempotent by construction)",
         %{priv_key: priv_key, pem: pem} do
      signed = sign(envelope("sns-bounce-replay-1", bounce_inner()), priv_key)
      body = Jason.encode!(signed)

      assert {:ok, event1} = Provider.verify_and_parse_event(body, [], config(pem))
      assert {:ok, event2} = Provider.verify_and_parse_event(body, [], config(pem))

      assert event1.event_id == event2.event_id
      assert event1.event_id == "sns-bounce-replay-1"
    end
  end
end
