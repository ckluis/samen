defmodule Samen.Billing.Provider do
  @moduledoc """
  Core-defined billing provider contract (ADR-038 §3; T18/B1).

  A host application selects an external billing provider via host config:

      config :samen_core, :billing_provider, {MyBillingAdapter.Provider, %{secret_key: "..."}}

  `samen_core` defines this behaviour, the normalized `Samen.Billing.ProviderEvent`
  struct, and the honest `Samen.Billing.FakeProvider` test double. It references NO
  vendor module and pulls NO HTTP client — every vendor SDK/HTTP dependency lives in
  a separate, first-party-but-separate adapter package, per INV-4 (ADR-038 §8).

  ## The fail-honest contract (ADR-014 shape, binding — ADR-038 §3.2)

  Every callback except `configured?/1` and `redact_payload/1` returns
  `{:error, :not_configured}` when `configured?/1` is `false` for the same config —
  NEVER a fake `{:ok, _}`, never a partial success. A capability the vendor
  genuinely lacks returns `{:error, :not_implemented}` instead. This mirrors the
  `Samen.Delivery.Provider` / `Samen.Files.Storage.S3` precedents: a stub that claims
  success for work it did not do is the exact lie this contract exists to forbid.

  ## Supersession of `Samen.Scopes.Billing.SyncAdapter` (ADR-038 §3.6)

  This behaviour REPLACES `Samen.Scopes.Billing.SyncAdapter` (deleted by this task).
  The old `SyncAdapter.Stub` always returned a fake `{:ok, %{stub: true}}` — the
  tautological-success shape ADR-014 abolished for delivery. `Samen.Billing.FakeProvider`
  is call-recording like the old `Stub`, but honest: an unconfigured fake refuses.
  """

  alias Samen.Billing.ProviderEvent

  @doc """
  Returns `true` when the provider has everything it needs to actually call out
  (creds, endpoint, etc.), `false` otherwise. Every other callback (except
  `redact_payload/1`) MUST refuse with `{:error, :not_configured}` when this is
  `false` for the same `config` — this predicate is the single source of truth
  (ADR-038 §3.5 B10: the billing settings page renders on this same predicate,
  no separate flag to drift).
  """
  @callback configured?(config :: map()) :: boolean()

  @doc """
  B2 — hosted checkout. `attrs`: `%{org_id, plan_id, price_ref, success_url,
  cancel_url, customer_ref}`. Returns the provider's hosted checkout session
  reference + redirect URL on success.
  """
  @callback create_checkout_session(attrs :: map(), config :: map()) ::
              {:ok, %{provider_session_id: String.t(), url: String.t()}} | {:error, term()}

  @doc """
  B5 — payment methods via HOSTED surfaces only (billing portal / setup session
  URL). Card data NEVER transits samen (ADR-038 §3.5 no-PAN rule). `attrs`:
  `%{org_id, customer_ref, return_url, billing_name (optional), billing_email
  (optional)}` — the caller (`Samen.Billing.PaymentMethod.create_portal_session/2`)
  has already vault-RESOLVED `billing_name`/`billing_email` (the Customer
  blueprint's only two PII fields) and reduced `attrs` to this CLOSED whitelist
  before the adapter ever sees it. An adapter that wants to sync those two
  fields onto the vendor's customer object applies its OWN hardcoded
  name/email-only whitelist when building the outbound form — two independent
  whitelists, no drift.
  """
  @callback create_portal_session(attrs :: map(), config :: map()) ::
              {:ok, %{url: String.t()}} | {:error, term()}

  @doc """
  B3 — lifecycle mutation initiated samen-side: cancel a subscription, with
  proration behavior opts (e.g. `at_period_end: true`).
  """
  @callback cancel_subscription(
              provider_subscription_id :: String.t(),
              opts :: keyword(),
              config :: map()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  B3 — lifecycle mutation initiated samen-side: change a subscription (plan/price
  change) with proration behavior opts.
  """
  @callback change_subscription(
              provider_subscription_id :: String.t(),
              changes :: map(),
              config :: map()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Convergence primitive (ADR-038 §3.4): authoritative re-fetch of a provider
  object, normalized to samen field names. The core `Samen.Billing.Reconciler`
  (T21) calls this on every verified webhook event and upserts the mirror from the
  returned snapshot — NEVER from the event payload directly.
  """
  @callback fetch_object(
              kind :: :customer | :subscription | :invoice | :payment_method_summary,
              provider_id :: String.t(),
              config :: map()
            ) :: {:ok, normalized :: map()} | {:error, :not_found | term()}

  @doc """
  B8 — metered usage reporting. Each record in `batch` carries an idempotency key
  derived from the `UsageRecord` id, so a retried batch is a safe no-op provider-side.
  """
  @callback report_usage(batch :: [map()], config :: map()) ::
              {:ok, %{reported: non_neg_integer()}} | {:error, term()}

  @doc """
  §5 ingress — verify the vendor webhook signature scheme and normalize the payload
  into a `Samen.Billing.ProviderEvent`. The vendor signature scheme lives entirely
  in the adapter; `samen_core`/`samen_web` never parse a vendor signature header.
  """
  @callback verify_and_parse_event(
              raw_body :: binary(),
              headers :: [{String.t(), String.t()}],
              config :: map()
            ) ::
              {:ok, ProviderEvent.t()}
              | {:error, :invalid_signature | :stale_timestamp | :malformed | term()}

  @doc """
  §5.4 PII pruning of a raw vendor payload BEFORE the envelope is persisted. A pure
  function — it must not need creds or network access, so it is exempt from the
  `configured?/1` fail-honest gate (it runs even when the provider is unconfigured,
  since redaction is a data-shape concern, not a network capability).
  """
  @callback redact_payload(payload :: map()) :: map()
end
