# ADR-038-A — Billing persistence architecture (addendum to ADR-038)

Status: **Accepted** (T106, 2026-07-23). Binds **T108** (production mirror implementations).
Extends: ADR-038 §3.4, §3.5, §8.3. Consumes verdicts T20/T21/T22/T24/T25.

## Context

ADR-038 §3 defined the `Samen.Billing.Provider` behaviour and the fetch-on-event
convergence model (§3.4), but deferred the *persistence* architecture for the mirror
subsystem. Five mirror slots exist — `:billing_mirror` (subscription lifecycle, T21),
`:billing_checkout_mirror` (T20), `:billing_invoice_mirror` (T22),
`:billing_dunning_mirror` (T24), `:billing_usage_mirror` (T25) — each shipped and gated
hermetically against a `Fake*Mirror`. Every verifier routed the production Ash-backed
mirror (and, for T25, subscription-item ref modeling) to a follow-up. The re-scope
(2026-07-23) split that follow-up: **T106 (this ADR) DECIDES the architecture; T108
IMPLEMENTS it** without re-litigating any decision below. T106 also lands the INV-4
provider-ref rename (see §2 of the handoff / §8.3 reconciliation in ADR-038).

The judgment call: the governed Tier-1 `Subscription.custom` map REJECTS arbitrary keys
(the catalog is closed-world), so the reconciler's watermark cannot hide there. Persisting
it as dedicated blueprint columns forces a host-blueprint migration fan-out
(demo/driftwood/pawchart/samen_web migrations + `schema.dict.json` + gen_app golden regen).
The precedent `Samen.Webhook.Event` (`whk_event`) shows a catalog-exempt alternative:
kernel infrastructure as a plain `Ecto.Schema` with a self-qualifying column prefix and a
raw-Ecto write path, invisible to the per-tenant catalog.

## Decision (a) — Watermark / persistence schema approach: **catalog-exempt core infra-table**

**RULING (binding on T108):** the reconciler convergence watermark + `last_event_id`
idempotency marker persist in a **catalog-exempt core infra-table**, `Samen.Billing.Mirror`
state modeled as a plain `Ecto.Schema` on the `whk_event` precedent — NOT as new columns on
the `Subscription` blueprint. Concretely:

- One kernel infra-table (proposed `bms_mirror_state`, abbrev `bms`, all columns
  `bms_`-prefixed, self-qualifying storage idiom) keyed on `(provider, provider_object_type,
  provider_object_ref)` with a UNIQUE index on that triple. Columns:
  `provider`, `object_type` (`"subscription" | "invoice" | ...`), `object_ref`,
  `last_event_id`, `watermark_at` (see decision (d)), `org_id` (nilable, resolved during
  processing, exactly as `whk_event`), plus the standard `inserted_at`/`updated_at`.
- Written through **raw Ecto** (like `Samen.Webhook.Event.insert_received/2`), so it composes
  inside the same `Multi` as the mirror upsert and needs no Ash action surface.
- **Rationale — why NOT blueprint columns:** dedicated `Subscription`/`Entitlement` watermark
  columns would (1) require the closed-world catalog to admit framework-bookkeeping columns
  on a Tier-1 tenant resource, muddying the tenant-facing surface; (2) force the four hosts'
  committed migrations + `schema.dict.json` + gen_app golden to regenerate on every future
  watermark-shape change; (3) fan every mirror-internals change out across verticals. The
  infra-table localizes all convergence bookkeeping to `samen_core`, exactly as `whk_event`
  localizes ingress/replay state. The subscription STATE (status, period dates, entitlement
  rows) stays on the blueprint resources — only the convergence BOOKKEEPING moves to infra.
- **Fan-out cost owned:** this route AVOIDS host-blueprint fan-out. The infra-table's own
  migration is a `samen_core`-side concern generated into each host the same way `whk_event`'s
  is; T108 owns wiring it. (The T22 `Invoice.last_event_id` column already exists on the
  blueprint and is NOT retro-moved — see decision (b) convention note; new watermark state is
  what routes to the infra-table.)

## Decision (b) — Mirror-slot consolidation convention

**RULING (binding on T108), per slot:**

