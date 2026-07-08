# Extraction Retro — what Driftwood FORCED, and the Rule-of-Three call on each (T6.1)

- **Date:** 2026-07-07
- **Task:** T6.1 (plan §7 Phase 6). The vision doc's honest edge: *"this is the core
  extracted by the Rule of Three … not a foundry you build before you've shipped one"*
  (`docs/samen-foundry.txt` :67). Building Driftwood — a real freight vertical — on
  `samen_core` is the first real test of what the substrate actually pays. This retro is
  the honest inventory of every place the vertical had to **work around, extend, or fight**
  the substrate, and the extract/defer decision on each.
- **Inputs read in full:** `docs/gate-5-report.md`, `docs/claim-evidence.md`,
  `driftwood/reports/{T5.2,T5.3,T5.4,T5.5,P6-PRE-F1-F2}.md`, `docs/adr/00{1..4}.md`, and
  the substrate/vertical code each item names.
- **Scope discipline (per [[feedback_scope_decomposition]]):** this is analysis + ADRs +
  **one** small, safe, well-tested extraction where the need was unambiguous (the
  `aud_chain` migration body — a 3-way byte-identical copy-paste). Anything that is a 50+
  file change is an ADR + a backlog item, **not** an attempted refactor.

---

## 0 · The Rule-of-Three counting rule used here

The doc's honest framing is "extract at the third use." In this substrate there are three
distinct *kinds* of use, and I count them explicitly rather than hand-wave:

- **substrate use** — `samen_core` itself (its test repo / demo-of-the-kernel) uses the
  shape. Counts as **one** use only when the shape is genuinely load-bearing there, not
  incidental.
- **demo use** — the `demo` dogfood app (the generic multi-scope host).
- **driftwood use** — the freight reference vertical (the first *real, bounded-context*
  vertical).

**extract-now** = the need is proven across ≥ 2 real hosts **and** the substrate itself
(= the arguable 3rd), the shape is stable, and the extraction is small/safe. **extract-on-3rd**
= proven across demo + driftwood (2) but the 3rd real vertical would sharpen the abstraction,
or the extraction is large. **leave-vertical** = the friction is domain-specific and generalizing
it would be premature or wrong.

A hard honesty rule I applied: **demo + driftwood = 2, not 3.** Both are hosts I built to the
same plan; two of my own hosts agreeing is weaker evidence than two independently-motivated
verticals. So a plain "demo and driftwood both do X" defaults to **extract-on-3rd** unless the
substrate itself already carries the shape (making it a genuine 3rd), or the copy is
byte-identical and security-critical (where drift is a real hazard *now*).

---

## A · Honest inventory — what Driftwood forced

Each row: what the vertical hit, where, and the class of friction. Evidence is cited to the
report/code that recorded it, so nothing here is invented.

### A1 — `cdl_expiry` stored as text, not `:date`, to satisfy the `non_pii!` redaction arm

