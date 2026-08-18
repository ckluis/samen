# ADR-006 — Abbrev registry: global-vs-per-host scoping

- **Status:** Accepted (decision: DEFER the refactor; adopt the target design behind a generator)
- **Date:** 2026-07-07
- **Task:** T6.1 (extraction retro, plan §7 Phase 6). Item **A3** in
  `docs/extraction-retro.md`; a Gate-5-flagged carry-to-P6 item
  (`docs/gate-5-report.md` fix-tasks: "the abbrev registry is global-to-samen_core not
  per-host").
- **Deciders:** opus (T6.1), grounded in `driftwood/reports/T5.2.md` ("The one samen_core
  change") and ADR-004 §4 (which already named this "a Phase-6 generalization concern,
  noted here as a seam").
- **Relates to:** A2 abbrev storage transformer (`Samen.Resource`), A5 abbrev registry
  (`Samen.AbbrevRegistry`), `Samen.Verifiers.AbbrevRegistry`, ADR-004 (scope packaging).

---

## 1 · Context — what Driftwood forced

An abbrev is a 3-letter storage prefix (`com_`, `drv_`) projected into every column name, CDC
row, log line, and catalog entry. It is treated like a stock ticker: **permanent, never
recycled, one owner forever**. The registry (`samen_core/priv/abbrev_registry.json`) is the
durable source of truth, and `Samen.Verifiers.AbbrevRegistry` enforces at *compile time* that
every resource's abbrev is registered, 3-letter-lowercase, collision-free, and never renamed.

The problem the second host exposed: **the registry is GLOBAL to `:samen_core`.** It is read
from `:code.priv_dir(:samen_core)/abbrev_registry.json` — one file, one namespace, shared by
every host compiled against that `samen_core`. When Driftwood tried to mount the CRM scope under
the scope-default abbrevs (`cmp/per/pip/opp/act/att`), it **collided** at compile time with the
`demo` host, which already owned those abbrevs in the shared registry. Two hosts in the same repo
cannot both claim `usr` for their own `User` (ADR-004 §4 predicted exactly this).

Driftwood's workaround (documented, honest — `T5.2.md`, `T5.3.md`, `P6-PRE`):
1. take **fresh** abbrevs `fcm/fpr/fpp/fop/fac/fat` via the blueprint's `abbrevs:` override;
2. **append** those + the vertical abbrevs (`drv/stl/dsp/dak/dag/dtq`) to the shared
   `samen_core/priv/abbrev_registry.json` — the ONLY edits ever made under `samen_core/`, all
   data-only and append-only, leaving `samen_core`'s own 768-test suite green.

This works for one reference host but is a real architectural mismatch: the design (DECISION AB)
assumed a **per-app** registry, and the substrate as built has a **global** one.

## 2 · Why this is a DEFER, not an extract-now

The Rule-of-Three count: the collision is proven across **2 hosts** (demo + driftwood), and the
substrate owns the mechanism (the arguable 3rd). By the retro's conservative rule (two of my own
hosts = 2, not 3) this is **extract-on-3rd** at best. Two further facts push it firmly to defer:

- **The right design is genuinely open.** There are at least three viable target designs (§3),
  and picking wrong bakes a permanent-identifier scheme into every column name — the most
  expensive thing to get wrong in this whole substrate.
- **The blast radius is 50+ files.** Changing the registry scoping touches the transformer
  (`Samen.Resource`), the compile-time verifier (`Samen.Verifiers.AbbrevRegistry`), the loader
  (`Samen.AbbrevRegistry`), the scope blueprints, and every host's registry file + every migration
  that hardcoded a prefix. Per the scope-decomposition principle ([[feedback_scope_decomposition]]),
  a 50+ file change becomes an ADR + a backlog item, **not** an attempted refactor in this task.

So this ADR fixes the *direction*, not the code.

## 3 · Options considered

### Option A — keep the global registry, sanction the workaround (status quo)

Every host in a shared repo takes fresh, globally-unique abbrevs; the registry stays one global
file. **Rejected as the *target*, kept as the *interim*.** It works (Driftwood proves it) but it
defeats the whole point of "inherit the scope with its default abbrevs" — every new host must
hand-pick collision-free abbrevs for the *same* inherited resources, which is drift-prone and
undermines the "one stable column identity everywhere" story the moment you have two products.

### Option B (TARGET) — per-host-namespaced ownership in one registry file

Keep a single registry file, but key each entry on **(host_otp_app, abbrev) → resource**, so
`demo`'s `cmp` and `driftwood`'s `cmp` are distinct, permanent, collision-checked *within* a host
but free to repeat *across* hosts. The physical column prefix stays 3 letters (unchanged storage);
only the *ownership ledger* becomes host-scoped. The verifier reads the host's `otp_app`
(it already does, for catalog parity — ADR-004) and checks only that host's namespace.

**Chosen as the target.** It preserves permanence + collision-safety *per host* (the real
invariant — a host must never recycle its own abbrev), lets an inherited scope keep its default
abbrevs in every host, and needs no change to physical storage. The cost is the registry file and
the verifier both become host-partitioned — the 50+ file change that mandates a generator to land
safely.

### Option C — a registry file per host (`priv/abbrev_registry.json` in each host)

Each host owns its own registry file in its own `priv/`; `samen_core` ships none. **Rejected as
primary.** Cleanest conceptually, but it forfeits the one cross-host safety the global file gives
today: catching a *genuine* cross-host abbrev clash when two hosts DO share physical infrastructure
(e.g. an operator plane reading multiple tenants' tables in one DB). Option B keeps one file (so a
true cross-host clash is still visible) while namespacing ownership. C is the fallback if B's
single-file partitioning proves unwieldy.

## 4 · The decision

**Adopt Option B (per-host-namespaced ownership in one registry file) as the TARGET design, but
DEFER the implementation behind the T6.4 generator (`mix samen.new` / `mix samen.gen.scope`).**
Until then, the sanctioned interim is Option A exactly as Driftwood does it:

- a host mounting an already-claimed scope takes **fresh** abbrevs via the blueprint `abbrevs:`
  override;
- new abbrevs are **appended** (append-only, data-only) to the shared
  `samen_core/priv/abbrev_registry.json`;
- the compile-time verifier's global collision check stays the safety net.

The generator is the right vehicle because host scaffolding is exactly when abbrev ownership is
assigned — `mix samen.new my_app` can stamp a host-namespaced registry section and rewrite the
loader/verifier to read it, landing the 50+ file change as generated, tested output rather than a
hand-edited big-bang refactor.

## 5 · Consequences

**Positive**
- The permanent-identifier scheme is not changed under time pressure; the target design is
  recorded so the generator work (T6.4) has a spec.
- The interim workaround is explicitly sanctioned and bounded (append-only, data-only, verifier
  still enforcing), so hosts can keep shipping.

**Negative / accepted**
- Until B lands, every new host still hand-picks collision-free abbrevs for inherited scopes — the
  friction Driftwood documented. Accepted as an interim cost with a named exit (T6.4).
- The single global registry file grows with every host — tolerable at the current host count;
  the partitioning in B addresses it when it matters.

**Neutral**
- No change to physical storage or to any emitted column prefix in either the interim or the
  target — the abbrev-per-column contract is untouched; only the ownership ledger's *scope* changes.

## 6 · Red paths

No code changed in this ADR (it is a deferral decision), so no new red path is required here. The
existing red paths that keep the interim honest stay in force:

- `samen_core/test/abbrev_registry_red_path_test.exs` — an unregistered / mis-shaped / recycled
  abbrev fails compile (fail closed).
- Driftwood's build itself is the proof of the interim: a colliding default-abbrev mount fails the
  compile-time verifier until the host takes fresh abbrevs (the workaround this ADR sanctions).

When Option B is implemented under T6.4, its red path is: **a host that recycles its OWN abbrev
fails compile, while two DIFFERENT hosts reusing the same abbrev for their own resources compile
cleanly** — the exact discriminator that proves per-host namespacing works and is not a tautology.
