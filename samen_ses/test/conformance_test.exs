defmodule SamenSes.ConformanceTest do
  @moduledoc """
  UXD-07 / A6 / E-04 — `samen_ses` converges onto the SHARED cross-family
  kit `Samen.AdapterConformanceCase` (T188, samen_core), the third ESP
  adapter to do so after `samen_postmark` (T27) and `samen_resend` (A13
  seam 2, adapter 1). This closes A13's second seam (adapter-by-adapter
  adoption; `E-04.answer.md`) for the final ESP adapter.

  Same fixture file (`test/fixtures/conformance.exs`, unchanged) and the same
  ADR-038 §4.5 (a)-(f) guarantees the macro harness (`Samen.Delivery.
  ProviderConformanceCase`) generated; the difference is that the assertions
  are PLAIN imported functions called from explicit `test` blocks — the
  kit's house convention — rather than a macro-generated fixture DSL.
  `Samen.Delivery.ProviderConformanceCase` is left UNCHANGED (its frozen
  signature never moves, ADR-038 roadmap-collision rule) and is still the
  harness `samen_core`'s own `Samen.Delivery.DeliverLeakGateTest` consumes.

  `samen_ses` declares NO `:inbound` capability (ADR-038 §4.5 adapter split:
  "samen_ses ... no inbound") — the capability-honesty test below proves
  `parse_inbound/3` ALWAYS refuses `{:error, :not_implemented}`, even when
  fully configured, which is strictly what the macro harness's
  `assert_undeclared_refuses!/3` branch proved before this swap.

  Unlike `samen_postmark`/`samen_resend` (whose credential-less capability
  gap lives on `verify_and_parse_event/3`, gated by a webhook secret), SES's
  SNS envelope verification (`SamenSes.SnsSignature`) needs NO per-host
  secret — it is fully implemented once `configured?/1` is true. The one
  genuine "configured but not wired" gap is `deliver/2` itself: it requires
  an injectable `config[:resolve_recipient]` (no generic ESP adapter can
  resolve a vault-routed `to_subscriber_id` to a plaintext email itself,
  ADR-014) and is honestly `{:error, :not_implemented}` without it, even
  though `configured?/1` is otherwise true (the provider moduledoc's
  "operator TODO"). The capability-honesty test below exercises THAT gap
  instead of a webhook-secret gap that does not exist for this adapter.

  Proven non-vacuous the same way the macro version was gated: this file's
  redaction test is the kit's own `assert_redaction!/3`, and the leak-gate
  test is the kit's own `assert_capture_no_leak!/2` — an adopted kit that
  would pass a broken adapter has adopted nothing.
  """
  use Samen.AdapterConformanceCase, adapter: SamenSes.Provider
  use ExUnit.Case, async: true

  alias Samen.Delivery.{Message, ProviderEvent}
  alias SamenSes.Provider

  @declared_capabilities [:deliverability_webhooks, :tracking]

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
             "SamenSes.Provider.configured?/1 must be false for an empty config (%{})"

      assert :ok =
               assert_refusal_table!([
                 {"deliver/2 unconfigured", fn -> Provider.deliver(message, %{}) end,
                  :not_configured},
                 {"verify_and_parse_event/3 unconfigured",
                  fn -> Provider.verify_and_parse_event(fixtures.webhook.valid.body, [], %{}) end,
                  :not_configured},
                 {"parse_inbound/3 unconfigured (capability undeclared, so :not_implemented " <>
                    "regardless of config)", fn -> Provider.parse_inbound("{}", [], %{}) end,
                  :not_implemented}
               ])
    end
  end

  describe "ADR-038 §4.5(e): capability honesty — configured but credential-less refuses honestly" do
    test "deliver/2 refuses :not_implemented when CONFIGURED but missing resolve_recipient",
         %{fixtures: fixtures} do
      # configured?/1 is TRUE here (access_key_id/secret_access_key/region/from
      # are present) while `:resolve_recipient` — the injectable host glue
      # deliver/2 needs to turn a vault-routed to_subscriber_id into a
      # plaintext email (ADR-014) — is absent, so the refusal below proves
      # capability honesty, not merely a side effect of being unconfigured.
      credential_less =
        Map.take(fixtures.configured_config, [:access_key_id, :secret_access_key, :region, :from])

      message = struct!(Message, fixtures.message)

      assert Provider.configured?(credential_less),
             "the credential-less fixture config must still be configured?/1 == true, " <>
               "otherwise this test degenerates into the unconfigured table above"

      assert :ok =
               assert_refusal_table!([
                 {"deliver/2 configured, no resolve_recipient",
                  fn -> Provider.deliver(message, credential_less) end, :not_implemented}
               ])
    end
  end

  describe "ADR-038 §4.5(e): capability honesty (undeclared :inbound)" do
    test "parse_inbound/3 always refuses :not_implemented, even fully CONFIGURED",
         %{fixtures: fixtures} do
      assert {:error, :not_implemented} =
               Provider.parse_inbound("{}", [], fixtures.configured_config)
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
end
