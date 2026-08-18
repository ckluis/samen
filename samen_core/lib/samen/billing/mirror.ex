defmodule Samen.Billing.Mirror do
  @moduledoc """
  The **mirror port** the `Samen.Billing.Reconciler` (B3 lifecycle sync; T21) writes
  through (ADR-038 §3.4 convergence model).

  ADR-038 §2 splits responsibility: **adapters translate and transport; core owns
  state and convergence.** The reconciler is the vendor-generic convergence brain; the
  *storage* of the subscription mirror + entitlement rows is a host concern (the
  governed Ash resources materialized by `Samen.Scopes.Billing`). This behaviour is the
  seam between them so the reconciler stays storage-agnostic and fully provable
  hermetically:

    * `Samen.Billing.FakeMirror` — the shipped in-memory impl (ships in lib, per the
      `Samen.RedPath`/`Samen.Factory` "test infra in lib" precedent). The adapter
      package's lifecycle sync test + the core reconciler test converge against it.
    * The PRODUCTION impl — an Ash-backed mirror writing the host's governed
      `Subscription`/`Entitlement` resources (resource modules + the provider-ref field
      name resolved from host config, so `samen_core` never names a vendor) — is the
      documented next step (GAP T21-G1). It needs the subscription convergence
      bookkeeping (watermark + last-applied event id) stored either as dedicated
      `Subscription` columns or in a catalog-exempt core infra table (the
      `Samen.Webhook.Event` precedent); the port + reconciler are ready for it unchanged.

  ## The two-step convergence contract

  The reconciler NEVER blind-writes. For every subscription event it:

    1. `read_state/2` — reads the mirror row's convergence bookkeeping for a
       `provider_subscription_id`: does a row exist, what is its stored **watermark**
       (the `occurred_at` of the last event applied to it), and the `last_event_id`
       that produced the current state. The reconciler uses these to decide
       idempotency (same `event_id` again ⇒ no-op) and out-of-order safety (a strictly
       older event ⇒ discarded, never a clobber — ADR-038 §3.4(3)).
    2. `write_snapshot/3` — upserts the mirror row from the AUTHORITATIVE snapshot
       (obtained by the reconciler via the provider's `fetch_object/3`, never from the
       event payload — §3.4(1)) and performs the entitlement transition. Idempotent by
       `provider_subscription_id`.

  ## Snapshot shape (the normalized, vendor-neutral subscription map)

  `write_snapshot/3` receives a map with atom keys (the adapter's `fetch_object/3`
  return, enriched by the reconciler with the convergence markers):

      %{
        provider_subscription_id: String.t(),        # the mirror's natural key
        provider_customer_id: String.t() | nil,
        status: :active | :trialing | :past_due | :cancelled | :unpaid | :inactive,
        current_period_start: DateTime.t() | nil,
        current_period_end:   DateTime.t() | nil,
        trial_end:            DateTime.t() | nil,
        cancel_at:            DateTime.t() | nil,
        cancelled_at:         DateTime.t() | nil,
        plan_ref:             String.t() | nil,       # provider price/plan id
        proration_amount_cents: integer() | nil,      # MIRRORED from the provider, never computed
        currency:             String.t() | nil,
        provider_event_at:    DateTime.t(),           # the applied event's monotonic marker (watermark)
        last_event_id:        String.t()              # the applied event id (idempotency key)
      }

  ## Entitlement transition (the T24/T23 seam — keep it clean)

  The third `write_snapshot/3` argument is the entitlement action the reconciler
  derived from the terminal subscription state:

    * `:active`             — the subscription is live; entitlements stay in force
      (and, per the T24 recovery seam below, any previously-set grace expiry is
      CLEARED — full access restored, not merely "left as-is").
    * `{:grace_until, dt}`  — a cancel (scheduled or effected): entitlements END AT
      PERIOD END (`dt`), NOT immediately (grace). This is the exact seam T24 dunning
      and T23 payment-methods build on — a cancelled sub keeps access through the paid
      period.
    * `:none`              — no entitlement change implied (e.g. a metadata-only update).

  ## `apply_entitlement/3` (T24 — the dunning grace/recovery seam)

  `Samen.Billing.Reconciler` drives entitlement transitions off a FULL subscription
  convergence (`write_snapshot/3`) — every call also updates the subscription
  snapshot + watermark bookkeeping. `Samen.Billing.Dunning` (T24; B7) is driven off
  `:invoice_payment_failed`/`:invoice_paid` events instead — an INVOICE-level
  convergence that must NEVER touch the subscription-lifecycle reconciler's own
  watermark/`last_event_id` bookkeeping (a partial/invoice-shaped "snapshot" written
  through `write_snapshot/3` would clobber it). `apply_entitlement/3` is the narrow,
  entitlement-ONLY seam dunning writes through instead: same `entitlement_action()`
  vocabulary, but it touches ONLY the entitlement rows for `provider_subscription_id`,
  never the subscription mirror row itself.
  """

  @type ref :: term()

  @type snapshot :: %{
          required(:provider_subscription_id) => String.t(),
          optional(atom()) => term()
        }

  @type state :: %{
          exists: boolean(),
          watermark: DateTime.t() | nil,
          last_event_id: String.t() | nil
        }

  @type entitlement_action :: :active | :none | {:grace_until, DateTime.t() | nil}

  @doc """
  Read the convergence bookkeeping for a `provider_subscription_id`. An absent row is
  `%{exists: false, watermark: nil, last_event_id: nil}` (the first-delivery case).
  """
  @callback read_state(ref(), provider_subscription_id :: String.t()) :: {:ok, state()} | {:error, term()}

  @doc """
  Upsert the subscription mirror from `snapshot` (keyed on `provider_subscription_id`)
  and perform `entitlement_action`. MUST be idempotent by `provider_subscription_id`.
  Returns `{:ok, applied}` (an impl-defined summary map) or `{:error, reason}`.
  """
  @callback write_snapshot(ref(), snapshot(), entitlement_action()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  T24 — apply an entitlement-ONLY transition for `provider_subscription_id`,
  independent of a full subscription-snapshot convergence. Used by
  `Samen.Billing.Dunning` for the grace-on-payment-failure / restore-on-recovery
  seam so a dunning-driven entitlement flip never resets the subscription
  reconciler's own watermark/`last_event_id` bookkeeping. Returns `{:ok, map()}`
  (an impl-defined summary) or `{:error, term()}`.
  """
  @callback apply_entitlement(ref(), provider_subscription_id :: String.t(), entitlement_action()) ::
              {:ok, map()} | {:error, term()}
end
