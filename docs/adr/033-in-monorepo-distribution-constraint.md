# ADR-033 — Framework distribution stays path-dep-in-monorepo; Hex publishing deferred to a stated trigger

- **Status:** Accepted (docs-only decision; no code change).
- **Date:** 2026-07-20
- **Task:** Decide and document the upgrade/distribution model for `samen_core`/`samen_web`,
  now that the repo is public. Every consumer — the three reference verticals AND every
  `mix samen.gen.app`-generated app — resolves the framework via `{:samen_core, path: "..."}`
  / `{:samen_web, path: "..."}`. That locks every consumer to the monorepo working tree: no
  version, no `mix deps.update` upgrade path, no resolution outside the tree.
- **Deciders:** engineering (foundry maintainer), grounded in the actual `mix.exs` wiring of
  `demo`/`driftwood`/`pawchart`, the `Samen.Gen.App` path-computation code, and the current
  `ash`/`ash_postgres` pin shape.

---

## 1 · Context

**Evidence — how the three reference verticals declare the dependency** (`grep path: demo/mix.exs
driftwood/mix.exs pawchart/mix.exs`):

```
demo/mix.exs:       {:samen_core, path: "../samen_core"},
driftwood/mix.exs:  {:samen_core, path: "../samen_core"},
                     {:samen_web, path: "../samen_web"},
pawchart/mix.exs:   {:samen_core, path: "../samen_core"},
                     {:samen_web, path: "../samen_web"},
```

All three are plain sibling-directory path deps. There is no version constraint anywhere in
this chain — a path dep tracks the working tree at whatever SHA is checked out, not a release.

**Evidence — how generated apps declare it** (`samen_core/lib/samen/gen/app.ex`,
`samen_core/lib/samen/gen/templates.ex`, `docs/guides/generators.md`):

- `Samen.Gen.App.samen_core_rel_path/1` (and its `samen_web` twin) computes a **relative path
  dependency** from the generated app's directory to `samen_core`/`samen_web` — the same
  `{:samen_core, path: "<%= samen_core_path %>"}` template idiom the verticals use
  (`templates.ex:252,1865`).
- Critically, that relative path is computed against `default_target/0`
  (`samen_core/lib/samen/gen/app.ex:129-140`), which derives from `:code.priv_dir(:samen_core)`
  of the **currently-running** `samen_core` — i.e. wherever this monorepo's `samen_core`
  actually lives on disk — **not** from the `--target` flag the caller passed. `--target` only
  chooses where the new app directory is created (`app_dir = Path.join(target, otp_app)`,
  `app.ex:150`); the emitted `path:` always points back at the real monorepo's `samen_core`,
  climbing however many `..` segments are needed (`rel_path/2`, `app.ex:764-780`).
- The consequence: **there is no `--target` value that produces a standalone app.** Point
  `--target` outside the monorepo and you get a deeper relative path
  (`../../../../Users/.../samen/samen_core`) that still resolves back into this exact
  checkout — the app is portable only as long as it and the monorepo stay at that same
  relative filesystem offset. `docs/guides/generators.md:36,43-44` documents this plainly:
  *"parent dir the app is created under (default: parent of the `samen_core` source root, so
  the app is a sibling and `path:` resolves)"* / *"depending on `samen_core` via a **computed
  relative path**."* The generator was built, by design, to keep every generated app inside
  (or filesystem-anchored to) the monorepo. There is no code path today that lets a
  `mix samen.gen.app`-generated app resolve `samen_core` from outside this tree.

**Evidence — no version is published anywhere consumers could pin:**

- `samen_core/mix.exs:4` sets `@version "0.1.0"`; `samen_web/mix.exs:19` sets
  `version: "0.1.0"` independently — two unsynchronized version strings, neither one
  referenced by any dependency declaration (`grep "~>" demo/mix.exs driftwood/mix.exs
  pawchart/mix.exs` for `samen_core`/`samen_web` returns nothing; both are path-only).
- `git tag -l` shows `v0.1.0` already exists (cut from the F1 release work per
  `docs/saas-gap-roadmap.md:207-209`), and `git log` shows F2–F5 workstreams landed since.
  So there IS a tag on the repo, but no package built from it — the tag marks a commit, not a
  Hex release, and nothing consumes it as a version constraint.

**Evidence — Hex publishing is not viable today without first loosening the dependency pins:**

- `samen_core/mix.exs:60-61` and `samen_web/mix.exs:52-53` both pin
  `{:ash, "== 3.29.3"}` and `{:ash_postgres, "== 2.10.0"}` with **exact-match (`==`)**
  operators, not `~>`. A Hex package with `==` pins on its own dependencies is hostile to
  downstream resolution: any consumer app that also wants a newer Ash patch (a common, even
  routine bump) cannot satisfy both constraints simultaneously, and any *second* Samen-based
  package in the same dependency tree with a different exact pin makes the tree unsolvable.
  Publishing to Hex as-is would ship a package version other packages structurally cannot
  co-exist with. This is a **precondition to fix**, not a blocker specific to any one
  distribution model — but it is a concrete reason Hex is not a same-day option regardless of
  which model this ADR picks.