**What happened.** Driftwood's `drv_cdl_expiry` is FMCSA-load-bearing and registered as a
reviewed `non_pii!` column (plaintext-at-rest, erased by row-level redaction — H4 in the
claim-evidence table). The substrate's `non_pii!` erasure arm writes a **TEXT sentinel** over
the plaintext on shred. A `:date` column **cannot** take a text sentinel (`Postgrex` encode
error). So the vertical stored the CDL validity date as **ISO-8601 text** and parses it with
`Date.from_iso8601/1` at the FMCSA gate (`driftwood/reports/T5.2.md` "Substrate-forced
adaptations"; `lib/driftwood/policy/fmcsa_dispatch_gate.ex`).

**Class:** the substrate's redaction mechanism dictated the vertical's column *type* — a real
"fight the substrate" adaptation. The vertical wanted a typed date; it got a stringly-typed one
because erasure-of-a-non_pii-column only knows how to write a text sentinel.

### A2 — the `non_pii!` redaction sentinel is untyped (text-only)

**What happened.** Directly downstream of A1: the redaction sentinel is a single text value
(`[REDACTED_NON_PII]` for strings, and Driftwood had to accept a `1970-01-01` epoch sentinel by
storing the date as text). There is no per-type sentinel (a `:date` NULL-or-epoch, an `:integer`
0/NULL, a numeric NULL). (`driftwood/reports/T5.4.md` §4 attests the two forms.)

**Class:** a substrate limitation the vertical had to route around by changing its own schema
(A1). The substrate could carry the redaction-sentinel-per-type knowledge itself.

### A3 — the abbrev registry is GLOBAL to `samen_core`, not per-host

**What happened.** Driftwood's design assumed a **per-app** abbrev registry, so it could mount
the CRM scope under the scope-default abbrevs (`cmp/per/pip/…`). The **built** substrate reads a
single GLOBAL registry at `:code.priv_dir(:samen_core)/abbrev_registry.json`, in which those
abbrevs were already owned by `demo`. Two hosts mounting the same scope with default abbrevs
**collide** at the compile-time `Samen.Verifiers.AbbrevRegistry`. Driftwood had to (1) take
**fresh** abbrevs `fcm/fpr/fpp/…` via the blueprint's `abbrevs:` override, and (2) **append**
those + the vertical `drv/stl/dsp/dak/dag/dtq` rows to `samen_core/priv/abbrev_registry.json` —
the only edits ever made under `samen_core/`, all data-only/append-only
(`driftwood/reports/T5.2.md` "The one samen_core change"; `T5.3.md`; `P6-PRE`). Gate 5 flagged
this for the retro; ADR-004 §4 already named it a "Phase-6 generalization concern, noted as a
seam."

**Class:** an architectural mismatch — the design (DECISION AB) does not match the substrate as
built. The global registry works fine for one reference host but forces per-host abbrev-collision
gymnastics the moment a second host shares the repo.

### A4 — the `aud_chain` migration was copy-pasted BYTE-IDENTICALLY across three hosts

**What happened.** Every host that mounts the operator plane — `samen_core`'s test repo, `demo`,
and `driftwood` — carried its OWN `aud_chain` migration. I diffed them: **byte-identical** modulo
the module name and the `otp_app` atom used to read `:aud_event_app_role`. Same `CREATE TABLE`,
same UNIQUE `(ach_org_id, ach_seq)` index, same append-only trigger + function, same
`REVOKE UPDATE, DELETE`, same 15 catalog rows. Driftwood *needed* the table only from T5.4
(the crypto-shred game-day must prove the chain verifies post-shred), and it got it by copying
demo's migration verbatim (`driftwood/reports/T5.4.md`; the three files were
`{samen_core/priv/test_repo,demo/priv/repo,driftwood/priv/repo}/migrations/*_aud_chain.exs`).

**Class:** the clearest copy-paste-that-signals-a-missing-core-abstraction in the whole build —
and it is **security-critical** (the tamper-evident audit chain). A column add or a trigger fix
had to land in three places or silently drift. **This is the one item I extracted this session.**

### A5 — vertical rollups are plain functions, NOT wired to the substrate's cron worker

**What happened.** `samen_core` already ships a real Oban cron worker
(`Samen.Jobs.RollupRefreshWorker`, wired into `Samen.Jobs.default_crontab/0` at `*/10 * * * *`)
that drives `Samen.Rollup.rebuild_all/1` over *registered* `Samen.Rollup.Spec`s. But BOTH demo
(`Demo.Aggregate.Rebuild`) and Driftwood (`Driftwood.BrokerRollup`, `Driftwood.Aggregate.Rebuild`)
materialize their vertical rollups with **plain functions the dogfood/test drives** — NOT
registered specs, NOT driven by the worker. Both files carry the *identical* honest comment:
*"In production this would be an AshOban rollup worker (like `Samen.Jobs.RollupRefreshWorker`);
here it is a plain function."* (`demo/lib/demo/aggregate/rebuild.ex`;
`driftwood/lib/driftwood/{broker_rollup,aggregate/rebuild}.ex`; Gate 5 D1 CAVEAT).

**Class:** a missing bridge, not a missing mechanism. The substrate has the worker AND the spec
registry; what's missing is the vertical rollups being *expressed as specs* so the worker drives
them. The copy-paste is the identical "this should be a worker" comment in two hosts.

### A6 — the webhook payload storage-name guard false-positives on freight catalog names

**What happened.** `Samen.Webhook.Payload`'s storage-name guard is a blanket regex `~r/^[a-z]{3}_/`
that drops any field whose name starts with three lowercase letters + underscore (to keep physical
storage names like `com_`/`pii_` off the public payload). Freight has legitimate **catalog** names
that match the pattern: `cdl_number`, `cdl_state`, `cdl_expiry`, `eld_provider`. The webhook
**silently drops** them (`P6-PRE-F1-F2.md` "Honest P6 finding"; `docs/claim-evidence.md` E3). It is
**over-strict** (absent by omission — never a leak), but it means a freight `driver.updated`
webhook can't carry the CDL fields the tenant expects.

