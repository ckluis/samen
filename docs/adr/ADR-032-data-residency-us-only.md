# ADR-032 — Data residency: US-only, documented (no per-tenant region selection)

- **Status:** Accepted (documentation of current posture; F3, Unit 6).
- **Date:** 2026-07-20
- **Task:** F3 Unit 6 — state the honest residency posture in one place instead of leaving it
  implicit. No code changes; this ADR documents what the single-Postgres-per-host model already
  does and does not provide, and names what a real multi-region story would require.
- **Deciders:** F3 documentation pass, grounded in ADR-001 (per-subject KMS key hierarchy),
  ADR-002 (hash-chained audit + WORM anchor), and `Samen.Erasure` (crypto-shred as the erasure
  guarantee).

---

## 1 · Context

A prospective tenant, or a compliance reviewer, will ask "where does my data live" and "can I
pin my org to the EU." Samen has never claimed multi-region placement, but the claim has also
never been written down as a decision — it has just been the default outcome of the
single-Postgres-per-host architecture. That silence is itself a risk: an unstated posture invites
someone to assume a capability (region selection, EU data residency) that does not exist.

This ADR states the posture explicitly: **one region, no per-tenant selection, today.**

## 2 · Decision — US-only, no residency-selection mechanism

All tenant data for a given deployment resides in **US regions**, with no per-tenant override:

- **Postgres** (live + PITR replica/backup) — a single regional Postgres host per deployment
  (Neon in prod; the CI/dev/test Postgres is local). There is no per-org database, schema, or
  region routing — every org's rows share the one Postgres instance for that deployment (scoped
  by `org_id`, per `Samen.Policy.OrgScope`, not by physical placement).
- **Vault ciphertext** — lives in the same Postgres instance as every other row (the vault is a
  table, not a separate store); it inherits the Postgres deployment's region.
- **KMS key material** — the external key store (ADR-001) is AWS KMS + DynamoDB in production
  (an operator TODO — not yet wired in this environment; `Samen.Kms.FileBacked` is the dev/test
  stand-in). Whichever AWS region the operator provisions KMS/DynamoDB in is the key store's
  region; today that is a single operator-chosen US region, not a per-tenant choice.
- **Backups / PITR** — the Postgres PITR archive (Neon continuous WAL, per
  `docs/runbooks/pitr-gameday.md`) lives alongside the primary; no cross-region backup copy is
  part of the shipped design.
- **CDC / analytics sink** — the aggregate/CDC projection (`Samen.Cdc.Projection`, ADR-015)
  mirrors into whatever regional sink the operator points it at; in this build that is the same
  region as the primary Postgres.

There is **no mechanism** — no config flag, no per-org attribute, no routing layer — that lets a
tenant select "put my org's data in the EU" or any other region. A tenant asking for that today
gets an honest "not supported"; there is no partial or silent implementation to point to.

## 3 · Rationale — why this is the honest default, not a gap being hidden

- **The architecture is single-Postgres-per-host by design** (see `CLAUDE.md`, the ADR-001/002
  key-hierarchy and audit-chain decisions). Every governed write path — vault writes
  (`Samen.Pii.WriteGuard`), the audit chain (`Samen.AuditChain`, per-org but not per-region), the
  erasure orchestrator (`Samen.Erasure`) — assumes one physical Postgres per deployment. Region
  selection is an orthogonal, unbuilt axis: it would mean routing an org's reads/writes to a
  *different* Postgres instance and a *different* KMS partition based on `org_id`, which none of
  the current chokepoints do.
- **Crypto-shred is the erasure guarantee, not geo-deletion.** Samen's answer to "how do you
  delete my data" is `Samen.Erasure.shred/2`: destroying a subject's DEK makes every vaulted value
  undecryptable across live/replica/backup-PITR/CDC/rollup/audit at once (see the module doc).
  This is a **cryptographic** guarantee, independent of physical geography — it does not require
  (and does not provide) deleting bytes from a specific region's disks. A residency requirement
  that means "the bytes must never leave region X" is a different, additive guarantee this ADR
  does not claim; a requirement that means "the data must become unrecoverable" is already met by
  the existing shred, in any region.
- **Stating it now avoids an implicit promise.** Silence on residency reads, to a careful
  reviewer, as either "not evaluated" or "some Samen deployments might differ" — neither of which
  is true. This ADR replaces the silence with a plain statement.

## 4 · What a real multi-region / EU story would require (NOT built)

Named so a future workstream has a concrete target instead of rediscovering the shape:

1. **Per-tenant region routing** — an `org_id → region` mapping consulted at the connection layer,
   so `Samen.Policy.OrgScope`-scoped reads/writes for an EU org hit an EU Postgres instance, not
   the shared US one. This is a new chokepoint, not a config toggle; every place that currently
   assumes "the one repo" (roughly every `Samen.*` module taking a `:repo` option, plus
   `default_repo/0` fallbacks like `Samen.Erasure.default_repo/0`) would need to resolve a
   *per-org* repo instead of an application-wide default.
2. **Regional KMS partitions** — a second (or Nth) `Samen.Kms` adapter instance scoped to the EU
   region, with the per-subject DEK provisioned in the region matching the subject's org. The
   `Samen.Kms.adapter()` seam (currently one configured adapter per deployment) would need to
   become org-aware.
3. **Regional replicas / PITR archives** — a PITR archive and any read replica for an EU org's
   Postgres instance would need to live in-region too (the current `docs/runbooks/pitr-gameday.md`
   drill assumes one branch/region).
4. **Regional CDC/analytics sinks** — the aggregate projection would need per-region sink routing
   so analytics data does not silently cross regions even after the primary is regionalized.
5. **An audit-chain partitioning decision** — ADR-002's per-org chain scoping is already the right
   shape for step 1 to build on (chains are already org-partitioned, just not region-partitioned),
   but the WORM anchor store (`Samen.Anchor`) would need a regional adapter per region too, or an
   explicit decision to keep anchoring centralized.

None of the above is built, planned in the current backlog, or partially wired. A tenant with a
hard EU-residency requirement cannot be served by this deployment today.

## 5 · Consequences

**Positive** — the posture is now written down in one place a reviewer or prospect can be pointed
to; it correctly distinguishes "no geo-deletion" (true, and not needed — crypto-shred covers
erasure) from "no region selection" (true, and a real gap for EU-requirement prospects); it gives
a future multi-region workstream a concrete list instead of a vague aspiration.

**Negative / accepted** — Samen cannot serve a tenant with a hard data-locality requirement (e.g.
GDPR data-transfer-restricted EU customers who require in-region storage, not just
erasure-on-request) until the work in §4 is built. This is a real go-to-market limitation for
some prospects, named rather than hidden.

**Neutral** — no code changes; this ADR is a documentation-only decision record.

## 6 · See also

- `Samen.Erasure` (`samen_core/lib/samen/erasure.ex`) — the crypto-shred erasure guarantee this
  ADR leans on to distinguish "cannot geo-restrict" from "cannot delete."
- ADR-001 (per-subject KMS key hierarchy) — the key store whose region this ADR names as the
  single point of physical control today.
- ADR-002 (hash-chained audit + WORM anchor) — the per-org (not per-region) chain partitioning
  that §4 step 5 would extend.
- `docs/runbooks/pitr-gameday.md` — the backup/restore surface whose regionality is unexamined
  outside this ADR.
