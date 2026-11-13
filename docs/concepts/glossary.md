# Glossary

The bespoke vocabulary of this repo, one or two lines per term, each pointing at the ADR (or code) that defines it.
Where a word is used in more than one sense, **all** the senses are listed — pick the right one by the module name next
to it. Start with [two-plane-masking.md](two-plane-masking.md) for the mental model; the [ADR index](../adr/README.md)
has every decision's status.

## Words with more than one meaning

**plane** — four different things, all "a way of acting on or looking at data":
- *tenant plane / operator plane* — who is looking: an org over its own data (PII in the clear) vs the SaaS company's
  staff over a tenant's data (PII `••••`). `Samen.Web.Plane`; [ADR-009](../adr/ADR-009-samen-web.md) §5,
  [ADR-010](../adr/ADR-010-operator-plane.md). This is the default meaning.
- *aggregate plane* — the cross-tenant, token-blind path (see **token-blind actor**). `Samen.Aggregate`; ADR-010 §4b.
- *AI plane* — the `Samen.AI` runtime and its no-PII-egress chokepoint. [ADR-043](../adr/ADR-043-ai-plane.md).
- *control plane* — used two ways: the vision doc's name for the operator plane ("the control plane you run the
  business with", `Samen.OperatorPlane`), and the central audit / key-management database the reveal path depends on
  (what "control-plane down" means in `Samen.BreakGlass` and the [break-glass runbook](../runbooks/break-glass.md)).

**scope** — four things:
- `%Samen.Scope{}` — the *actor*: who is acting and in which org (`actor` + `org_id`), threaded to every Ash call.
  `Samen.Scope`.
- `Samen.Scopes.*` — a *domain blueprint* (Billing, Identity, Support, …): a package of resources that a host mounts.
  [ADR-004](../adr/ADR-004-scope-packaging.md); [scope-authoring](../guides/scope-authoring.md). `mix samen.gen.scope`
  creates a host's own.
- `Samen.Policy.OrgScope` — the *policy check* that filters every tenant read/write to the acting org.
- *scope mount* — adopting a blueprint in a host with one macro call (see **mount**).

**mount** — three things:
- `Samen.Web.Mount` — the *struct* that parameterizes a framework LiveView with a host's `namespace`, `repo`,
  `domain` and plane, so the view never names a host module. [ADR-009](../adr/ADR-009-samen-web.md) §3.
- *scope mount* — a host adopting a `Samen.Scopes.*` blueprint at ≈0 authored lines ([ADR-004](../adr/ADR-004-scope-packaging.md)).
- *router mount* — a `samen_*_routes` macro in a host router that mounts framework LiveViews (e.g.
  `samen_files_routes`). [ADR-009](../adr/ADR-009-samen-web.md).

**verifier** — two things: a *`mix samen.verify.*` task* (a gate step that fails the build on a violated invariant; the
index is [gate-failures](../guides/gate-failures.md)), and a *Spark verifier* (a compile-time check inside a resource
DSL, e.g. the abbrev-registry verifier). The tasks are what the gate runs.

**ledger** — four unrelated append-only things: the *subscription-movement ledger*
([ADR-017](../adr/ADR-017-subscription-movement-ledger.md)), the *usage-event ledger*
([ADR-051](../adr/ADR-051-usage-metering-capture.md)), the *turn ledger* of an agent run
([ADR-047](../adr/ADR-047-ai-agent-loop.md)), and the *mutation ledger* `scripts/mutation/ledger.tsv`
([ADR-049](../adr/ADR-049-mutation-gate.md)) that records accepted surviving mutants.

## Storage, identity and registries

**abbrev (storage abbrev)** — a permanent three-letter prefix that every column of a resource carries (`pii_com_email`),
reserved once and never recycled. [ADR-006](../adr/ADR-006-abbrev-registry-scoping.md).

**abbrev registry** — the committed `priv/abbrev_registry.json` recording which module owns which abbrev. Never edited
by hand; allocation goes through `mix samen.abbrev.reserve` ([ADR-023](../adr/ADR-023-abbrev-reserve-allocator-host-namespace.md)).
Per-host partitioning of the verifier is deferred ([ADR-025](../adr/ADR-025-abbrev-verifier-host-partition-followon.md)).

**catalog** — the machine data dictionary: `tam_table` (every table) and `fld_field` (every column), written in the same
transaction as the DDL (`catalog_sync` in a `Samen.Migration`) and dumped to `schema.dict.json`. `Samen.Catalog`;
`samen.verify.catalog_parity` checks it against the live schema.

