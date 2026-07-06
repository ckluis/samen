# Gate-2 fixes — F2.2 (mandatory), F2.3, F2.4

**Date:** 2026-07-05
**Scope:** the three fix tasks from `docs/gate-2-report.md` §Fix tasks assigned to this pass —
F2.2 (mandatory-in-phase), F2.3, F2.4. F2.1 (`oban_jobs` tier) is a carry-to-P3 item and is out
of scope here.

## Baseline (before, run by me)

| Check | Result |
|---|---|
| samen_core `mix test --warnings-as-errors` | 482 passed (9 properties, 473 tests) |
| demo `mix test --warnings-as-errors` | 46 passed (3 properties, 43 tests) |
| root `bash ci.sh` | exit 0 — ALL PASSED |
| `bash demo/ci.sh` | exit 0 — ALL 8 steps passed |

## Final (after)

| Check | Result |
|---|---|
| samen_core `mix test --warnings-as-errors` | **491 passed** (9 properties, 482 tests) — +9 |
| samen_core `mix compile --warnings-as-errors --force` | exit 0, warning-clean |
| demo `mix test --warnings-as-errors` | 46 passed (unchanged) |
| root `bash ci.sh` | **exit 0** — ALL PASSED |
| `bash demo/ci.sh` | **exit 0** — ALL 9 steps passed (new step 9/9) |

---

## F2.2 — J2 runtime-value-guard honesty gap (MANDATORY) — BOTH halves done

### (a) Tightened `Samen.WideEvent.bounded_id_shape?/1` reusing the C4 value-shape heuristics

The gate found the runtime guard only rejected **whitespace**-containing values, so a single-token
email/SSN/phone (and an atom-ized name in `:action`) passed. Both `PiiClassify` (C4) and `WideEvent`
(J2) needed the same value-shape heuristics, so rather than duplicate the regexes I **extracted a
shared module**:

- **New `lib/samen/pii_value_shape.ex`** (`Samen.PiiValueShape`) — the single source of truth for the
  email / SSN / phone regexes (moved out of `PiiClassify`) plus a space-separated-name shape. Two
  entry points: `classify_value/1` (email/SSN/phone only — the C4 seed-value semantics, unchanged) and
  `classify_id_value/1` + `pii_shaped_id?/1` (adds the name shape — for the runtime ID/token guard).
- **`lib/samen/pii_classify.ex`** — deleted its `@email_regex/@ssn_regex/@phone_regex`; `pii_shaped_value?/1`
  now delegates to `PiiValueShape.classify_value/1`. C4 behaviour is byte-identical (verified: pii_classify
  tests + demo `pii_classify` gate step still pass).
- **`lib/samen/wide_event.ex`** — `bounded_id_shape?/1` now ANDs in `not PiiValueShape.pii_shaped_id?(value)`,
  so an email/phone/SSN literal in an `:opaque_id`/`:token` field fails. The open-`:enum` (`:action`) path
  now rejects an atom whose `Atom.to_string/1` form is PII/name-shaped (`pii_shaped_atom?/1`).

### (b) Honesty fixes — moduledocs + report state precisely what the guard is

The finding was that the prose over-sold the runtime guard as if it caught "every bounded field." Fixed
so an auditor cannot over-trust it:

- **`WideEvent` moduledoc** — the "Two defences" section now names defence (1) the **load-bearing** J2
  guarantee (schema, no free-string field, `mix samen.verify.sink_schema`) and defence (2) explicitly a
  **value-SHAPE heuristic, NOT a taint proof**, with an honesty note that a single-token opaque value that
  happens to be a real surname is indistinguishable from a legitimate token by shape alone. `new/1`'s
  `@doc` was aligned to match.
- **`TraceSinkIngress` moduledoc** — added a "What the load-bearing defence is (and what it is NOT)"
  section: the tier asserts over the **schema** (the load-bearing invariant); the runtime value-shape
  heuristic is separate, a heuristic not a proof, and the oracle does not lean on it.
- **`Samen.PiiValueShape` moduledoc** — states up front it is a heuristic not a taint proof, and that for
  `WideEvent` the schema is load-bearing.
