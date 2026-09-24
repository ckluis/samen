# ADR-051 — Usage-metering capture: an insert-only event ledger behind one chokepoint, with tallies derived from it and the reporter keyed end to end

- **Status:** **PROPOSED (2026-09-24) — DRAFT ONLY, no code authored.** Four operator decisions
  are open (§5). Nothing here is ratified; §4 records the recommended answer to each so the
  build can start the moment they are taken.
- **Date:** 2026-09-24
- **Task:** backlog **T163** (`_orch/plan/backlog.yaml:173`; OSS-scan shortlist item 3,
  `docs/research/oss-scan/capability-parse.md:117`; confirmed OPEN by mechanism in issue #33 and
  re-confirmed on `f8fcd79`: zero hits for `Billing.Meter` / `within_limit?` in `samen_core/lib`
  + `samen_core/test`, positive control `idempotency_key` hits `webhook.ex`,
  `webhook/delivery_worker.ex`, `usage_reporter.ex`). Closes the keyless samen-side half of G13
  usage rating. The reporting pipe (T25/T108) exists; **capture does not.**
- **Deciders:** the operator, on §5 D1–D4. D1 and D2 change schema in every host that mounts the
  Billing scope, so they are not reversible by a later code change alone.

---

## 1. Context — what exists, read on `f8fcd79`

**The Usage resource is a mutable tally, not a ledger.**
`Samen.Scopes.Billing.Blueprint.define_usage/6` (`samen_core/lib/samen/scopes/billing/blueprint.ex:636`)
documents itself as "one row per metric per billing window per subscription" and ships
`defaults([:read, :destroy, create: :*, update: :*])`. Any `:member` may update `quantity`. It
has no idempotency column and no uniqueness identity. A retried capture therefore **double-counts**,
and an update can silently rewrite history that has already been reported.

**The reporter is keyed on the tally row, not the event.**
`Samen.Billing.UsageReporter.idempotency_key/1` (`usage_reporter.ex:95`) is `"usage:" <> usage_record_id`.
That is sound against the *provider* for one row. It says nothing about whether the row's
`quantity` was captured once.

