defmodule Samen.Billing.DunningMirror do
  @moduledoc """
  The **dunning-case mirror port** `Samen.Billing.Dunning` (B7; T24) writes
  through (ADR-038 §3.5 "B7 dunning (T24): driven exclusively from
  `:invoice_payment_failed` normalized events… Retry schedule is mirrored
  provider truth; the grace-period entitlement policy is core logic on the
  mirror").

  ## Why a SEPARATE port from `Samen.Billing.Mirror` / `Samen.Billing.InvoiceMirror`

  Each object kind gets its own reconcile module + its own mirror port (the
  pattern T20/checkout and T22/invoice established over T21's subscription
  `Mirror`). A "dunning case" is neither a subscription snapshot nor an invoice
  snapshot — it is the RETRY-SCHEDULE bookkeeping (`attempt_count`,
  `next_payment_attempt`, case `status`, the computed `grace_until` boundary)
  keyed by `provider_invoice_id`, the SAME natural key
  `Samen.Billing.InvoiceMirror` uses (a provider retries the SAME invoice
  across attempts). Keeping it a separate port means a dunning-driven write can never
  clobber the subscription reconciler's watermark/`last_event_id` bookkeeping
  (`Samen.Billing.Mirror.write_snapshot/3`) or the invoice mirror's own row
  (`Samen.Billing.InvoiceMirror.upsert/2`) — entitlement changes route through
  the narrow `Samen.Billing.Mirror.apply_entitlement/3` seam instead (see that
  module's moduledoc).

  ## The two-step contract (mirrors `Samen.Billing.InvoiceMirror`'s shape)

    1. `read_state/2` — reads the case bookkeeping for a `provider_invoice_id`:
       does a case exist, its `status` (`:open | :recovered`), the
       `provider_subscription_id` it applies to, the `last_event_id` that
       produced the current state (the idempotency short-circuit — an exact
       replay of the event that already produced the current row is a no-op),
       AND `watermark` — the `occurred_at` of the last-applied event. This is
       the SAME out-of-order guard shape `Samen.Billing.Mirror`'s
       `read_state/2` carries for the subscription reconciler (ADR-038
       §3.4(3)): `Samen.Billing.Dunning` discards a strictly-OLDER event
       (`occurred_at < watermark`) as `{:ok, :stale}` — a distinct-event-id
       stale `:invoice_payment_failed` arriving AFTER a later `:invoice_paid`
       recovery must never re-open the case or re-clip entitlement just
       because its event_id differs from the one that closed it.
    2. `write_case/2` — upserts the case row from case `attrs` (the retry-schedule
       fields mirrored VERBATIM from the adapter's authoritative invoice
       snapshot — never recomputed here), STAMPING `occurred_at` so the NEXT
       `read_state/2` sees the advanced watermark. Idempotent by
       `provider_invoice_id`: a first delivery CREATES the row; every
       subsequent delivery (a further retry attempt, or a recovery) UPDATES
       THE SAME row in place.

  ## Implementations

    * `Samen.Billing.FakeDunningMirror` — in-memory, ships in lib (test infra
      precedent, mirrors `FakeMirror`/`FakeInvoiceMirror`/`FakeCheckoutMirror`).
      Proves `Samen.Billing.Dunning`'s routing/idempotency/retry-advance
      hermetically.
    * The REAL, Ash-backed impl is a documented GAP (same shape as the
      pre-existing `Samen.Billing.Mirror` GAP T21-G1): no host currently wires
      `:billing_dunning_mirror`, so dunning is honestly a safe `:ok` no-op
      everywhere until a host adds one (see `Samen.Billing.WebhookDispatch`).
  """

  @type ref :: term()

  @type state :: %{
          exists: boolean(),
          status: :open | :recovered | nil,
          provider_subscription_id: String.t() | nil,
          last_event_id: String.t() | nil,
          watermark: DateTime.t() | nil
        }

  @type case_attrs :: %{
          required(:provider_invoice_id) => String.t(),
          optional(:provider_subscription_id) => String.t() | nil,
          optional(:status) => :open | :recovered,
          optional(:attempt_count) => integer() | nil,
          optional(:next_payment_attempt) => DateTime.t() | nil,
          optional(:grace_until) => DateTime.t() | nil,
          optional(:occurred_at) => DateTime.t(),
          optional(:last_event_id) => String.t()
        }

  @doc """
  Read the case bookkeeping for a `provider_invoice_id`. An absent case is
  `%{exists: false, status: nil, provider_subscription_id: nil, last_event_id: nil,
  watermark: nil}` (the first-delivery case).
  """
  @callback read_state(ref(), provider_invoice_id :: String.t()) :: {:ok, state()} | {:error, term()}

  @doc """
  Upsert the dunning-case row from `attrs` (keyed on `provider_invoice_id`).
  MUST be idempotent by `provider_invoice_id`: creates on first delivery,
  updates in place on every subsequent one (a new retry attempt, or the
  recovery close). Returns `{:ok, map()}` (an impl-defined summary) or
  `{:error, term()}`.
  """
  @callback write_case(ref(), case_attrs()) :: {:ok, map()} | {:error, term()}
end