- **`:billing_mirror` (subscription lifecycle) + `:billing_checkout_mirror` → UNIFY on a
  shared-storage contract.** Both write the SAME `bsb_subscription` row keyed on the
  post-rename neutral `provider_subscription_ref`. They are NOT collapsed into one slot
  (checkout INSERT-activates; lifecycle UPDATE-converges — distinct triggers), but they share
  ONE storage contract: **the row is keyed on `provider_subscription_ref`, and both ports
  resolve/write that same row.** `AshCheckoutMirror` INSERTs (idempotent by
  `provider_subscription_ref`); the production `Mirror` UPDATEs by re-fetch. The DB-unique
  fence (decision (e)) makes the shared key structurally enforced. Coherence requirements
  T108 MUST honor: (i) the production `Mirror` keys the SAME `provider_subscription_ref`
  attribute `AshCheckoutMirror` wrote; (ii) it tolerates a NULL watermark on checkout-seeded
  rows (decision (e)).
- **`:billing_invoice_mirror` → STAY DISTINCT.** Invoice is its own object type (own resource,
  keyed on `provider_invoice_ref`, own `last_event_id`). No shared row with subscription.
- **`:billing_dunning_mirror` → STAY DISTINCT.** A dunning case is keyed on the provider
  invoice ref and carries its own lifecycle (open/advance/recover) + the `gate/2` watermark
  guard already shipped in T24. Distinct object type.
- **`:billing_usage_mirror` → STAY DISTINCT.** Batch-pull over `Usage.reported_at`; keyed on
  the subscription-item ref (decision (c)). Distinct object type.

**Convention for future object types (e.g. T23 payment methods):** *slots UNIFY only when two
ports write the SAME row of the SAME object type keyed on the SAME neutral provider ref
(insert-vs-update over one identity); otherwise they STAY DISTINCT.* A payment-method mirror is
a distinct object type keyed on `provider_customer_ref` + a provider payment-method ref → it
STAYS DISTINCT under this rule.

## Decision (c) — Subscription-item `si_` modeling (GAP T25-G2)

**RULING (design; impl is T108):** the metered-usage endpoint keys on a subscription-ITEM ref
(`si_…`), not the subscription ref (`sub_…`) the mirror stores. The production `UsageMirror`
persists **per-item refs alongside** the subscription, NOT by overloading
`provider_subscription_ref`:

- Add a bounded per-item collection to the subscription mirror state — a
  `subscription_items` list of `%{item_ref, price_ref, metric}` — sourced from the
  authoritative `fetch_object(:subscription, ref)` snapshot (Stripe returns
  `items.data[].id` = `si_…`). Persist it as a bounded JSONB column on the infra-table
  (decision (a)) OR, if T108 finds a tenant-facing need, a dedicated `SubscriptionItem`
  mirror row keyed on `provider_item_ref` — **T108's call, but the ref MUST be an
  authoritative-fetch-resolved `si_` value, never a substituted `sub_` ref.**
- The adapter already FAILS HONESTLY on a missing item ref
  (`{:error, :missing_provider_ref}`, T25-verified) and passes the mirror-supplied
  `provider_ref` through verbatim — so the production path is: resolve `si_` from the
  authoritative subscription snapshot → store per-item → `UsageReporter` supplies it as
  `provider_ref`. No `sub_`→`si_` guessing anywhere.
- **Retry-window note (T25 P3, folded here):** Stripe usage `action:increment` is additive and
  idempotency keys expire ~24h; a retry delayed past that window could re-increment. T108's
  production usage hardening SHOULD either bound the retry window (< idempotency TTL) or
  persist per-record accept-state so post-window retries are not blind re-increments. Design
  note, not a T106 deliverable.

## Decision (d) — Watermark naming reconciliation (T21 P3s)

**RULING:** the watermark field is named **`watermark_at`** (neutral) and its DOC contract is:
*"the authoritative object's convergence timestamp — the provider object-level
`provider_updated_at` where the provider exposes one, else the event `occurred_at`."* This
reconciles ADR-038 §3.4(3)'s literal `provider_updated_at` with the shipped implementation
(which stores event `occurred_at`): the field name is now provider-shape-agnostic and the ADR
text (§3.4(3)) is understood as naming the *semantic* (a monotonic convergence watermark), not
a literal Stripe field. T108 SHOULD prefer the object-level `updated_at` from the authoritative
`fetch_object` snapshot when present (it defends replica-lag better than event `occurred_at`);
`occurred_at` is the honest fallback. **No blueprint field is named `provider_updated_at`.**