**tier (Tier-0 … Tier-3)** — how much of a model a tenant can bend: Tier-0 config rows (data a tenant edits), Tier-1
custom fields, Tier-2 custom objects (`tnt_*`), Tier-3 code (`use Samen.Resource`). [scope-authoring](../guides/scope-authoring.md) §7.

**reads** — the bounded-read convention: every list is org-scoped and keyset-paginated through `Samen.Web.Reads`
(`bounded!/4`); an unbounded read raises. [ADR-016](../adr/ADR-016-kit-list-crud-notifications.md).

## PII, vault and masking

**vault** — the per-subject-encrypted PII store: domain rows hold only `vt_*` tokens, plaintext lives encrypted under a
key held in an external KMS. `Samen.Vault`; [ADR-001](../adr/ADR-001-key-hierarchy.md), [ADR-003](../adr/ADR-003-encryption-lib.md).

**vault class** — the shape of a vaulted field (`pii_secret`, `pii_address`, …) that decides how it is encrypted, cast
and resolved. Adding one has no central registry: [vault-class-extension](../guides/vault-class-extension.md),
[ADR-036](../adr/ADR-036-rich-types.md).

**mask / `••••`** — what a vaulted field renders as unless the actor's plane and a grant allow plaintext
(`%Samen.Masked{}`). Masking is a property of who is asking, resolved once in `Samen.Api.PiiResolution`.
[two-plane-masking](two-plane-masking.md).

**crypto-shred** — erasing a subject by destroying their key, which makes every copy (replica, backup, PITR) unreadable
at once. `Samen.Erasure`; [ADR-001](../adr/ADR-001-key-hierarchy.md) §7, [ADR-046](../adr/ADR-046-erasure-completeness.md).

**reveal grant** — a time-boxed, reasoned permission, held by a distinct second party, that lets one actor see one
subject's plaintext through the single reveal chokepoint. `Samen.Reveal`; ADR-001 / T1.6.

**impersonation session** — an operator opening a tenant's real UI for a short, reason-required, single-org session
that carries **no** reveal grant, so PII stays masked. `Samen.Impersonation`; ADR-010, [ADR-002](../adr/ADR-002-worm-anchor.md) for its audit rows.

**token-blind actor** — the cross-tenant `operator_aggregate` actor: it has no `org_id`, reads only projections where
`pii_` columns do not exist, and is structurally refused by the reveal path (aggregate and reveal are mutually
exclusive). `Samen.Aggregate`; ADR-010 §4b.

**chokepoint** — the one function or module through which a guarded action must pass, so a bypass is a structural
impossibility rather than a review comment: `Samen.Vault.reveal/3` (plaintext), `Samen.Files.upload/3` (storage keys,
[ADR-026](../adr/ADR-026-files-storage-adapter-fail-honest.md)), `Samen.AI.Chokepoint` (everything sent to a model,
ADR-043), `Samen.Pii.WriteGuard` (PII writes).

**fail-honest** — an unconfigured adapter returns `{:error, :not_configured}` and never a fake `{:ok, _}`.
[ADR-014](../adr/ADR-014-delivery-adapter-fail-honest.md), [ADR-024](../adr/ADR-024-generated-deploy-fail-honest.md), ADR-026.

**WORM anchor / hash-chained audit** — `aud_event` rows are hash-chained and periodically anchored to a write-once
store so tampering is detectable. [ADR-002](../adr/ADR-002-worm-anchor.md).

## Proof and CI

**gate** — the ordered set of verifiers + tests + probe a generated app's `ci.sh` runs (and `scripts/ci pr` runs for this
repo). "Correct by construction" means a generated app passes it on the first run.

**red path / anti-tautology** — every denial test is paired with a positive control, so a test that cannot fail is
treated as a bug. `Samen.RedPath`, `Samen.MaskingCase`.

**sabotage** — a committed patch (`scripts/sabotages/*.patch`) that breaks one guarantee; replaying it must make its
*named* test fail, and the revert must be byte-exact. Proves the test can fail. See [CLAUDE.md](../../CLAUDE.md) and [ci.md](../ci.md).

**double sweep** — the CI check that a new sabotage fails against a pristine `origin/main` (anchor) and that the whole
corpus still bites on the tree about to ship (disarm). `scripts/double-sweep.sh`.

**mutation gate** — the converse of sabotage: mechanically generated changes to a watch-listed file must each be killed
by a named test, or be ledgered with a proof. `scripts/mutate.sh`; [ADR-049](../adr/ADR-049-mutation-gate.md).

**probe** — a script that generates something real and checks it end to end (e.g. `priv/gen_app_flagship_probe.exs`
generates an app, runs its gate, boots it and flips sabotages). Not a unit test.
