defmodule Samen.Delivery.Provider do
  @moduledoc """
  Core-defined delivery-provider contract (ADR-038 §4; T27/C1). **Finalizes and
  REPLACES** `Samen.Delivery.Adapter` (deleted by this task, ADR-038 §4.2) — same
  two ADR-014 callbacks (`configured?/1`, `deliver/2`), same Invariant D1, PLUS the
  webhook/inbound/capability surface C4/C5/C8 need. `Samen.Delivery.Smtp`,
  `Samen.Delivery.LocalSink`, and `Samen.Delivery.Api` migrate to this behaviour;
  their existing semantics do not change.

  A host application selects a delivery provider via host config (host default)
  with an optional per-org override resolved by `Samen.Delivery.ProviderSelection`
  (ADR-038 §4.3):

      config :samen_core, :delivery_provider, {MyEspAdapter.Provider, %{api_key: "..."}}

  `samen_core` defines this behaviour, the normalized `Samen.Delivery.ProviderEvent`
  / `Samen.Delivery.InboundMessage` structs, the honest `Samen.Delivery.FakeProvider`
  test double, and the shared `Samen.Delivery.ProviderConformanceCase` test harness.
  It references NO vendor module and pulls NO HTTP client — every vendor SDK/HTTP
  dependency lives in a separate, first-party-but-separate adapter package
  (three ship under ADR-038 §8.1), per INV-4 (ADR-038 §8).

  ## The fail-honest contract (ADR-014 shape, binding — ADR-038 §3.2/§4.1)

  Every callback except `configured?/1` and `redact_payload/1` returns
  `{:error, :not_configured}` when `configured?/1` is `false` for the same
  config — NEVER a fake `{:ok, _}`, never a partial success. A capability the
  adapter genuinely lacks (undeclared in `capabilities/0`) returns
  `{:error, :not_implemented}` instead, REGARDLESS of configured state — the
  honest "this adapter does not do that" answer, checked in BOTH directions by
  `Samen.Delivery.ProviderConformanceCase` (§4.5e): a declared capability must
  have a real implementation; an undeclared one must always refuse.

  ## `use Samen.Delivery.Provider` — the minimal two-function adapter

  `use Samen.Delivery.Provider` injects overridable, fail-honest defaults for
  `capabilities/0` (`[]`), `verify_and_parse_event/3` and `parse_inbound/3`
  (`{:error, :not_implemented}`), AND `redact_payload/1` (identity pass-through —
  a no-op is honest here since an adapter declaring no webhook capability never
  receives a real vendor payload to redact). This is what lets a minimal adapter
  (SMTP/LocalSink-shaped) implement only `configured?/1` + `deliver/2` and stay
  fully conformant.
  """

  alias Samen.Delivery.{InboundMessage, Message, ProviderEvent}

  @typedoc "The bounded, honestly-declared capability enum (ADR-038 §4.1)."
  @type capability :: :deliverability_webhooks | :inbound | :tracking

  @doc """
  Returns `true` when the provider has everything it needs to actually dispatch
  (creds, endpoint, etc.), `false` otherwise. Every other callback (except
  `redact_payload/1`) MUST refuse with `{:error, :not_configured}` when this is
  `false` for the same `config` — this predicate is the single source of truth.
  """
  @callback configured?(config :: map()) :: boolean()

  @doc """
  ADR-014 `deliver/2`, unchanged semantics. Returns `{:ok, receipt}` ONLY when
  the message was actually dispatched (or, for `LocalSink`, actually captured).
  The receipt MUST include `:provider_message_id` when the provider returns
  one — it is the token-blind join key for deliverability events (§4.4).
  """
  @callback deliver(message :: Message.t(), config :: map()) ::
              {:ok, receipt :: map()} | {:error, reason :: term()}

  @doc """
  Honest capability declaration; drives the conformance harness (§4.5) and
  router wiring. NOT config-dependent — capabilities are a property of the
  adapter module itself, not of a given runtime config.
  """
  @callback capabilities() :: [capability()]

  @doc """
  C4 — bounce/complaint/delivered/open/click. Verifies the vendor's webhook
  signature scheme (whatever shape that is for the vendor — HMAC, Basic Auth,
  SNS envelope, ...) and normalizes the payload into a `ProviderEvent` whose
  `payload` is ALREADY redacted (`redact_payload/1` has already run). A bad
  signature returns `{:error, :invalid_signature}` and parses NOTHING.
  """
  @callback verify_and_parse_event(
              raw_body :: binary(),
              headers :: [{String.t(), String.t()}],
              config :: map()
            ) ::
              {:ok, ProviderEvent.t()}
              | {:error, :invalid_signature | :malformed | :not_implemented | term()}

  @doc """
  C5 seam — inbound email. The reference ESP adapter package (ADR-038 §8.1) is
  the inbound-capable one; adapters without the `:inbound` capability return
  `{:error, :not_implemented}` (the honest absence, never a fake parse). NOT
  persisted here — mapping an `InboundMessage` into a ticket/thread is a
  downstream consumer's job (T59).
  """
  @callback parse_inbound(
              raw_body :: binary(),
              headers :: [{String.t(), String.t()}],
              config :: map()
            ) :: {:ok, InboundMessage.t()} | {:error, :not_implemented | term()}

  @doc """
  §5.4 PII pruning of a raw vendor payload BEFORE the envelope is persisted. A
  pure function — it must not need creds or network access, so it is exempt
  from the `configured?/1` fail-honest gate.
  """
  @callback redact_payload(payload :: map()) :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour Samen.Delivery.Provider

      @impl Samen.Delivery.Provider
      def capabilities, do: []

      @impl Samen.Delivery.Provider
      def verify_and_parse_event(_raw_body, _headers, _config), do: {:error, :not_implemented}

      @impl Samen.Delivery.Provider
      def parse_inbound(_raw_body, _headers, _config), do: {:error, :not_implemented}

      @impl Samen.Delivery.Provider
      def redact_payload(payload) when is_map(payload), do: payload

      defoverridable capabilities: 0,
                      verify_and_parse_event: 3,
                      parse_inbound: 3,
                      redact_payload: 1
    end
  end
end