**The reporter's production mirror does not exist.**
`Samen.Billing.UsageMirror` (`usage_mirror.ex:30-37`) names the real Ash-backed impl a documented
GAP (T25-G1 → T106, operator-deferred as issue #6). Only `FakeUsageMirror` ships.
`UsageReportWorker` is an honest `:ok` no-op until a host wires `:billing_usage_mirror`.

**Entitlements are boolean, so there are no numeric limits to check against.**
`Samen.Scopes.Billing.Entitlement` (`entitlement.ex:21-26`) answers "is this org entitled to
feature X" from `feature` / `granted` / `expires_at`. The T163 row's "`within_limit?` joining
tallies to typed numeric entitlement limits" assumes a column that does not exist
(`capability-parse.md` Part 5 carries the idea as the "F7-P2-2 typed limits" residue, unbuilt).

**Money is mirrored, never computed.**
`Samen.Billing.Mirror` (`mirror.ex:54`): `proration_amount_cents` is "MIRRORED from the provider,
never computed". The row's "honestly-labeled estimated spend receipts" would be the first local
price computation in samen.

**Blast radius.** The Billing scope is mounted, with its own migrations, by `demo`
(`20260706020000_add_billing_scope.exs`), `driftwood` (`…110000_mount_billing_support_scopes.exs`,
`…140000_mount_operator_scopes.exs`), `pawchart` (`20260709100000_pawchart_resources.exs`,
`20260807120000_mount_operator_scopes.exs`) and `samen_web` (`…130000_mount_billing_support_scopes.exs`,
`…140000_mount_operator_scopes.exs`), and emitted by `Samen.Gen.App` (`samen_core/lib/samen/gen/app.ex:170`,
`:542`). Any schema choice below lands in all of them.

## 2. Decision (proposed)

1. **One chokepoint.** `Samen.Billing.Meter.record(org_id, event, opts)` is the only sanctioned
   write path for usage, in the same shape as `Samen.Files.upload/3` and `Delivery.Chokepoint`.
   A `Samen.Billing.Meter.ChokepointGuard` change refuses any other create, so a direct
   `Ash.create` on the ledger fails closed.
2. **An insert-only event ledger** (`<abbrev>_usage_event`, D1): `metric`, `quantity`,
   `occurred_at`, `subscription_id`, `idempotency_key`, with an identity on
   `(org_id, idempotency_key)` and `on_conflict: :nothing`. The resource defines **no update and
   no destroy action at all**. A replay of the same event is a no-op that reports
   `{:ok, :duplicate}`, never a second row and never an error the caller must special-case.
3. **The idempotency key is the caller's event identity** (D3). `record/3` requires
   `event.source_ref` (e.g. `"api_call:<request_id>"`, `"seat:<membership_id>:<period>"`). The
   stored key is `sha256(metric <> 0x00 <> source_ref)`, so it is bounded, carries no free text,
   and is the same on every retry by construction. A missing `source_ref` is
   `{:error, :idempotency_ref_required}`, never a generated UUID (a random key is exactly the
   double-count this ADR exists to remove).
4. **Tallies are derived, never written.** The existing `Usage` row becomes the per-period tally,
   **rebuilt from the ledger** by a `Samen.Rollup` `source: :domain` spec (ADR-018: always the
   rebuild arm) at period rollover and on demand. Its generic `update: :*` is replaced by exactly
   two narrow actions: `:rebuild_tally` (Rollup only) and `:mark_reported` (the reporter's
   `reported_at` stamp, the one mutation `UsageMirror.mark_reported/3` needs).
5. **The reporter's key goes end to end** (Part 5, T25/B8 annotation). A tally's report key
   becomes `sha256` over its period, metric, subscription and the sorted ledger keys it sums, so
   a rebuilt-but-unchanged tally re-reports under the **same** key and the provider dedups it,
   while a tally that genuinely grew gets a new one.
6. **Quota is a read, never a lock.** `within_limit?/4` answers from the current tally plus the
   limit in D2. It never blocks capture: usage that happened is recorded, and over-limit is a
   policy decision for the caller. Fail-closed semantics apply only to the *check*: an
   unreadable limit is `{:error, _}`, never `{:ok, true}`.

## 3. Red paths (each ships with a sabotage patch, next free number at build time)

| # | Guarantee | Red | Sabotage |
|---|---|---|---|
| R1 | A replayed event never double-counts | record the same `source_ref` twice → one ledger row, tally = 1× | drop the identity's `on_conflict: :nothing` → the second insert must error, or the dedup test flips |
| R2 | The chokepoint is the only write path | direct `Ash.create` on the ledger → refused | remove the guard change |
| R3 | The ledger is immutable | there is no update/destroy action; a raw `Ash.update` → `NoSuchAction` | re-add `update: :*` → the "no mutation surface" test flips |
| R4 | The tally is derived | mutate a ledger row out of band, rebuild → tally matches the ledger, not the stale value | make `:rebuild_tally` additive instead of recomputing |
| R5 | No generated key | `record/3` without `source_ref` → `{:error, :idempotency_ref_required}` | default `source_ref` to `Ecto.UUID.generate()` → R1's replay test double-counts |
| R6 | The limit check fails closed | an unreadable/absent limit row under D2 option (a) → `{:error, _}` | return `{:ok, true}` on the error arm |

Every red pairs with a positive control that must stay green under its sabotage (a distinct
`source_ref` is **not** deduped; a rebuilt, unchanged tally re-reports under the same key).

## 4. Phasing (one PR each, all off `main`, none stacked)

- **P1 — capture substrate:** ledger resource + `Meter.record/3` + guard + R1/R2/R3/R5, host
  migrations for demo/driftwood/pawchart/samen_web, `Samen.Gen.App` template. Depends on D1
  and D3 only.
- **P2 — derived tallies + end-to-end key:** the Rollup spec, the two narrow Usage actions,
  R4, reporter key switch. Depends on P1 and D4.
- **P3 — quota:** `within_limit?/4` + R6. Depends on D2.
- **P4 — tenant usage panel:** quantities only, unless D2's spend question resolves otherwise.
  samen_web, ≈0-LOC vertical mount.

## 5. Open decisions (operator)

- **D1 — New ledger table, or make `Usage` itself insert-only?**
  (a) **Recommended:** a new `usage_event` ledger, with `Usage` kept as the derived tally. Usage's
  documented grain is a period tally, and the reporter's `mark_reported` needs one mutation on it.
  (b) Make `Usage` insert-only with an idempotency column. That's one table fewer, but it breaks
  `mark_reported` and leaves nothing for the reporter to report except raw events. That is a
  provider-API change (many small usage records instead of one per period).
- **D2 — Where do numeric limits live, and is there a spend estimate at all?**
  (a) **Recommended:** a nullable integer `limit` + `metric` on `Entitlement` (`nil` = unlimited),
  mirrored from the provider's plan like every other entitlement field, and **no local spend
  estimate**: the panel shows quantities and the provider's own last invoice line, keeping
  `mirror.ex:54`'s doctrine intact.
  (b) A separate `Quota` resource, if limits should be settable independently of the plan.
  (c) Also ship the "estimated spend" line from the backlog row. This is the first local price
  computation in samen, and it would need its own ADR amendment to ADR-038.
- **D3 — Caller-provided `source_ref` (recommended), or a server-derived key** from
  `(org, metric, occurred_at truncated to a window)`? The derived key can't tell two real events
  in the same window apart, so it under-counts. That's the opposite failure, but still a wrong bill.
- **D4 — Ship P1–P3 before issue #6 (the real `UsageMirror`)?** **Recommended: yes.** Capture and
  quota are useful on their own (a quota needs no provider). The reporter remains the honest no-op
  it is today until #6 lands, and the P2 key switch is proven against `FakeUsageMirror`, the same
  way T25 was.

## 6. Out of scope

Local rating and proration (mirror doctrine, `mirror.ex:54`). AI-spend metering (T169 is
`blocked_by` T163 and must reuse this ledger's shape, per the backlog row, but it is not built
here). Erasure: usage rows carry no PII and no subject column. They are org-scoped and go with
the org, so no `Samen.Rollup.erase_subject/3` arm is needed. If D1(a)'s ledger ever gains a
per-user dimension, that changes and this line must be revisited.
