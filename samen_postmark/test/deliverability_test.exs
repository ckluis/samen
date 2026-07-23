defmodule SamenPostmark.DeliverabilityTest do
  @moduledoc """
  C4 (T30) — Postmark REFERENCE fixtures for every deliverability `RecordType`
  (ADR-038 §4.4; handoff done-criterion 1). Hermetic, adapter-side-only: proves
  `SamenPostmark.Provider.verify_and_parse_event/3` correctly maps each real
  Postmark webhook `RecordType` to the bounded, samen-owned `ProviderEvent.kind`
  enum, extracts `provider_message_id` (the token-blind join key ADR-038 §4.1
  requires), and redacts PII — the ADAPTER-side half of C4.

  `samen_core` is vendor-free (INV-4) and therefore CANNOT depend on this
  package, so the domain-side half of C4 — matching a `ProviderEvent` to a send
  receipt, writing `Samen.Delivery.EmailEvent`/`Samen.Delivery.Suppression`,
  and the `Samen.Delivery.Chokepoint` suppression integration — is proven in
  `samen_core/test/delivery/deliverability_test.exs` against
  hand-constructed `ProviderEvent` structs shaped EXACTLY like what THIS test
  proves this adapter produces for the same fixture bodies (see that file's
  moduledoc for the split rationale).
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.ProviderEvent
  alias SamenPostmark.Provider

  @basic_auth_username "wh_user"
  @basic_auth_password "wh_pass"

  @config %{
    server_token: "fixture-server-token",
    from: "sender@example.test",
    webhook_username: @basic_auth_username,
    webhook_password: @basic_auth_password
  }

  defp valid_headers do
    [
      {"authorization", "Basic " <> Base.encode64("#{@basic_auth_username}:#{@basic_auth_password}")},
      {"content-type", "application/json"}
    ]
  end

  @bounce_pii_email "bounced-recipient@example.test"
  @bounce_pii_name "Bounced Recipient"

  defp bounce_body do
    Jason.encode!(%{
      "RecordType" => "Bounce",
      "ID" => 111_222_333,
      "Type" => "HardBounce",
      "TypeCode" => 1,
      "MessageID" => "postmark-bounce-msg-1",
      "Email" => @bounce_pii_email,
      "FromName" => @bounce_pii_name,
      "BouncedAt" => "2026-07-22T00:00:00.000-04:00",
      "Description" => "The server was unable to deliver your mail."
    })
  end

  @complaint_pii_email "complainer@example.test"
  @complaint_pii_name "Complaining Recipient"

  defp complaint_body do
    Jason.encode!(%{
      "RecordType" => "SpamComplaint",
      "ID" => 444_555_666,
      "Type" => "SpamComplaint",
      "MessageID" => "postmark-complaint-msg-1",
      "Email" => @complaint_pii_email,
      "FromName" => @complaint_pii_name,
      "BouncedAt" => "2026-07-22T01:00:00.000-04:00"
    })
  end

  defp delivery_body do
    Jason.encode!(%{
      "RecordType" => "Delivery",
      "MessageID" => "postmark-delivery-msg-1",
      "Recipient" => "delivered-to@example.test",
      "DeliveredAt" => "2026-07-22T02:00:00.000-04:00"
    })
  end

  defp open_body do
    Jason.encode!(%{
      "RecordType" => "Open",
      "MessageID" => "postmark-open-msg-1",
      "Recipient" => "opener@example.test",
      "ReceivedAt" => "2026-07-22T03:00:00.000-04:00"
    })
  end

  defp click_body do
    Jason.encode!(%{
      "RecordType" => "Click",
      "MessageID" => "postmark-click-msg-1",
      "Recipient" => "clicker@example.test",
      "ReceivedAt" => "2026-07-22T04:00:00.000-04:00"
    })
  end

  describe "bounce fixture -> :bounce ProviderEvent (handoff done-criterion 1)" do
    test "kind, provider_message_id, and redaction are all correct" do
      assert {:ok, %ProviderEvent{} = event} =
               Provider.verify_and_parse_event(bounce_body(), valid_headers(), @config)

      assert event.kind == :bounce
      assert event.provider_message_id == "postmark-bounce-msg-1"
      assert event.provider == :postmark

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @bounce_pii_email
      refute serialized =~ @bounce_pii_name
      # Surgical, not a wipe: structural fields survive (T30 allowlist hardening).
      assert event.payload["MessageID"] == "postmark-bounce-msg-1"
      assert event.payload["Type"] == "HardBounce"
    end
  end

  describe "complaint fixture -> :complaint ProviderEvent (handoff done-criterion 1)" do
    test "kind, provider_message_id, and redaction are all correct" do
      assert {:ok, %ProviderEvent{} = event} =
               Provider.verify_and_parse_event(complaint_body(), valid_headers(), @config)

      assert event.kind == :complaint
      assert event.provider_message_id == "postmark-complaint-msg-1"

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @complaint_pii_email
      refute serialized =~ @complaint_pii_name
      assert event.payload["MessageID"] == "postmark-complaint-msg-1"
    end
  end

  describe "delivered/open/click fixtures -> the remaining bounded ProviderEvent kinds" do
    test "Delivery -> :delivered" do
      assert {:ok, %ProviderEvent{kind: :delivered, provider_message_id: "postmark-delivery-msg-1"}} =
               Provider.verify_and_parse_event(delivery_body(), valid_headers(), @config)
    end

    test "Open -> :open" do
      assert {:ok, %ProviderEvent{kind: :open, provider_message_id: "postmark-open-msg-1"}} =
               Provider.verify_and_parse_event(open_body(), valid_headers(), @config)
    end

    test "Click -> :click" do
      assert {:ok, %ProviderEvent{kind: :click, provider_message_id: "postmark-click-msg-1"}} =
               Provider.verify_and_parse_event(click_body(), valid_headers(), @config)
    end

    test "every fixture's Recipient/Email address is redacted" do
      for {body, pii} <- [
            {delivery_body(), "delivered-to@example.test"},
            {open_body(), "opener@example.test"},
            {click_body(), "clicker@example.test"}
          ] do
        assert {:ok, %ProviderEvent{} = event} =
                 Provider.verify_and_parse_event(body, valid_headers(), @config)

        refute Jason.encode!(event.payload) =~ pii,
               "#{pii} must not survive redact_payload/1 for RecordType #{inspect(event.kind)}"
      end
    end
  end
end
