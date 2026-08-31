defmodule Samen.Delivery.ProviderConformanceCase do
  @moduledoc """
  The SHARED `Samen.Delivery.Provider` conformance harness (ADR-038 §4.5;
  T27/C1). Defined here, consumed READ-ONLY by every ESP adapter package
  (three ship under ADR-038 §8.1). **A13/T27-owned follow-up decision
  (`_orch/nodes/A13a/work/conformance-case-decision.md`): this module is now
  a thin SHIM.** Its public macro signature (`use ..., provider:, fixtures:,
  capabilities:`) and its public function names/arities are unchanged and
  stay FIXED — `deliver_leak_gate_test.exs` calls
  `assert_deliver_no_leak!/2` directly, and
  `chokepoint_anti_bypass_probe_test.exs` excludes this file by path — but
  the bodies that have a delivery-shaped equivalent in the general kit
  (`load_fixtures!/1`, the deliver-leak gate, redaction) now DELEGATE to
  `Samen.AdapterConformanceCase` instead of duplicating its logic. ESP-only
  concerns (webhook red/green, inbound, the unconfigured table, capability
  honesty) have no kit equivalent and stay implemented here, expressed as
  macro-time options.

  ## Usage (verbatim ADR-038 §4.5 example shape)

      use Samen.Delivery.ProviderConformanceCase,
        provider: MyEspAdapter.Provider,
        fixtures: "test/fixtures",           # adapter-local recorded fixtures
        capabilities: [:deliverability_webhooks, :inbound, :tracking]

  `fixtures` is a path RELATIVE TO THE ADAPTER PACKAGE'S ROOT (the cwd `mix
  test` runs from) containing exactly one file: `conformance.exs`, a plain
  `.exs` script (checked-in, hand-curated fixture data — never network-recorded
  in CI, ADR-038 §7.2) that evaluates to a map with this SHAPE:

      %{
        # A config causing `configured?/1` to be true. `deliver/2` MUST reach
        # a receipt using ONLY this config — no real network call (embed a
        # `:transport`-shaped dependency-injection hook in your own Provider
        # to keep deliver/2 hermetic under this fixture; the harness itself
        # does not know or care HOW you keep it offline, only that you do).
        configured_config: %{...},

        # A token-only Samen.Delivery.Message field map (send_id/org_id/
        # to_subscriber_id/template_id).
        message: %{send_id: "...", org_id: "...", to_subscriber_id: "...", template_id: nil},

        # REQUIRED only if :deliverability_webhooks is in the declared capabilities.
        webhook: %{
          valid: %{body: "...", headers: [{"...", "..."}]},
          tampered: %{body: "...", headers: [{"...", "..."}]}   # must be REJECTED
        },

        # REQUIRED only if :inbound is in the declared capabilities.
        inbound: %{body: "...", headers: [{"...", "..."}]},

        # Redaction proof fixture (always required): a raw vendor payload
        # carrying known PII substrings redact_payload/1 must strip.
        redaction: %{
          payload: %{...},
          pii_strings: ["known-pii@example.test", "Known Pii Name"],
          retained_keys: ["MessageID"]   # optional; non-PII keys that must SURVIVE
        },

        # DELIVER LEAK PROBE (always required — ADR-038 §4.5(f) / C3 T29, INV-1).
        # Proves deliver/2's outbound ESP payload carries no vault token / PII by
        # capturing the real request. See `assert_deliver_no_leak!/2`.
        deliver_leak_probe: %{
          build_config: fn capture -> %{...config..., transport: capture} end,
          message: %{send_id: "...", org_id: "...", to_subscriber_id: "vt_...", template_id: nil},
          forbidden_plaintext: "OTHER-SUBJECT-SENTINEL@leak.test"
        }
      }

  ## What the harness asserts (ADR-038 §4.5 (a)-(e))

    * (a) the unconfigured table — every callback refuses with `:not_configured`
      (mandatory callbacks) or the capability-honest `:not_implemented`
      (capability-gated callbacks whose capability is undeclared), NEVER `{:ok, _}`;
    * (b) configured `deliver/2` against the fixture returns a receipt carrying
      `:provider_message_id`;
    * (c) webhook red/green (only if `:deliverability_webhooks` declared): the
      valid fixture parses; the SAME body with tampered signature material
      returns `{:error, :invalid_signature}` and parses NOTHING;
    * (d) redaction — no PII fixture string survives `redact_payload/1`;
    * (e) capability honesty both directions — declared capabilities have a
      real implementation (checked via (c) and the inbound analogue);
      undeclared capabilities refuse `:not_implemented` even when CONFIGURED
      (proving the refusal isn't merely a side effect of being unconfigured);
    * (f) deliver leak gate (C3/T29, INV-1) — the adapter's REAL `deliver/2`
      routes its outbound request through a harness capture transport; the
      captured ESP payload carries NO `vt_*` vault token and NONE of the
      forbidden plaintext sentinels. This makes masking enforced-by-a-gate on
      EVERY adapter (incl. T94/T95), not adapter goodwill — a rogue adapter
      that hand-reveals or forwards the raw `vt_` `to_subscriber_id` is caught.

  `:tracking` has no dedicated C1 callback (open/click events ride the SAME
  `verify_and_parse_event/3` seam as bounce/complaint) — its honesty is proven
  downstream by C4/T30's consent-gated open/click dispatch, not by this
  harness; declaring it here only asserts it is a legal member of the
  `capabilities()` return value.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    fixtures_dir = Keyword.fetch!(opts, :fixtures)
    capabilities = Keyword.fetch!(opts, :capabilities)

    quote bind_quoted: [provider: provider, fixtures_dir: fixtures_dir, capabilities: capabilities] do
      use ExUnit.Case, async: true

      alias Samen.Delivery.ProviderConformanceCase, as: Harness

      @conformance_provider provider
      @conformance_fixtures_dir fixtures_dir
      @conformance_capabilities capabilities

      setup_all do
        {:ok, fixtures: Harness.load_fixtures!(@conformance_fixtures_dir)}
      end

      describe "ADR-038 §4.5(e): capabilities/0 matches the declared list" do
        test "the provider's capabilities/0 == the capabilities the harness was told about" do
          Harness.assert_capabilities_match!(@conformance_provider, @conformance_capabilities)
        end
      end

      describe "ADR-038 §4.5(a): the unconfigured table — every callback refuses honestly" do
        test "unconfigured refuses every callback (never a fake {:ok, _})", %{fixtures: fixtures} do
          Harness.assert_unconfigured_table!(@conformance_provider, @conformance_capabilities, fixtures)
        end
      end

      describe "ADR-038 §4.5(b): configured deliver/2 against the fixture transport" do
        test "returns a receipt carrying :provider_message_id", %{fixtures: fixtures} do
          Harness.assert_deliver_ok!(@conformance_provider, fixtures)
        end
      end

      describe "ADR-038 §4.5(f) / C3 (T29): deliver/2 leaks NO vault token or PII to the ESP (INV-1)" do
        test "the captured outbound ESP payload carries no vt_ token and no forbidden plaintext",
             %{fixtures: fixtures} do
          Harness.assert_deliver_no_leak!(@conformance_provider, fixtures)
        end
      end

      describe "ADR-038 §4.5(d): redaction — no PII fixture string survives redact_payload/1" do
        test "redact_payload/1 strips every known-PII fixture string", %{fixtures: fixtures} do
          Harness.assert_redaction!(@conformance_provider, fixtures)
        end
      end

      if :deliverability_webhooks in capabilities do
        describe "ADR-038 §4.5(c)+(e): webhook red/green (declared :deliverability_webhooks)" do
          test "a valid fixture parses; a tampered one refuses :invalid_signature, parses nothing",
               %{fixtures: fixtures} do
            Harness.assert_webhook_red_green!(@conformance_provider, fixtures)
          end
        end
      else
        describe "ADR-038 §4.5(e): capability honesty (undeclared :deliverability_webhooks)" do
          test "verify_and_parse_event/3 always refuses :not_implemented, even configured",
               %{fixtures: fixtures} do
            Harness.assert_undeclared_refuses!(
              @conformance_provider,
              :verify_and_parse_event,
              fixtures.configured_config
            )
          end
        end
      end

      if :inbound in capabilities do
        describe "ADR-038 §4.5(e): parse_inbound/3 (declared :inbound)" do
          test "a valid inbound fixture parses to a real InboundMessage", %{fixtures: fixtures} do
            Harness.assert_inbound_ok!(@conformance_provider, fixtures)
          end
        end
      else
        describe "ADR-038 §4.5(e): capability honesty (undeclared :inbound)" do
          test "parse_inbound/3 always refuses :not_implemented, even configured", %{fixtures: fixtures} do
            Harness.assert_undeclared_refuses!(@conformance_provider, :parse_inbound, fixtures.configured_config)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers (called from the generated tests above — kept out of the
  # macro body so failures report a clean, direct stack frame). These use
  # `ExUnit.Assertions` (the house convention `Samen.RedPath`/`Samen.MaskingCase`
  # already follow) rather than hand-built exceptions.

  import ExUnit.Assertions

  @doc false
  def load_fixtures!(fixtures_dir) do
    # SHIM: delegates to the general kit's loader (same relative-to-package-root
    # path join + Code.eval_file, ADR-038 §7.2). Kept as a same-name/arity
    # wrapper here so the macro body above needs no change.
    Samen.AdapterConformanceCase.load_fixtures!(fixtures_dir)
  end

  @doc false
  def assert_capabilities_match!(provider, declared_capabilities) do
    actual = provider.capabilities()

    assert Enum.sort(actual) == Enum.sort(declared_capabilities),
           "#{inspect(provider)}.capabilities/0 returned #{inspect(actual)} but the harness was " <>
             "told #{inspect(declared_capabilities)} — the `use Samen.Delivery.ProviderConformanceCase, " <>
             "capabilities: [...]` argument must match the real capabilities/0 value exactly."

    :ok
  end

  @doc false
  def assert_unconfigured_table!(provider, declared_capabilities, fixtures) do
    unconfigured = %{}
    message = struct!(Samen.Delivery.Message, atomize_message(fixtures.message))

    refute provider.configured?(unconfigured),
           "#{inspect(provider)}.configured?/1 must be false for an empty config (%{})"

    case provider.deliver(message, unconfigured) do
      {:error, :not_configured} ->
        :ok

      other ->
        flunk(
          "#{inspect(provider)}.deliver/2 must refuse {:error, :not_configured} when " <>
            "unconfigured, got: #{inspect(other)}"
        )
    end

    assert_capability_gated_refusal!(
      provider,
      :verify_and_parse_event,
      :deliverability_webhooks,
      declared_capabilities,
      fn -> provider.verify_and_parse_event(fixture_binary(fixtures, [:webhook, :valid, :body]), [], unconfigured) end
    )

    assert_capability_gated_refusal!(
      provider,
      :parse_inbound,
      :inbound,
      declared_capabilities,
      fn -> provider.parse_inbound(fixture_binary(fixtures, [:inbound, :body]), [], unconfigured) end
    )

    :ok
  end

  # A capability-gated callback: if the capability IS declared, unconfigured
  # must refuse :not_configured (it genuinely tries real work, gated on
  # configured?/1); if the capability is NOT declared, it must refuse
  # :not_implemented regardless (the honest absence, per the `use` default).
  defp assert_capability_gated_refusal!(provider, callback_name, capability, declared_capabilities, invoke) do
    expected = if capability in declared_capabilities, do: :not_configured, else: :not_implemented

    case invoke.() do
      {:error, ^expected} ->
        :ok

      other ->
        flunk(
          "#{inspect(provider)}.#{callback_name}/3 (capability #{inspect(capability)} " <>
            "declared=#{capability in declared_capabilities}) must refuse {:error, #{inspect(expected)}} " <>
            "while unconfigured, got: #{inspect(other)}"
        )
    end
  end

  @doc false
  def assert_deliver_ok!(provider, fixtures) do
    message = struct!(Samen.Delivery.Message, atomize_message(fixtures.message))

    case provider.deliver(message, fixtures.configured_config) do
      {:ok, receipt} when is_map(receipt) ->
        id = Map.get(receipt, :provider_message_id)

        assert is_binary(id) and id != "",
               "#{inspect(provider)}.deliver/2's configured receipt must carry a non-empty " <>
                 ":provider_message_id, got receipt: #{inspect(receipt)}"

      other ->
        flunk(
          "#{inspect(provider)}.deliver/2 with the fixture's configured_config must return " <>
            "{:ok, receipt} (offline, via the fixture transport), got: #{inspect(other)}"
        )
    end
  end

  @doc """
  ADR-038 §4.5(f) / C3 (T29) — the INV-1 enforcement gate every adapter must
  pass (non-skippable, part of the base conformance run). Makes masking
  enforced-by-a-gate rather than adapter goodwill: runs the adapter's REAL
  `deliver/2` with a harness-supplied CAPTURE transport, then asserts the
  outbound ESP request the adapter actually built carries NO `vt_*` vault token
  and NONE of the forbidden plaintext sentinels. A rogue/careless adapter that
  hand-reveals vault fields or forwards the raw token-only message's
  `to_subscriber_id` (a `vt_` token) into its request is CAUGHT here — proven
  refutable by `Samen.Delivery.DeliverLeakGateTest`'s rogue adapter.

  Requires `fixtures.deliver_leak_probe`:

      deliver_leak_probe: %{
        # arity-1: given the harness capture fn, return a configured_config that
        # routes deliver/2's outbound request THROUGH that capture (the §7.2
        # injectable transport hook). deliver's RESULT is ignored — only the
        # captured outbound request is inspected.
        build_config: fn capture -> %{..., transport: capture} end,
        # a token-only message field map; set to_subscriber_id to a vt_-shaped
        # value so a conformant adapter is PROVEN not to forward the raw token.
        message: %{send_id: "...", org_id: "...", to_subscriber_id: "vt_...", template_id: nil},
        # a plaintext sentinel that must NOT appear in the outbound payload
        forbidden_plaintext: "OTHER-SUBJECT-SENTINEL@leak.test"
      }
  """
  def assert_deliver_no_leak!(provider, fixtures) do
    probe =
      Map.get(fixtures, :deliver_leak_probe) ||
        flunk(
          "Samen.Delivery.ProviderConformanceCase: fixtures.deliver_leak_probe is REQUIRED " <>
            "(ADR-038 §4.5(f) / C3 T29, INV-1). Every adapter MUST prove its deliver/2 " <>
            "outbound ESP payload carries no vault token or unresolved PII — this gate is " <>
            "non-skippable. See the harness moduledoc for the deliver_leak_probe shape."
        )

    message = struct!(Samen.Delivery.Message, atomize_message(probe.message))
    forbidden = Map.get(probe, :forbidden_plaintext)
    forbidden_list = if is_binary(forbidden), do: [forbidden], else: []

    # SHIM: the ESP-specific probe setup (deliver_leak_probe shape, message
    # struct, non-skippable precheck above) stays here; the capture/assert
    # mechanics themselves — same Agent-based capture, same "must capture at
    # least one request" check, same vt_ check, same forbidden-plaintext
    # check — now delegate to the general kit (ADR-038 §4.5(f) / C3 T29,
    # INV-1 stay enforced identically; the gate stays armed).
    invoke = fn capture ->
      config = probe.build_config.(capture)

      # The deliver RESULT is irrelevant; the outbound request was captured
      # before the adapter processed the transport return. Guard against any
      # handler that raises on the probe's error return.
      try do
        provider.deliver(message, config)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    Samen.AdapterConformanceCase.assert_capture_no_leak!(invoke, forbidden_list)
  end

  @doc false
  def assert_redaction!(provider, fixtures) do
    # SHIM: delegates to the general kit's redaction property (same PII-string
    # check, same retained-keys anti-tautology check, same empty-map guard) —
    # ADR-038 §4.5(d) stays enforced identically.
    %{payload: payload, pii_strings: pii_strings} = fixtures.redaction
    retained_keys = Map.get(fixtures.redaction, :retained_keys, [])

    Samen.AdapterConformanceCase.assert_redaction!(&provider.redact_payload/1, payload,
      pii_strings: pii_strings,
      retained_keys: retained_keys
    )
  end

  @doc false
  def assert_webhook_red_green!(provider, fixtures) do
    %{valid: valid, tampered: tampered} = fixtures.webhook
    config = fixtures.configured_config

    case provider.verify_and_parse_event(valid.body, valid.headers, config) do
      {:ok, %Samen.Delivery.ProviderEvent{}} ->
        :ok

      other ->
        flunk(
          "#{inspect(provider)}.verify_and_parse_event/3 must parse the VALID webhook fixture " <>
            "to {:ok, %Samen.Delivery.ProviderEvent{}}, got: #{inspect(other)}"
        )
    end

    case provider.verify_and_parse_event(tampered.body, tampered.headers, config) do
      {:error, :invalid_signature} ->
        :ok

      other ->
        flunk(
          "#{inspect(provider)}.verify_and_parse_event/3 must refuse {:error, :invalid_signature} " <>
            "(and parse NOTHING) for the TAMPERED webhook fixture, got: #{inspect(other)}"
        )
    end
  end

  @doc false
  def assert_inbound_ok!(provider, fixtures) do
    %{body: body, headers: headers} = fixtures.inbound

    case provider.parse_inbound(body, headers, fixtures.configured_config) do
      {:ok, %Samen.Delivery.InboundMessage{}} ->
        :ok

      other ->
        flunk(
          "#{inspect(provider)}.parse_inbound/3 must parse the inbound fixture to " <>
            "{:ok, %Samen.Delivery.InboundMessage{}}, got: #{inspect(other)}"
        )
    end
  end

  @doc false
  def assert_undeclared_refuses!(provider, callback_name, configured_config) do
    result =
      case callback_name do
        :verify_and_parse_event -> provider.verify_and_parse_event("{}", [], configured_config)
        :parse_inbound -> provider.parse_inbound("{}", [], configured_config)
      end

    case result do
      {:error, :not_implemented} ->
        :ok

      other ->
        flunk(
          "#{inspect(provider)}.#{callback_name}/3 declares no matching capability, so it must " <>
            "ALWAYS refuse {:error, :not_implemented} — even when CONFIGURED. Got: #{inspect(other)}"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers

  defp atomize_message(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  end

  defp fixture_binary(fixtures, path) do
    case get_in(fixtures, path) do
      nil -> "{}"
      value -> value
    end
  end
end