**Class:** a substrate heuristic that is wrong for a vertical whose *domain* nouns happen to look
like storage prefixes. The guard should key on the resource's **declared** storage prefix (the
abbrev registry knows it), not a blanket regex.

### A7 — the anti-corruption layer cannot add auth/FK/validation (alias/reshape are translation-only)

**What happened.** `Samen.Context`'s `alias_resource` and `reshape` are a thin translation layer:
they re-identify a kernel noun (Company → Carrier/Shipper, Opportunity → Load) and reshape money
(settlement netting) — but they **cannot add** a foreign key, a policy, or a validation. Driftwood's
FMCSA dispatch gate needs an FK to the driver + a hard before-action compliance check, which an
alias/reshape structurally cannot express. So dispatch is a **vertical `DispatchEvent` resource**
(a real `use Samen.Resource`), not an aliased kernel Activity (`docs/claim-evidence.md` H6;
`driftwood-design.md §1.4`; `T5.2.md` OR-1).

**Class:** a designed boundary, not a defect — the doc is explicit that verticals "author the
domain." But it's a real friction worth naming: the ladder's top rung (context translation) is
*translation only*; anything that adds structure drops to writing a native resource. Gate 5's
"alias-cannot-add-auth split" and "reshape-cannot-add-storage" are this item.

### A8 — `org_id` is not auto-derived from the actor on create

**What happened.** The gated `:dispatch` action had to set `org_id` explicitly from the actor
(`set_attribute(:org_id, actor(:org_id))`) — the substrate does not auto-derive `org_id` from the
scope on a create (`T5.2.md` "Substrate-forced adaptations").

**Class:** minor boilerplate the vertical repeats on org-scoped creates. A candidate for a base-macro
convenience, but low-value and easy to get subtly wrong (which creates need a *different* org?).

### A9 — operator-plane kernel tables are host-materialized copies (impersonation/reveal/suspension)

**What happened.** For impersonation/reveal to work at all, Driftwood had to migrate
`imp_impersonation_session`, `osp_operator_suspension`, `brl_reveal_ledger`, `brc_break_glass_anchor`
itself (`T5.3.md`), plus the `aud_chain` table (A4). These are the operator-plane's own tables —
"token-only, uncatalogued (the demo precedent)". Without them, `suspended?/2` fails closed and
impersonation refuses. This is the SAME class as A4 (copy-pasted operator-plane migrations) but the
tables are token-only and uncatalogued, so the drift hazard is lower than `aud_chain`.

**Class:** copy-paste of operator-plane migration DDL, adjacent to A4. Extract the whole
operator-plane migration set together (ADR-005 scopes `aud_chain` now, backlogs the rest).

### A10 — game-day / drill infra is re-authored per host (Fly/Neon/KMS seams)

**What happened.** The crypto-shred and PITR game-day harnesses
(`driftwood/priv/gameday/*`, `priv/drills/*`) reuse the T2.5 machinery but are re-authored in the
vertical, and every one carries the same operator-TODO seam list (real Fly/Neon/AWS-KMS, PITR-history
+ physical-replica oracle tiers). These are faithful local simulations + documented TODOs
(`T5.4.md`, `T5.5.md`, `claim-evidence.md` D4/H3).

**Class:** shared drill *scaffolding* that each vertical currently re-hosts. Generalizing it is real
work and needs the real cloud substrate to be meaningful — clearly a later item.

---

## B · The Rule-of-Three call on each

