defmodule SamenResend.DeliverabilityTest do
  @moduledoc """
  C4 (T30) — Resend/Svix REFERENCE fixtures for every deliverability event
  kind (ADR-038 §4.4; T95 handoff done-criterion 2). Hermetic, ADAPTER-side-
  only: proves `SamenResend.Provider.verify_and_parse_event/3` correctly
  (a) verifies the real Svix HMAC-SHA256 signature, (b) maps each real Resend
  `type` to the bounded, samen-owned `ProviderEvent.kind` enum, (c) extracts
  `provider_message_id` from `data.email_id` — the token-blind join key
  ADR-038 §4.1 requires — and (d) redacts PII (allowlist).

  `samen_core` is vendor-free (INV-4) and therefore CANNOT depend on this
  package, so — exactly as `samen_postmark`/T27 and `samen_ses`/T94
  established for the SAME split — the DOMAIN-side half of C4 (matching a
  `ProviderEvent` to a send receipt, writing
  `Samen.Delivery.EmailEvent`/`Samen.Delivery.Suppression` via
  `Samen.Delivery.Deliverability.handle_event/2`, and the
  `Samen.Delivery.Chokepoint` suppression integration) is proven ONCE,
  generically, in `samen_core/test/delivery/deliverability_test.exs` against
  a hand-built `ProviderEvent`. `Samen.Delivery.ProviderEvent` is
  provider-agnostic by construction (a `provider: atom` label plus
  `kind`/`provider_message_id`/`payload`; `Deliverability.handle_event/2`
  never branches on `provider`), so the SAME domain logic that file proves
  for a `:postmark`-labeled event applies verbatim to the `:resend`-labeled
  events THIS file proves this adapter genuinely produces from real
  Svix-signed Resend fixture bodies — together the two files (across two
  packages, per the established split, never a parallel pipeline in this
  one) prove the FULL C4 pipeline for Resend.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.ProviderEvent
  alias SamenResend.Provider

  @secret "whsec_" <> Base.encode64("resend-deliverability-fixture-secret-32b")

  defp config, do: %{api_key: "fixture-key", from: "sender@example.test", webhook_secret: @secret}

  defp sign(svix_id, timestamp, body) do
    signed_content = svix_id <> "." <> timestamp <> "." <> body
    {:ok, key} = @secret |> String.trim_leading("whsec_") |> Base.decode64()
    sig = :crypto.mac(:hmac, :sha256, key, signed_content) |> Base.encode64()

    [
      {"svix-id", svix_id},
      {"svix-timestamp", timestamp},
      {"svix-signature", "v1," <> sig}
    ]
  end

  defp now_ts, do: System.system_time(:second) |> Integer.to_string()

  @bounce_pii_email "bounced-recipient@example.test"

  defp bounce_body do
    Jason.encode!(%{
      "type" => "email.bounced",
      "created_at" => "2026-07-22T00:00:00.000Z",
      "data" => %{
        "email_id" => "resend-bounce-msg-1",
        "from" => "sender@example.test",
        "to" => [@bounce_pii_email],
        "subject" => "Welcome to samen!",
        "bounce" => %{"type" => "Permanent", "message" => "smtp; 550 5.1.1 no such user"}
      }
    })
  end

  @complaint_pii_email "complainer@example.test"

  defp complaint_body do
    Jason.encode!(%{
      "type" => "email.complained",
      "created_at" => "2026-07-22T01:00:00.000Z",
      "data" => %{
        "email_id" => "resend-complaint-msg-1",
        "from" => "sender@example.test",
        "to" => [@complaint_pii_email],
        "subject" => "Welcome to samen!"
      }
    })
  end

  defp delivered_body do
    Jason.encode!(%{
      "type" => "email.delivered",
      "created_at" => "2026-07-22T02:00:00.000Z",
      "data" => %{"email_id" => "resend-delivery-msg-1", "to" => ["delivered-to@example.test"]}
    })
  end

  defp open_body do
    Jason.encode!(%{
      "type" => "email.opened",
      "created_at" => "2026-07-22T03:00:00.000Z",
      "data" => %{"email_id" => "resend-open-msg-1", "to" => ["opener@example.test"]}
    })
  end

  defp click_body do
    Jason.encode!(%{
      "type" => "email.clicked",
      "created_at" => "2026-07-22T04:00:00.000Z",
      "data" => %{"email_id" => "resend-click-msg-1", "to" => ["clicker@example.test"], "link" => "https://example.test/promo"}
    })
  end

  describe "bounce fixture -> :bounce ProviderEvent (handoff done-criterion 1+2)" do
    test "kind, provider_message_id, and redaction are all correct" do
      body = bounce_body()
      headers = sign("msg_bounce_1", now_ts(), body)

      assert {:ok, %ProviderEvent{} = event} = Provider.verify_and_parse_event(body, headers, config())

      assert event.kind == :bounce
      assert event.provider == :resend
      assert event.provider_message_id == "resend-bounce-msg-1"
      assert event.event_id == "msg_bounce_1"

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @bounce_pii_email
      # Only the top-level `type`/`created_at` scalars survive — the entire
      # nested `data` structure (where the PII actually lives) is dropped.
      assert event.payload["type"] == "email.bounced"
    end
  end

  describe "complaint fixture -> :complaint ProviderEvent (handoff done-criterion 1+2)" do
    test "kind, provider_message_id, and redaction are all correct" do
      body = complaint_body()
      headers = sign("msg_complaint_1", now_ts(), body)

      assert {:ok, %ProviderEvent{} = event} = Provider.verify_and_parse_event(body, headers, config())

      assert event.kind == :complaint
      assert event.provider_message_id == "resend-complaint-msg-1"

      serialized = Jason.encode!(event.payload)
      refute serialized =~ @complaint_pii_email
      assert event.payload["type"] == "email.complained"
    end
  end

  describe "delivered/open/click fixtures -> the remaining bounded ProviderEvent kinds" do
    test "email.delivered -> :delivered" do
      body = delivered_body()
      headers = sign("msg_delivered_1", now_ts(), body)

      assert {:ok, %ProviderEvent{kind: :delivered, provider_message_id: "resend-delivery-msg-1"}} =
               Provider.verify_and_parse_event(body, headers, config())
    end

    test "email.opened -> :open" do
      body = open_body()
      headers = sign("msg_open_1", now_ts(), body)

      assert {:ok, %ProviderEvent{kind: :open, provider_message_id: "resend-open-msg-1"}} =
               Provider.verify_and_parse_event(body, headers, config())
    end

    test "email.clicked -> :click" do
      body = click_body()
      headers = sign("msg_click_1", now_ts(), body)

      assert {:ok, %ProviderEvent{kind: :click, provider_message_id: "resend-click-msg-1"}} =
               Provider.verify_and_parse_event(body, headers, config())
    end

    test "every fixture's recipient address is redacted" do
      for {body, pii} <- [
            {delivered_body(), "delivered-to@example.test"},
            {open_body(), "opener@example.test"},
            {click_body(), "clicker@example.test"}
          ] do
        svix_id = "msg_redact_check_#{System.unique_integer([:positive])}"
        headers = sign(svix_id, now_ts(), body)

        assert {:ok, %ProviderEvent{} = event} = Provider.verify_and_parse_event(body, headers, config())

        refute Jason.encode!(event.payload) =~ pii,
               "#{pii} must not survive redact_payload/1 for kind #{inspect(event.kind)}"
      end
    end
  end

  describe "replay-dedup key (handoff §5.3): event_id is the Svix svix-id header" do
    test "the SAME webhook re-delivered produces the SAME event_id (idempotent by construction)" do
      body = bounce_body()
      headers = sign("msg-bounce-replay-1", now_ts(), body)

      assert {:ok, event1} = Provider.verify_and_parse_event(body, headers, config())
      assert {:ok, event2} = Provider.verify_and_parse_event(body, headers, config())

      assert event1.event_id == event2.event_id
      assert event1.event_id == "msg-bounce-replay-1"
    end
  end
end