**`:eq` tie-break — DECLINED (deliberately).** The shipped guard is strict `:lt`-discard
(`:eq`/`:gt` proceed), byte-identical in `Reconciler.gate/2` and `Dunning.gate/2`. Equal-second
`watermark_at` collisions tie-break by delivery order (last-delivered wins), which is SAFE on
the production fetch-on-event path: every event re-fetches the authoritative CURRENT object, so
an equal-timestamp replay converges to current truth rather than clobbering with stale data
(T21/T24 verifier-confirmed). Hardening to `>=`-discard + a content hash is a second-granularity
micro-optimization with no live hazard; **declined** to keep the two gates byte-identical. T108
MAY revisit only if a real second-granularity collision hazard is demonstrated.

## Decision (e) — Checkout-seeded row design + DB-unique fence

**RULING:**

- **Null-watermark tolerance (binding on T108):** a checkout-activated row is seeded with NO
  watermark (`watermark_at = NULL`). The production `Mirror` MUST treat a NULL stored watermark
  as "accept the first lifecycle event as the baseline" — i.e. `gate/2` proceeds when the
  stored watermark is NULL, then stamps it. This is preferred over `AshCheckoutMirror.activate/2`
  seeding a synthetic watermark (a checkout has no authoritative lifecycle timestamp yet;
  seeding one would fabricate ordering data). The first real `subscription.updated` establishes
  the baseline.
- **DB-unique fence (LANDED in this task):** a UNIQUE index on `provider_subscription_ref`
  rides the §2 rename migrations — one per subscription table across all four hosts
  (`{bsb,fbs,dps,pbs,wbs,wps}_subscription_provider_ref_index`). The column is nullable, so
  Postgres permits multiple NULLs (local rows with no provider ref are unconstrained) while
  non-null provider refs collide — closing the T20 write-time check-then-insert TOCTOU window
  (two distinct-event-id concurrent deliveries naming one sub). The fence is a SCHEMA fact now;
  T108 owns (i) the Ash-side `identity`/`upsert_identity` that makes the create action surface
  the constraint as a value (not a raw DB raise), and (ii) the behavior PROOFS (same-row
  convergence, no-orphan, concurrent distinct-event-id fence). **Design split rationale:**
  landing only the index now keeps T106 a bounded design+rename unit and avoids adding an Ash
  identity that would (a) require snapshot/golden regen and (b) risk existing multi-row test
  fixtures; the physical fence exists immediately, the Ash-aware behavior is T108's.

## What T108 must implement (per this ADR, no re-litigation)

1. `Samen.Billing.Mirror` production Ash-backed subscription mirror + the `bms_mirror_state`
   infra-table (decision (a)); wire `:billing_mirror` host config.
2. The shared-storage contract between `:billing_mirror` and `:billing_checkout_mirror`
   (decision (b)) — same row, same neutral ref, null-watermark tolerance (decision (e)).
3. Production `InvoiceMirror`, `DunningMirror`, `UsageMirror` (distinct slots, decision (b)) +
   the `si_` subscription-item resolution (decision (c)).
4. `watermark_at` semantics (decision (d)); prefer object-level `updated_at`, `occurred_at`
   fallback; keep the two `gate/2` guards byte-identical.
5. The Ash `identity`/`upsert_identity` on `provider_subscription_ref` + the idempotency
   behavior proofs on top of the DB fence this task landed (decision (e)).

## Consequences / what a skeptic should attack

- **Infra-table vs blueprint:** a reviewer may argue watermark-on-blueprint is simpler to query
  tenant-side. Rebuttal: convergence bookkeeping is framework-internal, never tenant-facing; the
  `whk_event` precedent already establishes catalog-exempt infra for exactly this class of state,
  and it avoids fanning mirror-internals churn across four hosts.
- **Nullable unique index:** multiple NULLs are allowed, so the fence does NOT prevent two
  no-ref local subscriptions — intended (local rows have no provider identity to fence on). The
  fence is precisely for non-null provider refs, which is where the idempotency hazard lives.
- **`:eq` decline:** the risk is a real equal-second out-of-order clobber. Mitigated by
  fetch-on-event (re-fetch converges) and verifier-confirmed on both the subscription and
  dunning paths; the guards stay byte-identical, which is itself a coherence guarantee.