| # | Item | uses today | call | reasoning |
|---|------|-----------|------|-----------|
| A4 | `aud_chain` migration copy-paste | samen_core + demo + driftwood = **3**, byte-identical, security-critical | **EXTRACT-NOW** ✅ done | 3 identical copies of the tamper-evident chain DDL; drift is a live hazard. Small, safe, high-value. **Extracted this session** → `Samen.OperatorPlane.Migration` + ADR-005. |
| A3 | abbrev registry global-vs-per-host | demo + driftwood collide = **2 hosts**, substrate owns the mechanism (3rd) | **EXTRACT-ON-3RD** → ADR-006 | The need is real and Gate-5-flagged, but the *right* design (per-host namespacing vs a keyed global vs a registry-per-repo) is genuinely open and touches the transformer + verifier + every host's registry file — a 50+ file blast radius. ADR decides the direction; a 3rd vertical would confirm the shape. **Do not refactor now.** |
| A5 | rollup refresh as a real cron worker | worker EXISTS in core; demo + driftwood both bypass it = **2** | **EXTRACT-ON-3RD** → ADR-007 | The mechanism is already in core; the gap is expressing vertical rollups as `Samen.Rollup.Spec`s so the worker drives them. ADR-007 defines the spec-registration bridge; a 3rd vertical proves the Spec shape covers non-`aud_event`-sourced rollups (Driftwood's read from domain tables, not just the event tier). |
| A9 | operator-plane migration set (impersonation/reveal/suspension) | 2–3 hosts, adjacent to A4 | **EXTRACT-ON-3RD** (backlog under ADR-005) | Same copy-paste class as A4, but token-only/uncatalogued so lower drift hazard; the tables also vary more between hosts. Extract alongside a `mix samen.gen.operator_plane` generator (T6.4). ADR-005 §6 scopes the follow-up. |
| A1/A2 | `non_pii!` redaction sentinel is text-only / dictated a column type | driftwood = **1** (demo has no non_pii! date column) | **LEAVE-VERTICAL** (backlog a typed-sentinel enhancement) | Only ONE host hit it. The text-sentinel-forces-text-column adaptation is ugly but contained and documented; the fix (per-type redaction sentinels) is a substrate enhancement to schedule when a 2nd host needs a typed `non_pii!` column, not a Rule-of-Three extraction yet. |
| A6 | webhook storage-name guard false-positives | driftwood = **1** (the only host with catalog names matching `^[a-z]{3}_`) | **EXTRACT-ON-3RD** → backlog (small, but change the core heuristic) | It's a real correctness bug in a core module, but it surfaced on ONE host. The fix (key on the declared abbrev, not a blanket regex) is small and safe — I'd do it the moment a 2nd host trips it, or fold it into T6.3/T6.4. Backlogged with a precise fix, not extracted blind. |
| A7 | alias/reshape can't add auth/FK/validation | by design | **LEAVE-VERTICAL** | The doc explicitly makes context translation translation-only; adding structure = write a native resource. Not friction to remove — it's the boundary the doc sells. Documented, not extracted. |
| A8 | `org_id` not auto-derived on create | 2 hosts repeat it | **LEAVE-VERTICAL** (note) | Low value, easy to get wrong (which create uses which org?). A base-macro convenience is a footgun risk; leave it explicit. |
| A10 | per-host game-day/drill scaffolding | 2 hosts, all cloud-seamed | **EXTRACT-ON-3RD** (backlog) | Meaningful only against real Fly/Neon/KMS; generalizing local sims now would freeze the wrong shape. Revisit with T6.5 (CDC) and the real cloud drills. |

---

## C · Extraction ADRs

Three ADRs were written this session, one per Gate-5-flagged item:

- **`docs/adr/005-operator-plane-migration-extraction.md`** — A4, the **done** extraction.
  Decision: the `aud_chain` DDL body lives once in `Samen.OperatorPlane.Migration`; hosts write a
  4-line wrapper. Includes the red-path + anti-tautology evidence. Scopes A9 as a follow-up.
- **`docs/adr/006-abbrev-registry-scoping.md`** — A3. Decision: **defer** the refactor; adopt a
  per-host-namespaced-owner registry as the *target* design, but land it behind a generator (T6.4),
  because retrofitting it is a 50+ file change. Records the interim rule (fresh abbrevs +
  append-only global registry) as the sanctioned workaround until then.
- **`docs/adr/007-rollup-cron-worker.md`** — A5. Decision: vertical rollups become
  `Samen.Rollup.Spec`s driven by the existing `Samen.Jobs.RollupRefreshWorker`; the gap is a
  spec-registration bridge for domain-table-sourced (not just `aud_event`-sourced) rollups, defined
  here and landed when a 3rd vertical confirms the Spec shape generalizes.

---

## D · Prioritized backlog (the rest)

Ordered by (drift-hazard × frequency) ÷ blast-radius. Items already ADR'd above are the top three.

| pri | item | action | trigger to do it | est. blast radius |
|-----|------|--------|------------------|-------------------|
| P1 | A9 operator-plane migration set (imp/reveal/suspension) | extract via `mix samen.gen.operator_plane` (folds A4's helper + these tables) | T6.4 generators task | medium (3 hosts, 4 migrations each) |
| P1 | A6 webhook storage-name guard | change `Samen.Webhook.Payload` to key on the resource's declared abbrev, not `^[a-z]{3}_`; add a freight-catalog-name red path | next host that trips it, or T6.3 | small (1 core module + tests) |
| P2 | A3 abbrev registry per-host scoping | execute ADR-006 behind the generator | 3rd real vertical, or when 2 hosts must share the repo in prod | **large (50+)** — transformer + verifier + every registry |
| P2 | A5 rollup-spec bridge | execute ADR-007: register `Driftwood.BrokerRollup`/`Aggregate` as Specs; wire the cron | 3rd vertical confirms non-event-sourced Spec shape | medium |
| P3 | A1/A2 typed `non_pii!` redaction sentinels | add per-type redaction sentinel to `Samen.NonPii`/`Erasure`; let `cdl_expiry` be `:date` | 2nd host needs a typed non_pii! column | medium (erasure + oracle tier) |
| P3 | A8 org-scoped-create convenience | evaluate a base-macro `org_from_actor` opt-in helper (opt-in, never default) | when ≥3 verticals repeat the boilerplate | small |
| P4 | A10 shared game-day/drill harness | extract the T2.5/T5.4/T5.5 scaffolding into a `Samen.GameDay` reusable once real Fly/Neon/KMS exist | real cloud substrate + T6.5 | large |

**Nothing here is silently dropped.** Every friction the vertical hit is either extracted (A4),
ADR'd with a direction (A3, A5, A9), or backlogged with a concrete fix and a trigger (A1/A2, A6,
A8, A10). The two "leave-vertical" items (A1/A2 as a schema choice; A7 as a designed boundary) are
labeled as such, not ignored.

---

## E · What was extracted this session (the only code change)

**`Samen.OperatorPlane.Migration`** (`samen_core/lib/samen/operator_plane/migration.ex`) — the
shared `aud_chain` migration body (A4). The three host migrations now each read:

```elixir
def up,   do: Samen.OperatorPlane.Migration.create_aud_chain(@app_role)
def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(@app_role)
```

- **Red-path + anti-tautology** (`samen_core/test/operator_plane_migration_test.exs`, 10 tests):
  end-to-end against a throwaway DB — the append-only trigger REFUSES UPDATE/DELETE (with a normal
  INSERT succeeding as the non-vacuous control); `down/0` leaves **zero** orphaned catalog rows; the
  role gate REFUSES an injectable Postgres role (fail closed); and a **field-parity** test asserts
  the extracted column list matches `Samen.AuditChain.Entry`'s schema exactly (so the DDL can't
  silently drift from the schema).