- **`samen_core/reports/T2.7.md`** — the STEP-3 claim ("REJECTS the exact laundered plaintext at every
  bounded field") was corrected to state the runtime check is a value-shape heuristic (whitespace/type
  + email/phone/SSN/name shape) that catches the obvious literal, NOT a taint proof, and that the
  **schema-level no-free-string-field defence is the load-bearing J2 guarantee** (see report edit).

### Red paths (new — `test/wide_event_j2_laundered_test.exs`, describe "F2.2 …")

All four required single-token shapes are now **REJECTED** at runtime:

| Value | Field(s) | Result |
|---|---|---|
| `alice@example.com` (single-token email) | `tenant_id`, `actor_id`, atom-ized `:action` | `{:error, _}` |
| `123-45-6789` (dashed SSN) | `tenant_id`, `actor_id` | `{:error, _}` |
| `+15551234567` (phone) | `tenant_id`, `actor_id` | `{:error, _}` |
| atom-ized `"Alice Anders"` (name) | `:action` | `{:error, _}` |
| `alice@example.com` (struct-smuggled) | `tenant_id` via `emit/1` | `{:error, _}` |

Plus discriminating "not always-fail" cases that must still PASS: `action: :create`,
`action: :contact_created`, and legitimate opaque IDs/tokens (a ULID + a `vt_`-prefixed hex token).

### Anti-tautology probe (HARD RULE 2)

- Scratch: self-created `gate2_scratch/f22_antitaut/` (project-external, OUTSIDE `/tmp` root; since removed).
  Backed up `lib/samen/pii_value_shape.ex` (4235 bytes).
- Sabotage: made `PiiValueShape.pii_shaped_id?/1` a constant `false` (defeat the belt).
- Result: **5 of the new F2.2 red-path tests FLIPPED to FAILING** (email/SSN/phone in tenant_id & actor_id,
  atom-ized email, emit-path re-validation) — `Result: 6/11 passed`. The 6 still-green cases are the
  pre-existing space-separated-name rejections (caught by the independent `String.contains?` whitespace
  check, not the sabotaged heuristic) and the "not always-fail" discriminators. This proves the new
  heuristic is a **non-vacuous discriminator** for exactly the single-token PII shapes it was added to
  catch.
- Revert: restored from backup → **0 `SABOTAGED` occurrences**, byte count back to 4235, scratch dir
  removed, `mix test test/wide_event_j2_laundered_test.exs` → **11/11 green**, `mix compile
  --warnings-as-errors` clean.

---

## F2.3 — wire `mix samen.verify.metric_labels` into demo/ci.sh (one line + a latent crash fix)

### What I found

Wiring the task in surfaced a **latent crash** the gate's existing test did not cover: the existing
`metrics_label_lint_test.exs` only exercised the pure filter (`Enum.filter(tags, …)`), never the mix
task's `run/1`. `run/1` did `Map.get(metric, :tag_values, %{}) |> Map.keys()` — but `Telemetry.Metrics`
structs always carry `:tag_values` as a **function** (a measurements→tags transform), so `Map.keys/1`
crashed with `:maps.keys(#Function<…>)`. The task exited 1 by crashing, not by linting — it would have
**exploded** the CI step, not gated it, had it been wired earlier.

### Fix

- **`lib/mix/tasks/samen.verify.metric_labels.ex`** — `scan_module/2` now lints only `:tags` (the label
  dimensions that become Prometheus series). `:tag_values` is a function whose output keys are not
  statically inspectable, so it cannot be linted here; a comment documents why. This aligns the task with
  the mechanism the unit test always validated.
- **`demo/ci.sh`** — added `mix samen.verify.metric_labels` as **step 9/9**, same shape as the other
  verifier steps; normalized all step denominators to `/9` (they were inconsistently `/7` and `/8`
  before) and updated the header comment.
- **`test/metrics_label_lint_test.exs`** — added a "F2.3 — the mix task run/1 (what CI gates)" describe
  block with two tests that exercise the **real** `run/1`: a bounded-only module runs without raising
  (locks the crash fix), and a seeded `org_id` module raises `Mix.Error` (locks the red path).

### Verification

- `mix samen.verify.metric_labels` now exits **0** on `Samen.Metrics` (6 metrics scanned) in both
  samen_core and demo; demo/ci.sh step 9/9 PASSED.
