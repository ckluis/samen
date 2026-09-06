defmodule SamenPostmark.ConformanceTest do
  @moduledoc """
  UXD-07 / A6 — `samen_postmark` is the FIRST ESP adapter to consume the SHARED
  cross-family kit `Samen.AdapterConformanceCase` (T188, samen_core) instead of the
  ESP-only `Samen.Delivery.ProviderConformanceCase` macro harness. This closes the
  convergence half of T188, which shipped a generalized kit no ESP adapter consumed:
  generalizing a kit nothing consumes proves the kit compiles, not that it converges.

  Same fixture file (`test/fixtures/conformance.exs`, unchanged) and the same ADR-038
  §4.5 (a)-(f) guarantees the macro harness generated; the difference is that the
  assertions are PLAIN imported functions called from explicit `test` blocks — the kit's
  house convention (`Samen.MaskingCase`/`Samen.RedPath`) — rather than a macro-generated
  fixture DSL.

  `Samen.Delivery.ProviderConformanceCase` is left UNCHANGED and is still the harness
  `samen_resend`, `samen_ses` and samen_core's own `Samen.Delivery.DeliverLeakGateTest`
  consume, so its frozen signature never moves (the ADR-038 roadmap-collision rule).

  Proven non-vacuous by `scripts/sabotages/301-uxd07-postmark-redaction-allowlist-widened.patch`:
  widening `SamenPostmark.Provider`'s redaction allowlist flips the redaction test below,
  which is the kit's own `assert_redaction!/3` — an adopted kit that would pass a broken
  adapter has adopted nothing.
  """
  use Samen.AdapterConformanceCase, adapter: SamenPostmark.Provider
  use ExUnit.Case, async: true

  alias Samen.Delivery.{InboundMessage, Message, ProviderEvent}
  alias SamenPostmark.Provider

  @declared_capabilities [:deliverability_webhooks, :inbound, :tracking]

  setup_all do
    {:ok, fixtures: load_fixtures!("test/fixtures")}
  end

  describe "ADR-038 §4.5(e): capabilities/0 matches the declared list" do
    test "capabilities/0 == the capabilities this conformance run declares" do
      assert Enum.sort(Provider.capabilities()) == Enum.sort(@declared_capabilities)
    end
  end

  describe "ADR-038 §4.5(a): the unconfigured table — every callback refuses honestly" do
    test "unconfigured refuses every callback (never a fake {:ok, _})", %{fixtures: fixtures} do
      message = struct!(Message, fixtures.message)

      refute Provider.configured?(%{}),
             "SamenPostmark.Provider.configured?/1 must be false for an empty config (%{})"

      assert :ok =
               assert_refusal_table!([
                 {"deliver/2 unconfigured", fn -> Provider.deliver(message, %{}) end,
                  :not_configured},
                 {"verify_and_parse_event/3 unconfigured",
                  fn -> Provider.verify_and_parse_event(fixtures.webhook.valid.body, [], %{}) end,
                  :not_configured},
                 {"parse_inbound/3 unconfigured",
                  fn -> Provider.parse_inbound(fixtures.inbound.body, [], %{}) end,
                  :not_configured}
               ])
    end
  end

  describe "ADR-038 §4.5(e): capability honesty — configured but credential-less refuses honestly" do
    test "the capability-gated callbacks refuse :not_implemented even when CONFIGURED",
         %{fixtures: fixtures} do
      # configured?/1 is TRUE here (server_token + from are present) while the webhook and
      # inbound credential pairs are absent — so the refusal below proves capability
      # honesty, not merely a side effect of being unconfigured.
      credential_less = Map.take(fixtures.configured_config, [:server_token, :from])

      assert Provider.configured?(credential_less),
             "the credential-less fixture config must still be configured?/1 == true, " <>
               "otherwise this test degenerates into the unconfigured table above"

      assert :ok =
               assert_refusal_table!([
                 {"verify_and_parse_event/3 configured, no webhook credentials",
                  fn ->
                    Provider.verify_and_parse_event(
                      fixtures.webhook.valid.body,
                      fixtures.webhook.valid.headers,
                      credential_less
                    )
                  end, :not_implemented},
                 {"parse_inbound/3 configured, no inbound credentials",
                  fn ->
                    Provider.parse_inbound(
                      fixtures.inbound.body,
                      fixtures.inbound.headers,
                      credential_less
                    )
                  end, :not_implemented}
               ])
    end
  end

  describe "ADR-038 §4.5(b): configured deliver/2 against the fixture transport" do
    test "returns a receipt carrying a non-empty :provider_message_id", %{fixtures: fixtures} do
      message = struct!(Message, fixtures.message)

      assert {:ok, receipt} = Provider.deliver(message, fixtures.configured_config)
      assert is_map(receipt)

      id = Map.get(receipt, :provider_message_id)

      assert is_binary(id) and id != "",
             "the configured receipt must carry a non-empty :provider_message_id, got: " <>
               inspect(receipt)
    end
  end

  describe "ADR-038 §4.5(f) / C3 (T29): deliver/2 leaks NO vault token or PII to the ESP (INV-1)" do
    test "the captured outbound ESP payload carries no vt_ token and no forbidden plaintext",
         %{fixtures: fixtures} do
      probe = fixtures.deliver_leak_probe
      message = struct!(Message, probe.message)

      assert :ok =
               assert_capture_no_leak!(
                 fn capture -> Provider.deliver(message, probe.build_config.(capture)) end,
                 [probe.forbidden_plaintext]
               )
    end
  end

  describe "ADR-038 §4.5(d): redaction — no PII fixture string survives redact_payload/1" do
    test "redact_payload/1 strips every known-PII fixture string and keeps the retained keys",
         %{fixtures: fixtures} do
      assert :ok =
               assert_redaction!(
                 &Provider.redact_payload/1,
                 fixtures.redaction.payload,
                 pii_strings: fixtures.redaction.pii_strings,
                 retained_keys: fixtures.redaction.retained_keys
               )
    end
  end

  describe "ADR-038 §4.5(c)+(e): webhook red/green (declared :deliverability_webhooks)" do
    test "a valid fixture parses; a tampered one refuses :invalid_signature, parses nothing",
         %{fixtures: fixtures} do
      %{valid: valid, tampered: tampered} = fixtures.webhook
      config = fixtures.configured_config

      assert {:ok, %ProviderEvent{}} =
               Provider.verify_and_parse_event(valid.body, valid.headers, config)

      assert {:error, :invalid_signature} =
               Provider.verify_and_parse_event(tampered.body, tampered.headers, config)
    end
  end

  describe "ADR-038 §4.5(e): parse_inbound/3 (declared :inbound)" do
    test "a valid inbound fixture parses to a real InboundMessage", %{fixtures: fixtures} do
      %{body: body, headers: headers} = fixtures.inbound

      assert {:ok, %InboundMessage{}} =
               Provider.parse_inbound(body, headers, fixtures.configured_config)
    end
  end
end
