defmodule Samen.Billing.InvoiceMirror do
  @moduledoc """
  The **invoice mirror port** `Samen.Billing.Invoice` (B4+B6; T22) writes through
  (ADR-038 §3.4 convergence model — fetch-on-event — applied to the invoice object,
  §3.5 "the Invoice mirror gains tax fields + hosted invoice/receipt URLs").

  ## Why a SEPARATE port from `Samen.Billing.Mirror` / `Samen.Billing.CheckoutMirror`

  Each object kind gets its own reconcile module + its own mirror port — the pattern
  T20 (checkout) established over T21's subscription `Mirror`, and this task follows
  for invoices: `Samen.Billing.Invoice.reconcile/2` is the invoice-kind convergence
  logic; `Samen.Billing.InvoiceMirror` is the storage seam it writes through.

  Unlike T21's subscription `Mirror` (deferred to a production impl, GAP T21-G1 — no
  new columns existed on `Subscription` for the watermark), the invoice mirror ships
  the REAL Ash-backed impl NOW (`Samen.Billing.AshInvoiceMirror`), because:

    * The convergence bookkeeping an invoice needs is minimal — the blueprint's
      pre-existing, ratcheted vendor-ref carve-out attribute is the natural key; the
      ONE new field this task adds for bookkeeping is `last_event_id` (a plain
      framework-owned column, NOT the Tier-1 `custom` bag — that engine is a
      closed-world, org-declared field set that rejects any key without a
      `tnt_field` definition). No out-of-order watermark is needed (see below).
    * Every fetched invoice snapshot is authoritative and idempotent-by-upsert on
      the SAME natural key regardless of which kind (`:invoice_finalized` /
      `:invoice_paid`) triggered the fetch — there is no separate "activation vs.
      convergence" row-ownership split like checkout/subscription have (§ below).

  ## The two-step contract (mirrors `Samen.Billing.Mirror`'s shape)

    1. `read_state/2` — reads the mirror row's bookkeeping for a
       `provider_invoice_id`: does a row exist, and its `last_event_id` (the
       event that produced the CURRENT state). Used for the idempotency short-circuit
       (an exact-event replay is a no-op) — `Samen.Billing.Invoice.reconcile/2` does
       NOT need an out-of-order watermark guard the way subscription sync does,
       because every invoice event triggers the SAME re-fetch of the SAME
       authoritative object; two different kinds (`finalized` then `paid`) converge
       to the CURRENT truth regardless of delivery order (there is no "clobber an
       already-applied later status with an earlier snapshot" hazard: the fetch
       always returns whatever is true NOW). This is the "coherent, not
       double-guarded" idempotency story the task calls for — T19's ingress
       `{provider, event_id}` unique index already makes an exact-duplicate
       DELIVERY a no-op before this port is ever called; `last_event_id` here
       covers the DLQ-replay / at-least-once-retry re-dispatch case, exactly like
       `Samen.Billing.Mirror`'s `last_event_id` bookkeeping.
    2. `upsert/2` — writes the mirror row from the AUTHORITATIVE snapshot (obtained
       via the provider's `fetch_object(:invoice, …)`, never from the event payload
       — §3.4(1)). Idempotent by `provider_invoice_id`: a first delivery CREATES the
       row; every subsequent delivery (a later status, a replay, an out-of-order
       arrival) UPDATES the SAME row. Tax fields and hosted links are mirrored
       VERBATIM — `nil`/`[]` when the provider's snapshot carries no tax data
       (fail-honest; ADR-014 shape applied to tax, never a fabricated `0`).

  ## Implementations

    * `Samen.Billing.FakeInvoiceMirror` — in-memory, ships in lib (test infra
      precedent, mirrors `FakeMirror`/`FakeCheckoutMirror`). Proves
      `Samen.Billing.Invoice.reconcile/2`'s routing/idempotency hermetically.
    * `Samen.Billing.AshInvoiceMirror` — the REAL, resource-module-agnostic impl.
      References ONLY Ash (not a vendor — INV-4 concerns the billing vendor/HTTP
      deps). The host's concrete Invoice resource module + its provider-ref
      attribute name are resolved via the `ref` map, exactly like
      `Samen.Billing.AshCheckoutMirror`.
  """

  @type ref :: term()

  @type upsert_attrs :: %{
          required(:org_id) => String.t(),
          required(:snapshot) => map(),
          optional(:customer_ref) => String.t() | nil,
          optional(:subscription_ref) => String.t() | nil,
          optional(:event_id) => String.t()
        }

  @type state :: %{exists: boolean(), last_event_id: String.t() | nil}

  @doc """
  Read the convergence bookkeeping for a `provider_invoice_id`. An absent row is
  `%{exists: false, last_event_id: nil}` (the first-delivery case) — the idempotency
  short-circuit `Samen.Billing.Invoice.reconcile/2` checks BEFORE the authoritative
  re-fetch (avoiding a wasted provider round-trip on a known exact-event replay).
  """
  @callback read_state(ref(), provider_invoice_id :: String.t()) :: {:ok, state()} | {:error, term()}

  @doc """
  Upsert the invoice mirror row from `attrs.snapshot` (keyed on
  `provider_invoice_id`). MUST be idempotent by `provider_invoice_id`: creates on
  first delivery, updates in place on every subsequent one. Returns `{:ok, map()}`
  (an impl-defined summary, e.g. `%{invoice_id:, created: true|false}`) or
  `{:error, term()}`.
  """
  @callback upsert(ref(), upsert_attrs()) :: {:ok, map()} | {:error, term()}
end