- Red path confirmed for real (not just via the unit test): I ran the actual task `run/1` against a
  seeded module with `tags: [:action, :org_id]` — it printed `FAIL: … "bad.events" uses forbidden tag
  :org_id` and raised `Mix.Error` ("forbidden metric tags found — exit 1"). The task-level test asserts
  this via `assert_raise Mix.Error`.

---

## F2.4 — column_refs test scratch dirs moved off the /tmp root

### Decision + reasoning

I moved them (did **not** take the "document the exception" option). The gate's scratch-dir rule is
"scratch OUTSIDE the `/tmp` root." The PRE-a fix isolated per-test with a unique subdir but still rooted
the subtree at `/tmp/samen_colrefs_test/`, i.e. under the shared `/tmp` root — the exact dependency the
rule exists to remove. Since a project-local move is trivial and strictly better (no other process, test
suite, or user writes into a project-owned dir), moving is the honest fix; there is no reason to keep the
`/tmp` dependency and paper over it with a note.

### Fix

- **`test/catalog_test.exs`** — `make_scratch_dir/1` now roots the scratch subtree at a project-local,
  git-ignored `samen_core/tmp/colrefs_scratch/<ctx>/` (`@scratch_root = Path.join([__DIR__, "..", "tmp",
  "colrefs_scratch"])`, `Path.expand`ed), NOT `System.tmp_dir!()`. Per-test `on_exit` cleanup
  (`File.rm_rf`) is unchanged. The helper comment explains the F2.4 rationale.
- **`.gitignore`** — added `samen_core/tmp/` and `gate2_scratch/`.

### Verification

`mix test test/catalog_test.exs` → 21 passed; the scratch dir is created under `samen_core/tmp/`
(confirmed, then cleaned). No `/tmp`-root dependency remains for these tests.

---

## Files changed

**New:**
- `samen_core/lib/samen/pii_value_shape.ex` — shared value-shape heuristic (F2.2 a)

**Modified:**
- `samen_core/lib/samen/wide_event.ex` — tightened `bounded_id_shape?/1` + open-enum atom guard; honesty moduledoc (F2.2 a/b)
- `samen_core/lib/samen/pii_classify.ex` — delegate to `PiiValueShape` (F2.2 a, de-dup)
- `samen_core/lib/samen/no_plaintext_pii/tiers/post_shred/trace_sink_ingress.ex` — honesty moduledoc (F2.2 b)
- `samen_core/lib/mix/tasks/samen.verify.metric_labels.ex` — fixed `:tag_values` crash; lint `:tags` only (F2.3)
- `samen_core/reports/T2.7.md` — corrected STEP-3 runtime-guard prose (F2.2 b)
- `samen_core/test/wide_event_j2_laundered_test.exs` — F2.2 single-token red paths (+7 tests)
- `samen_core/test/metrics_label_lint_test.exs` — F2.3 task-level red path (+2 tests)
- `samen_core/test/catalog_test.exs` — F2.4 project-local scratch root
- `demo/ci.sh` — F2.3 step 9/9 metric_labels; step numbering normalized to /9
- `.gitignore` — F2.4 ignore `samen_core/tmp/` + `gate2_scratch/`

## Caveats / honesty notes

- **F2.2 is intentionally a heuristic.** The tightening catches the obvious single-token PII *literal*
  shapes; it does NOT and cannot prove non-PII for an arbitrary opaque value. Every moduledoc and the
  T2.7 report now say so explicitly, and name the schema-level no-free-string-field check as the
  load-bearing J2 defence. This is the honest closure the mandatory fix required — belt (a) + honesty (b).
- **F2.3 uncovered a real latent crash**, not just a wiring gap. Wiring the task as-was would have
  crashed the CI step, not gated it. The fix makes the task actually run; a new task-level test prevents
  regression. Reported honestly here rather than silently.
- **`:tag_values` is not linted** by the label-lint task (it is a runtime transform function, not a
  static map). If a host uses a `:tag_values` function that injects an `org_id` key at runtime, the
  static lint cannot see it — this is a documented bound of the check, same class as the doc's existing
  "a host stuffs a name into a `non_pii!` column" caveat. The primary label surface (`:tags`) IS gated.
