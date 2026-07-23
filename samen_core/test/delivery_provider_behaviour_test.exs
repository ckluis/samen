defmodule Samen.Delivery.ProviderBehaviourTest do
  @moduledoc """
  ADR-038 §4.1–§4.2 `Samen.Delivery.Provider` behaviour conformance (T27/C1) —
  mirrors `Samen.Billing.ProviderTest`'s discipline for the delivery side.

  Coverage:
    * The fail-honest table (§4.1): `Samen.Delivery.FakeProvider`, unconfigured,
      refuses EVERY callback except `configured?/1` and `redact_payload/1` with
      `{:error, :not_configured}` (mandatory callbacks) or the capability-honest
      `{:error, :not_implemented}` (capability-gated callbacks, undeclared) —
      never a fake `{:ok, _}`.
    * Anti-tautology: a CONFIGURED fake (with the matching capability declared)
      genuinely records the call and returns real (fake-tagged) data.
    * `use Samen.Delivery.Provider`'s minimal-two-function default: `capabilities/0`
      -> `[]`, `verify_and_parse_event/3` / `parse_inbound/3` -> `:not_implemented`,
      `redact_payload/1` -> identity — all overridable.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.{FakeProvider, InboundMessage, Message, Provider, ProviderEvent}

  setup do
    FakeProvider.reset()
    :ok
  end

  defp msg do
    %Message{
      send_id: "s1",
      org_id: "o1",
      to_subscriber_id: "sub1",
      template_id: nil
    }
  end

  # ---------------------------------------------------------------------------
  # §4.1 — the behaviour defines exactly the ADR's callbacks.

  describe "Provider behaviour shape (§4.1)" do
    test "defines every callback the ADR specifies" do
      callbacks = Provider.behaviour_info(:callbacks)

      assert {:configured?, 1} in callbacks
      assert {:deliver, 2} in callbacks
      assert {:capabilities, 0} in callbacks
      assert {:verify_and_parse_event, 3} in callbacks
      assert {:parse_inbound, 3} in callbacks
      assert {:redact_payload, 1} in callbacks
      assert length(callbacks) == 6
    end
  end

  # ---------------------------------------------------------------------------
  # `use Samen.Delivery.Provider` — the minimal two-function default.

  describe "use Samen.Delivery.Provider minimal defaults" do
    defmodule Minimal do
      use Provider
      @impl true
      def configured?(_config), do: true
      @impl true
      def deliver(_message, _config), do: {:ok, %{provider_message_id: "min-1"}}
    end

    test "capabilities/0 defaults to []" do
      assert Minimal.capabilities() == []
    end

    test "verify_and_parse_event/3 and parse_inbound/3 default to :not_implemented" do
      assert {:error, :not_implemented} = Minimal.verify_and_parse_event("{}", [], %{})
      assert {:error, :not_implemented} = Minimal.parse_inbound("{}", [], %{})
    end

    test "redact_payload/1 defaults to identity (never receives a real vendor payload since no webhook capability is declared)" do
      payload = %{email: "a@b.com", amount: 100}
      assert Minimal.redact_payload(payload) == payload
    end
  end

  # ---------------------------------------------------------------------------
  # §4.1 fail-honest table: FakeProvider unconfigured refuses everything.

  describe "fail-honest table (§4.1): FakeProvider unconfigured" do
    test "configured?/1 is false by default" do
      refute FakeProvider.configured?(%{})
      refute FakeProvider.configured?(%{configured: false})
    end

    test "deliver/2 refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.deliver(msg(), %{})
    end

    test "verify_and_parse_event/3 refuses :not_implemented when capability undeclared, even unconfigured" do
      assert FakeProvider.capabilities() == []
      assert {:error, :not_implemented} = FakeProvider.verify_and_parse_event("{}", [], %{})
    end

    test "parse_inbound/3 refuses :not_implemented when capability undeclared, even unconfigured" do
      assert {:error, :not_implemented} = FakeProvider.parse_inbound("{}", [], %{})
    end

    test "verify_and_parse_event/3 refuses :not_configured when capability IS declared but unconfigured" do
      FakeProvider.set_capabilities([:deliverability_webhooks])
      assert {:error, :not_configured} = FakeProvider.verify_and_parse_event("{}", [], %{})
    end

    test "parse_inbound/3 refuses :not_configured when capability IS declared but unconfigured" do
      FakeProvider.set_capabilities([:inbound])
      assert {:error, :not_configured} = FakeProvider.parse_inbound("{}", [], %{})
    end

    test "no call is recorded as successful while unconfigured" do
      FakeProvider.deliver(msg(), %{})
      assert FakeProvider.calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # redact_payload/1 — exempt from configured?/1, genuinely strips PII.

  describe "redact_payload/1 — exempt from configured?/1, genuinely strips PII" do
    test "strips known PII keys without needing config" do
      payload = %{email: "person@example.com", name: "Person", amount_cents: 500}
      redacted = FakeProvider.redact_payload(payload)

      refute Map.has_key?(redacted, :email)
      refute Map.has_key?(redacted, :name)
      assert redacted.amount_cents == 500
    end
  end

  # ---------------------------------------------------------------------------
  # Anti-tautology: a CONFIGURED FakeProvider (with capabilities declared) is a
  # real, call-recording double.

  describe "anti-tautology: a CONFIGURED FakeProvider genuinely dispatches" do
    test "deliver/2 returns a fake-tagged receipt with :provider_message_id and records the call" do
      config = %{configured: true}
      m = msg()

      assert {:ok, %{provider_message_id: id, fake: true}} = FakeProvider.deliver(m, config)
      assert is_binary(id)
      assert [{:deliver, %{message: ^m}}] = FakeProvider.calls()
    end

    test "verify_and_parse_event/3 returns a real ProviderEvent when configured + capability declared" do
      FakeProvider.set_capabilities([:deliverability_webhooks])
      assert {:ok, %ProviderEvent{provider: :fake}} =
               FakeProvider.verify_and_parse_event("{}", [], %{configured: true})
    end

    test "parse_inbound/3 returns a real InboundMessage when configured + capability declared" do
      FakeProvider.set_capabilities([:inbound])
      assert {:ok, %InboundMessage{provider: :fake}} =
               FakeProvider.parse_inbound("{}", [], %{configured: true})
    end
  end
end