## 2 · Decision

**Samen stays an explicit in-monorepo, path-dependency framework. Generated apps are declared
to live inside the monorepo working tree by design — not versioned, not vendored, not
published.** Concretely:

1. `samen_core`/`samen_web` remain path deps for `demo`/`driftwood`/`pawchart` and for every
   `mix samen.gen.app` output, exactly as wired today. No code change.
2. The constraint is now **documented as a stated design decision** (this ADR), not an
   unstated accident of the generator's path math — see the one-line pointer added to
   `docs/guides/generators.md` (§5 below).
3. Hex publishing and git-subtree/submodule vendoring are **explicitly rejected for now** (§4)
   and named as the future options, gated on a concrete trigger (§3 Consequences), not pursued
   speculatively ahead of that trigger.

## 3 · Rationale

- **This matches what the repo actually is today.** Samen is a single-author internal foundry
  that was recently made public — three reference verticals, a generator, and zero Hex
  packages published, zero external builders depending on it outside this tree. Optimizing
  the distribution model for a multi-consumer ecosystem that does not exist yet is exactly the
  kind of hand-waved hypothetical this ADR was asked not to indulge.
- **The generator was already built for this model, correctly.** `samen_core_rel_path/1`
  computing against the *real* monorepo location regardless of `--target` is not a bug to
  patch — it is the generator keeping every generated app truthfully anchored to the
  framework version it was scaffolded against (the working tree, not a fiction of a resolved
  version). Declaring the constraint in this ADR turns that behavior from an implicit
  accident into an owned decision.
- **Hex is not free today — it has a real precondition (the `==` pins) and a real ongoing
  cost** (semver discipline across two packages, a release process, a compatibility matrix for
  `ash`/`ash_postgres` version ranges instead of exact pins). Paying that cost now, before a
  single external consumer exists to benefit from it, is speculative engineering against a
  need that has not materialized — the same anti-pattern the repo's own "claim-evidence
  parity" ethos (ADR-024) argues against: don't build the on-ramp for a trip nobody has taken.
- **Vendoring (subtree/submodule) solves the wrong problem.** It would let an app exist
  outside the monorepo, but at the cost of a copy that drifts from the framework with no
  upgrade signal at all — worse than the current path dep, which at least always reflects the
  live framework state. It also does nothing about the missing version/semver story; it just
  relocates the same unversioned coupling into every consumer's tree instead of one shared
  monorepo. It solves "can the app live elsewhere" while making the deeper problem (no
  versioned upgrade path) permanent and per-app instead of solving it once.

## 4 · Rejected alternatives

- **Hex packages now.** Rejected for now, not forever. Requires: (a) loosening `ash`/
  `ash_postgres` from `==` to `~>` pins (a real compatibility-testing cost — samen_core's
  correctness claims are proven against exact versions today), (b) reconciling the two
  independent `0.1.0` version strings into one release cadence, (c) standing up a publish/CI
  step, (d) committing to semver discipline on every future breaking change to the vault/
  policy/Mount surfaces — all real work with zero current consumers to justify it. Revisit
  when the trigger in §5 fires.
- **Git subtree/submodule vendoring.** Rejected. Moves the coupling problem into every
  consumer's tree without adding a version/upgrade story, adds vendor-sync process overhead,
  and fights the "framework code is inherited, not re-emitted" invariant this repo already
  enforces structurally (CLAUDE.md, ADR-022) — a vendored copy is a fork the instant anyone
  hand-edits it, which a path dep structurally cannot become.

## 5 · Consequences

**Positive.** Zero migration cost — this ADR changes no code, only makes an existing,
load-bearing constraint explicit and intentional. The generator's `--target` behavior (always
resolving back to the real monorepo `samen_core`) is now documented as correct-by-design
rather than left to be mis-read as a bug. Builders and future contributors get an honest
answer to "can I run a generated app outside this repo?" — no.

**Negative / accepted.** Every consumer — verticals and every generated app — is permanently
tied to this monorepo's working tree until the trigger below fires. There is no upgrade path
today (`mix deps.update` does nothing meaningful against a path dep); moving to a newer
framework SHA means re-syncing the checkout, not bumping a version. An external builder who
clones just `samen_core` cannot use it — they need the whole monorepo. This is a real,
accepted limitation of a single-author project made public before it has external adopters.

**Migration trigger (revisit this ADR when any ONE of these happens):** (1) the first external
builder needs to generate or run a Samen app **outside** this monorepo's filesystem tree; (2) a
second team/repo wants to depend on `samen_core`/`samen_web` independently of the verticals
here; (3) the `ash`/`ash_postgres` pins are loosened from `==` to `~>` for an unrelated reason,
removing the Hex precondition cost. When triggered, Hex publishing (§4) is the pre-named
successor — not vendoring, for the reasons in §3/§4.

**Neutral.** No dependency versions change; `demo`/`driftwood`/`pawchart`/generated-app
`mix.exs` files are unchanged; the `v0.1.0` git tag continues to mark commits, not a Hex
release.
