# Stripe Tax — enabling automatic tax on invoices, and what samen mirrors

**The boundary.** Samen never computes tax. Tax law (jurisdiction, rate, exemptions, nexus) is a
compliance surface owned by the billing provider — samen's job (B4/B6, ADR-038 §3.5) is to mirror
whatever tax figure the provider's invoice snapshot carries, *exactly*, and to render its absence
*honestly* when the provider computed none. This guide covers: (1) how to turn on Stripe Tax so
invoices carry tax data at all, (2) which fields populate once it's on, and (3) the fail-honest
contract for what happens when it's off — samen's side of that contract, not Stripe's.

---

## 1 · Enabling Stripe Tax (operator setup — outside samen)

Stripe Tax is a **per-Stripe-account** feature, turned on in the Stripe Dashboard (Settings →
Tax), not a samen config flag:

1. Register your tax origin address and the jurisdictions you collect tax in (Stripe's own
   registration flow — samen has no part in this).
2. Enable **automatic tax** on the objects that need it — either globally (Dashboard default) or
   per-object at creation time (`automatic_tax[enabled]=true` on the Checkout Session /
   Subscription / Invoice the provider adapter creates).
3. Stripe then computes tax at invoice-finalization time using the customer's tax location
   (billing address / IP / explicitly-collected tax ID) and your registered jurisdictions.

Samen's checkout session creation (`Samen.Billing.Provider.create_checkout_session/2`, B2/T20)
does not itself set `automatic_tax` — that is an adapter-package (`samen_stripe`) or host-level
decision, since it is a Stripe account/tax-registration concern, not a samen kernel one. If your
adapter/host wants automatic tax on by default, it sets `automatic_tax[enabled]=true` in the
checkout-session/subscription form it builds. This guide describes what samen does with the
*result*, not how to configure Stripe's tax registration itself (see Stripe's own Tax
documentation for that — out of scope for this repo).

---

## 2 · What samen mirrors once tax is configured

The invoice mirror (`Samen.Billing.Invoice.reconcile/2` + `Samen.Billing.InvoiceMirror`, T22)
converges the `Invoice` resource's tax fields from the provider's authoritative invoice snapshot
(`Samen.Billing.Provider.fetch_object(:invoice, id, config)`) on every `invoice.finalized` /
`invoice.paid` webhook — never computed, only mirrored (ADR-038 §3.4(1)/(4), the same "provider is
the source of truth, samen never recomputes" rule proration already follows):

| Invoice field | Populated from | Shape |
|---|---|---|
| `tax_amount_cents` | the invoice's total computed tax (provider's `tax` field) | integer minor units, or `nil` (see §3) |
| `tax_lines` | the itemized tax breakdown (provider's per-jurisdiction tax amounts) | bounded jsonb list: `[%{"amount_cents" =>, "display_name" =>, "percentage" =>, "jurisdiction" =>}]`, or `[]` |
| `hosted_invoice_url` | the provider's hosted invoice page | string URL, or `nil` until the invoice is finalized |
| `hosted_receipt_url` | the provider's hosted receipt page (available once a payment/charge exists) | string URL, or `nil` until paid |

Amounts (`amount_due_cents`, `amount_paid_cents`) already include tax when tax is configured —
`tax_amount_cents` is the tax **portion** of `amount_due_cents`, broken out for display, never a
separate charge samen invents. `tax_lines` lets the tenant billing page show a jurisdiction-level
breakdown (e.g. "CA Sales Tax — 7.25% — $21.30") without samen knowing anything about tax law
itself — it is purely a mirror of whatever the provider's `total_tax_amounts`-shaped array
contained.

**No PDF mirroring** (ADR-038 §3.5) — only the provider's *hosted web pages* are linked; a
provider-generated PDF is never fetched or stored by samen.

---

## 3 · Fail-honest tax — the contract when tax is NOT configured (ADR-014 shape, applied to tax)

This is the load-bearing rule the done-criteria assert, and the reason this section exists as its
own guide rather than a footnote:

> **An invoice with no tax configured (or not applicable) mirrors `tax_amount_cents: nil` and
> `tax_lines: []` — NEVER a fabricated `0`.**

This is exactly the `{:error, :not_configured}` discipline ADR-014 established for delivery
adapters, applied to a *field* instead of a whole adapter call: absence is represented as absence
(`nil`/`[]`), never as a value that *looks* like a real answer. A `$0.00` tax figure is a claim —
"the provider computed tax and it came to zero" (e.g. a fully tax-exempt line item) — and that
claim must never be made when the truth is "tax was never computed at all." Collapsing those two
states into the same `0` would be a silent lie: an operator or tenant reading "$0.00 tax" would
reasonably conclude tax compliance was handled, when in fact it was never engaged.

**Where this is enforced:**

- **The adapter** (`samen_stripe`, `SamenStripe.Provider.fetch_object/3`) mirrors the provider's
  raw `tax`/`total_tax_amounts` fields as-is: absent → `nil`/`[]`. It never substitutes a `0` when
  those keys are missing from the provider's response.
- **The core mirror** (`Samen.Billing.Invoice.reconcile/2`, `Samen.Billing.AshInvoiceMirror`)
  passes the snapshot's tax fields straight through to the `Invoice` row — no default, no
  coalescing to `0` anywhere in the write path.
- **The tenant billing page** (`Samen.Web.Billing.InvoicesLive`) renders the Tax column via a
  dedicated `tax_display/1` helper: `nil` → an honest "—", an integer (including a genuine `0`) →
  the real dollar figure. The em-dash and `$0.00` are never interchangeable in the render.

**What each lane can honestly claim:** the keyless CI suites (lane 0, ADR-038 §7.1) prove BOTH
directions with real fixtures — `samen_stripe/test/invoice_mirror_test.exs` mirrors a fixture WITH
`total_tax_amounts` (asserting the exact figures land on the mirror) and a fixture with no tax
keys at all (asserting `nil`/`[]`, never `0`); `samen_web`'s
`billing_invoice_tax_links_test.exs` asserts the tenant page renders the fail-honest "—" and
never a fabricated "$0.00" in the Tax cell specifically. Nothing here claims Stripe Tax was
exercised live (that would need `STRIPE_TEST_KEY`, lane 1) — only that samen's mirror + render
path handles both the "tax configured" and "tax absent" shapes honestly.

---

## 4 · Operator-plane posture (INV-2 — token-blind, tenant-side links only)

The hosted invoice/receipt links are rendered **tenant-side only**. The operator plane (viewing a
tenant's invoices under impersonation/support access) sees invoice amounts, status, and the tax
figure — the same non-PII numeric fields it already sees — but never the `hosted_invoice_url` /
`hosted_receipt_url` links themselves, gated off entirely (not masked — absent from the DOM),
alongside the existing customer-name masking (`billing_name` stays `••••` on the operator plane
per the pre-existing two-plane guarantee). Following a hosted link off-platform lands on the
provider's own page, which may render customer-identifying details samen itself never displays —
keeping that link tenant-side-only is what keeps the operator plane's token-blind guarantee
end-to-end, not just within samen's own rendered HTML.
