defmodule SamenPostmark.ProviderTest do
  @moduledoc """
  `SamenPostmark.Provider`-specific coverage beyond the shared conformance
  harness: the layered fail-honest gates (server_token vs webhook creds vs
  inbound creds vs `:resolve_recipient`), the event-id fallback for Postmark
  record types with no vendor-native unique id, and error-path plumbing.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Message
  alias SamenPostmark.Provider

  defp msg do
    %Message{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil}
  end

  defp base_config do
    %{server_token: "tok", from: "sender@example.test"}
  end

  # ---------------------------------------------------------------------------
  # configured?/1

  describe "configured?/1" do
    test "false with neither server_token nor from" do
      refute Provider.configured?(%{})
    end

    test "false with only server_token (from is also required)" do
      refute Provider.configured?(%{server_token: "tok"})
    end

    test "false with only from (server_token is also required)" do
      refute Provider.configured?(%{from: "sender@example.test"})
    end

    test "true with both server_token and from" do
      assert Provider.configured?(base_config())
    end
  end

  # ---------------------------------------------------------------------------
  # deliver/2 — layered fail-honest gates

  describe "deliver/2 fail-honest layering" do
    test "unconfigured (no server_token/from) refuses :not_configured" do
      assert {:error, :not_configured} = Provider.deliver(msg(), %{})
    end

    test "configured but no :resolve_recipient wired refuses :not_implemented (operator TODO, never a fake ok)" do
      assert {:error, :not_implemented} = Provider.deliver(msg(), base_config())
    end

    test "resolve_recipient error is surfaced as-is" do
      config = Map.put(base_config(), :resolve_recipient, fn _ -> {:error, :vault_locked} end)
      assert {:error, :vault_locked} = Provider.deliver(msg(), config)
    end

    test "configured + resolve_recipient + transport genuinely dispatches (anti-tautology)" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn _req ->
          {:ok, %{status: 200, body: %{"MessageID" => "real-id-1", "ErrorCode" => 0}}}
        end)

      assert {:ok, %{provider_message_id: "real-id-1"}} = Provider.deliver(msg(), config)
    end

    test "a Postmark-side error response (ErrorCode != 0) is surfaced, never {:ok, _}" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn _req ->
          {:ok, %{status: 422, body: %{"ErrorCode" => 300, "Message" => "Invalid email request"}}}
        end)

      assert {:error, {:postmark_error, 422, 300, "Invalid email request"}} = Provider.deliver(msg(), config)
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
  # verify_and_parse_event/3 — layered gates + Basic Auth "signature"

  describe "verify_and_parse_event/3 fail-honest layering" do
    test "unconfigured refuses :not_configured" do
      assert {:error, :not_configured} = Provider.verify_and_parse_event("{}", [], %{})
    end

    test "configured but no webhook creds wired refuses :not_implemented" do
      assert {:error, :not_implemented} = Provider.verify_and_parse_event("{}", [], base_config())
    end

    test "missing Authorization header is invalid_signature (fail-closed, no default-accept)" do
      config = Map.merge(base_config(), %{webhook_username: "u", webhook_password: "p"})
      assert {:error, :invalid_signature} = Provider.verify_and_parse_event("{}", [], config)
    end

    test "a malformed (non-JSON) body with valid auth is :malformed" do
      config = Map.merge(base_config(), %{webhook_username: "u", webhook_password: "p"})
      headers = [{"authorization", "Basic " <> Base.encode64("u:p")}]
      assert {:error, :malformed} = Provider.verify_and_parse_event("not json", headers, config)
    end

    test "unknown RecordType maps to :unhandled (stored replay-safe, not dispatched)" do
      config = Map.merge(base_config(), %{webhook_username: "u", webhook_password: "p"})
      headers = [{"authorization", "Basic " <> Base.encode64("u:p")}]
      body = Jason.encode!(%{"RecordType" => "SomeFutureType", "MessageID" => "m1"})

      assert {:ok, event} = Provider.verify_and_parse_event(body, headers, config)
      assert event.kind == :unhandled
    end

    test "Delivery/Open/Click events (no vendor ID field) get a stable content-hash event_id" do
      config = Map.merge(base_config(), %{webhook_username: "u", webhook_password: "p"})
      headers = [{"authorization", "Basic " <> Base.encode64("u:p")}]
      body = Jason.encode!(%{"RecordType" => "Delivery", "MessageID" => "m1", "DeliveredAt" => "2026-07-22T00:00:00Z"})

      assert {:ok, event1} = Provider.verify_and_parse_event(body, headers, config)
      assert {:ok, event2} = Provider.verify_and_parse_event(body, headers, config)
      # Same body -> same synthesized event_id (idempotent replay-dedup key, §5.3).
      assert event1.event_id == event2.event_id
      assert is_binary(event1.event_id) and event1.event_id != ""
    end

    test "Bounce events use Postmark's own :ID field as event_id (not the hash fallback)" do
      config = Map.merge(base_config(), %{webhook_username: "u", webhook_password: "p"})
      headers = [{"authorization", "Basic " <> Base.encode64("u:p")}]
      body = Jason.encode!(%{"RecordType" => "Bounce", "ID" => 999, "MessageID" => "m1"})

      assert {:ok, event} = Provider.verify_and_parse_event(body, headers, config)
      assert event.event_id == "999"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_inbound/3 — layered gates

  describe "parse_inbound/3 fail-honest layering" do
    test "unconfigured refuses :not_configured" do
      assert {:error, :not_configured} = Provider.parse_inbound("{}", [], %{})
    end

    test "configured but no inbound creds wired refuses :not_implemented" do
      assert {:error, :not_implemented} = Provider.parse_inbound("{}", [], base_config())
    end

    test "wrong Basic Auth credentials refuse :invalid_signature" do
      config = Map.merge(base_config(), %{inbound_username: "u", inbound_password: "p"})
      headers = [{"authorization", "Basic " <> Base.encode64("u:WRONG")}]
      assert {:error, :invalid_signature} = Provider.parse_inbound("{}", headers, config)
    end

    test "correct credentials parse a real InboundMessage" do
      config = Map.merge(base_config(), %{inbound_username: "u", inbound_password: "p"})
      headers = [{"authorization", "Basic " <> Base.encode64("u:p")}]

      body =
        Jason.encode!(%{
          "From" => "a@b.test",
          "FromName" => "A B",
          "To" => "support@example.test, cc@example.test",
          "Subject" => "hi",
          "MessageID" => "in-1",
          "TextBody" => "body text"
        })

      assert {:ok, inbound} = Provider.parse_inbound(body, headers, config)
      assert inbound.from == "a@b.test"
      assert inbound.to == ["support@example.test", "cc@example.test"]
      assert inbound.message_id == "in-1"
    end
  end

  # ---------------------------------------------------------------------------
  # capabilities/0

  test "capabilities/0 declares deliverability_webhooks, inbound, tracking" do
    assert Enum.sort(Provider.capabilities()) ==
             Enum.sort([:deliverability_webhooks, :inbound, :tracking])
  end

  # ---------------------------------------------------------------------------
  # redact_payload/1 — genuinely strips PII, retains structural fields

  describe "redact_payload/1" do
    test "strips Email/From/FromName, retains non-PII keys" do
      payload = %{
        "RecordType" => "Bounce",
        "Email" => "person@example.test",
        "FromName" => "Person Name",
        "MessageID" => "m1",
        "Type" => "HardBounce"
      }

      redacted = Provider.redact_payload(payload)

      refute Map.has_key?(redacted, "Email")
      refute Map.has_key?(redacted, "FromName")
      assert redacted["MessageID"] == "m1"
      assert redacted["Type"] == "HardBounce"
    end
  end

  # ---------------------------------------------------------------------------
  # T30 hardening (routed from the T24 verifier, ADR-038 §5.4 / INV-1):
  # redact_payload/1 converted DENYLIST -> ALLOWLIST (scalar-key, mirrors
  # SamenStripe.Provider's T24 hardening line-for-line). Postmark webhooks
  # carry a free-form `Metadata` bag (custom key/value data an org attaches to
  # an outbound message, echoed back on the bounce/complaint/delivery event)
  # — the SAME free-form-PII-container shape as Stripe's `metadata`. A
  # denylist can only strip keys it already knows about; this is the gap the
  # allowlist closes.
  # ---------------------------------------------------------------------------

  describe "T30: Metadata.* PII never survives redaction (red) + a whitelisted field survives (control)" do
    test "a bounce payload with PII under an UNENUMERATED nested Metadata key is redacted" do
      # `account_holder_ssn` is NOT one of the ~9 literal keys the OLD denylist
      # enumerated (`Recipient Email From FromFull FromName To ToFull Cc
      # CcFull ReplyTo`) — the exact shape of free-form Postmark `Metadata` an
      # org can populate with ANYTHING.
      novel_pii_ssn = "123-45-6789"
      # `Email` WAS one of the old denylist's literal keys — kept here as a
      # control proving the fix is not narrower than before, not a regression
      # on the one case the denylist used to catch.
      enumerated_pii_email = "hidden-in-metadata@example.test"

      payload = %{
        "RecordType" => "Bounce",
        "ID" => 4_323_463,
        "MessageID" => "fixture-dunning-1",
        "Type" => "HardBounce",
        # A free-form Postmark metadata bag — the org can stash ANYTHING under
        # ANY key here, including a key no denylist enumerates. Nested, not a
        # top-level key.
        "Metadata" => %{
          "account_holder_ssn" => novel_pii_ssn,
          "customer_email" => enumerated_pii_email
        }
      }

      redacted = Provider.redact_payload(payload)
      serialized = Jason.encode!(redacted)

      refute serialized =~ novel_pii_ssn,
             "PII under a key NO denylist ever enumerated must not survive redaction"

      refute serialized =~ enumerated_pii_email,
             "PII under a key the OLD denylist happened to enumerate must still not survive"

      refute Map.has_key?(redacted, "Metadata"),
             "Metadata is dropped wholesale — even its non-PII sibling keys never survive"

      # Positive control: genuinely whitelisted TOP-LEVEL fields still survive
      # (redaction is surgical, not a wipe-everything no-op).
      assert redacted["MessageID"] == "fixture-dunning-1"
      assert redacted["Type"] == "HardBounce"
      assert redacted["RecordType"] == "Bounce"
      assert redacted["ID"] == 4_323_463
    end

    test "an allowlisted key whose VALUE is a nested map is dropped too (not assumed safe by name)" do
      # Even a key that IS on the allowlist must be dropped if its value isn't
      # a scalar — an expanded/nested value under an allowlisted-looking name
      # is never assumed safe merely because the key matches.
      payload = %{
        "RecordType" => %{"unexpected" => "nested-shape", "email" => "sneaky@example.test"},
        "MessageID" => "m2"
      }

      redacted = Provider.redact_payload(payload)

      refute Map.has_key?(redacted, "RecordType"),
             "an allowlisted key with a non-scalar value must still be dropped"

      assert redacted["MessageID"] == "m2"
    end
  end
end