- **Anti-tautology probe (run this session, project-local `.t61_scratch/`, reverted byte-identical,
  md5 `d96d8ec46333d82b43fbdeead535ce61`):** neutered the append-only trigger's `RAISE EXCEPTION`
  → the two append-only red paths **FLIPPED to failing** ("nothing was raised") while the positive
  INSERT control stayed green; reverted; all 10 green again; scratch removed. The red paths exercise
  the real trigger, not a tautology.
- **A pre-existing latent flake was found and fixed while landing this** (not caused by the
  extraction — exposed by its test-ordering shift): `reveal_grant_seam_test.exs` restored
  `:kms_adapter` to `prior_kms` which is `nil` when it ran first, overriding the `FileBacked`
  default and crashing a later `context_test` with `nil.attest/1`. Fixed to `prior_kms || FileBacked`
  — the guard the other adapter-mutating tests already use. Confirmed deterministically
  (`reveal_grant_seam_test context_test --seed 0` reproduced then fixed) and across 5 seeds.

**Green-before → green-after:** root `bash ci.sh` = ALL PASSED both before and after. samen_core
768 → **778** (+10 new tests), demo 399 + 48 gate unchanged, driftwood 58 + 4 adversarial + full
20-step `ci.sh` all green (all three hosts migrate `aud_chain` via the shared helper).
`mix test --warnings-as-errors` green in every app.
