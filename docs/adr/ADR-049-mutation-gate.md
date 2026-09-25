# ADR-049 — Mutation testing as a gate: mechanical enumeration of the failure modes nobody thought to sabotage

- **Status:** **Accepted** (2026-09-18)
- **Date:** 2026-09-18
- **Build status:** **SHIPPED with this ADR.** Engine (`scripts/mutation/mutate.exs`), harness
  (`scripts/mutate.sh`), preflight (`scripts/mutation_lint.sh`), anti-tautology self-test
  (`scripts/mutation_selection_test.sh`, 30 assertions), committed watch-list + ledger
  (`scripts/mutation/{targets,ledger}.tsv`), and the `ci.sh` wiring (two unconditional steps
  + one opt-in `SAMEN_MUTATION=1` tier) are all in this change. First tier-1 run: **61 mutants,
  42 killed, 17 survived, 2 build-refused.** Six of those survivors were **closed with tests**
  in the same pass (MG-01…MG-06); the remaining 16 are ledgered as individually-referenced
  ACCEPTED_GAPs and 1 as a proven EQUIVALENT (§7).
- **Task:** Add the one thing the 328-patch sabotage corpus structurally cannot produce — evidence
  about failure modes nobody thought of — without weakening the specificity rule that makes the
  sabotage corpus worth having.
- **Deciders:** no operator decision is required. Every tradeoff below was resolvable from the
  standing house rules (fail-honest, anti-tautology, decompose-cross-cutting-changes). §7 carries
  16 named open items; they are ordinary backlog, not decisions.
- **Consumes (binding inputs):**
  - **the sabotage harness** (`scripts/sabotage.sh`, ADR-045 §4.2) — its selection-flag grammar,
    its five-step apply/run/revert/SHA contract, and its `APP:`/`TEST_FILES:` headers, which this
    gate reuses as a *derived* owning-test mapping rather than inventing a second one.
  - **`CLAUDE.md` "Chokepoints / guards"** — the module list that defines tier 1.
  - **the standing anti-tautology rule** ("a test that cannot fail is a bug") — restated here one
    level up, as "a gate that cannot report a survivor is a bug".

---

## 1 · Context — the blind spot, stated precisely

The sabotage harness replays 328 hand-authored patches and proves each still flips its **named**
tests. That is a strong and unusual guarantee, and the landing page is right that the naming is
what distinguishes it from mutation testing that merely counts breakage.

But every sabotage is a claim **someone thought to make**. The corpus can only ever cover the
failure modes its authors imagined, and it cannot tell you what it is missing — asking a corpus
of claims about its own completeness is circular. The gap is not hypothetical: the verification
session that motivated this ADR spent its effort hand-applying one-off mutations to source
modules and checking that named tests flipped (see `_orch-runs/adr048-coverage-20260916/nodes/G*/
work/control/*.mutation.log`), i.e. doing mutation testing by hand, per finding, and throwing the
apparatus away each time. That is the tell: a ritual performed by judgment every round is
infrastructure that has not been written yet.

Two properties made this cheap enough to be worth building here specifically:

1. **The owning-test mapping already exists.** Every sabotage's `APP:` + `TEST_FILES:` headers
   assert "these named tests guard this file", and the sabotage harness already *proves* that
   assertion. Across 328 patches that is a gate-proven file→suite map covering 155 `lib/` files.
2. **A mutant cycle costs ~2 seconds.** Elixir's incremental compile means apply → `mix test
   <owning files>` → restore is fast, so a curated tier is a few minutes, not an overnight soak.

## 2 · Decision

Ship a mutation gate that **mechanically enumerates** mutation sites in a declared watch-list and
requires each mutant to be killed by that file's **owning** tests.

The specificity objection is answered by construction, not by argument: **only the owning test
files run.** A mutant to `chokepoint_guard.ex` must be killed by `files_upload_test.exs` — a kill
by some unrelated suite three apps away is not available as an outcome, because that suite is
never invoked. Where the owning-test column is derived from the sabotage headers, the attribution
is already gate-proven. So this gate does not count breakage; it asks a *named* suite a question
it has not been asked.

### 2.1 Operator families (four, and why not more)

| family | mutations |
|---|---|
| `EQ` | `==`→`!=`, `!=`→`==`, `===`→`!==`, `!==`→`===` |
| `REL` | `>`→`>=`, `>=`→`>`, `<`→`<=`, `<=`→`<` |
| `BOOLOP` | `and`→`or`, `or`→`and`, `&&`→`\|\|`, `\|\|`→`&&` |
| `BOOLLIT` | `true`→`false`, `false`→`true` |

These four are exactly the shapes this repo's mechanisms fail in: a fail-closed default
(`BOOLLIT`), an off-by-one threshold (`REL`), a weakened condition (`BOOLOP`), an identity check
(`EQ`). Families whose replacement changes arity or precedence class — `not`/`!` removal, `in`→
`not in` — are **excluded on purpose**: they produce mutants whose behaviour change is real but
not attributable to the line a reader is looking at, and an unattributable mutant is the same
vacuity the sabotage corpus exists to refuse.

Sites come from `Code.string_to_quoted/2` with `columns: true` (plus a `literal_encoder` so bare
booleans carry position metadata), never from a regex, so a site is by construction a real
operator in real code — not an `==` inside a string, a comment, or a `@moduledoc`. Boolean
literals under `@moduledoc`/`@doc`/`@typedoc`/`@impl`/`@deprecated`/`@derive` are skipped: flipping
`@moduledoc false` is a guaranteed-equivalent mutant, i.e. permanent ledger noise. The mutation
itself is a codepoint-exact splice at the site's line/column, which is what makes the byte-exact
restore contract cheap and total.

### 2.2 The five contracts

1. **Baseline green first.** Before a target's first mutant, its owning tests run UNMUTATED and
   must pass. Skipping this is the vacuity that makes a mutation gate lie: against an already-red
   suite every mutant "fails" and the gate reports a confident 100% over a broken suite.
2. **A kill is a named test failure.** The run must fail AND emit at least one `N) test …` header.
   A non-zero exit with no test header means the mutant never reached a test — the **compiler**
   refused it. That is scored `BUILD-REFUSED`, never a kill: such a mutant cannot exist in a tree
   that compiles (correct-by-construction, no test owes anything), and crediting the suite for the
   compiler's work is this family's other false green. The gate deliberately does **not** pass
   `--warnings-as-errors` to the owning suites, so a warning can never masquerade as either.
3. **Byte-exact restore.** Snapshot per target; restore + SHA-256 verify after every mutant, on
   every exit path including SIGINT/SIGTERM. Residue fails the run.
4. **A survivor fails the gate** unless it carries a ledger entry (§3).
5. **The full report comes first.** Unlike `sabotage.sh` (fail-fast), this runs the whole selection
   and fails at the END — the value of a mutation run is the complete survivor list.

### 2.3 Selection

Default = the tier-1 watch-list (`scripts/mutation/targets.tsv`, 8 targets / 61 mutants / ~3 min),
which is what `ci.sh` runs. `--corpus` derives targets from the sabotage headers instead (163 (file, app) rows over 155 distinct lib files / 2,852 mutants) — a soak, not a gate step. Flags mirror `sabotage.sh`'s grammar exactly
(`--app`, `--file`, `--family`, `--changed [<ref>]`, `--list`/`--dry-run`; same-flag-twice is an
error; different flags intersect; a filtered run's success line is deliberately distinct from a
full run's). Two additions:

- `--shard <i>/<n>` — a deterministic partition of the mutant list, proven disjoint-and-total by
  the self-test, so a 2,852-mutant soak can be swept across runs with no overlap and no gaps.
- `--emit-patches <dir>` — writes each survivor as a sabotage-format patch with headers pre-filled
  and `MUST_FAIL` left as a TODO. This is the **promotion path**: write the test, fill `MUST_FAIL`,
  move the file into `scripts/sabotages/`, and a mechanically-found hole becomes a permanent
  hand-named guarantee. The two harnesses feed each other rather than competing.

`--changed` unions `git diff --name-only <ref>` with `git ls-files --others --exclude-standard`,
for the same load-bearing reason it does in `sabotage.sh`: `git diff` never lists new files, so
without the union a batch that ADDS a guard module selects none of its own mutants.

## 3 · The ledger — the one lever that can turn a red gate green, and its guards

`scripts/mutation/ledger.tsv` is the only way a survivor can be accepted, so it gets the strictest
checks in the system.

- **Content-pinned, not line-pinned.** A row's key is
  `relpath | line_sha12 | col | family | from>to`, where `line_sha12` is SHA-256 over the **exact
  source line** the exemption excuses. Inserting lines above a justified survivor keeps the
  exemption valid; **editing that line expires it** — the row then matches no live site and
  `mutation_lint.sh` fails it as STALE. An exemption cannot outlive the code it was written about,
  which is the whole reason the file is safe to have.
- **Two classes, no third.** `EQUIVALENT` (the mutation provably cannot change behaviour; the
  reason must say why, specifically) and `ACCEPTED_GAP` (it does change behaviour and no test
  catches it — a real hole, consciously deferred, whose reason **must** carry a `ref=` naming the
  ADR or backlog item that owns it). There is no bare "won't fix".
- **Obsolescence is refused too.** On an unfiltered run, a ledger entry whose mutant is now
  **killed** fails the gate: delete the row. An exemption that outlives the gap it excused is how
  a ledger stops being a debt list and becomes a blindfold.
- Exempt survivors are counted and printed **separately** from unexempt ones, so no report can
  round a ledgered hole into a clean number.

## 4 · What did NOT get built, and why

- **No whole-suite mutation.** Running every mutant against every test would restore exactly the
  attribution problem the house objection names.
- **No `--warnings-as-errors` on the owning suites.** See contract 2.
- **No kill-result cache.** A cache would let a gate report a kill it did not observe. The cost is
  that a corpus-wide sweep is a soak; `--shard` makes that schedulable, which is the honest trade.
- **No Ash resource/blueprint DSL files in tier 1.** Their `public? true` / `allow_nil? false`
  option flips generate hundreds of low-signal sites. Reachable via `--corpus`; not a gate step.
- **No auto-generated ledger rows.** Every exemption is written by a human with a reason, or the
  gate stays red.

## 5 · Tier 1 (the committed watch-list)

The structural chokepoint/guard set — the modules `CLAUDE.md` calls governed-by-construction,
whose failure mode is a silent policy bypass rather than a visible crash:
`files/chokepoint_guard.ex`, `pii/write_guard.ex`, `vault/change.ex`, `pii/classification.ex`,
`delivery/chokepoint.ex`, `approvals/gate.ex`, `policy/same_org_fk.ex`, `scope_mask_case.ex`
(the masking test-infra itself: if *it* can be weakened undetected, every masking proof built on
it is suspect). Adding a row requires running the gate on it first — a row whose owning suite does
not kill its mutants must not be committed green.

## 6 · Proof that the gate itself is refutable

`scripts/mutation_selection_test.sh` (30 assertions, ~15s, no database, applies no real mutant)
drives the gate's **scoring logic** against a throwaway probe module with stub runners. A mutation
gate's failure mode is not a crash — it is a confident, wrong number — so each way it could lie
has a negative control:

| # | control | what it would hide |
|---|---|---|
| 5 | a runner that always PASSES ⇒ every mutant survives ⇒ gate FAILS | a gate that cannot report a survivor reports 100% forever |
| 6 | a failure with no test header ⇒ `BUILD-REFUSED`, zero kills | crediting the suite for the compiler's work |
| 7 | a RED baseline ⇒ gate fails before scoring, and prints **no score** | 100% over an already-broken suite |
| 9 | a ledger row with a stale line hash ⇒ lint FAILS | exemptions outliving their code |
| 10/11 | `ACCEPTED_GAP` with no `ref=` / a 3-char reason ⇒ lint FAILS | a deferred hole with no owner |
| 12 | an exemption whose mutant is now killed ⇒ gate FAILS obsolete | the ledger becoming a blindfold |
| 13/14 | a zero-site target / a missing owning test file ⇒ lint FAILS | a watch-list row that certifies nothing |
| 2 | the engine refuses to splice where the expected token is absent | a stale site silently corrupting a source file |
| 15 | `--shard` shards proven disjoint **and** total | a sharded sweep double-running some mutants while missing others |

Both `mutation_lint.sh` and this self-test are **unconditional** `ci.sh` steps (~17s combined, no
DB, no mutant applied). The replay tier is opt-in (`SAMEN_MUTATION=1`), matching the sabotage
harness's posture for the same reason: it deliberately breaks the tree 61 times.

## 7 · First-run findings

61 mutants · 42 killed · 17 survived · 2 build-refused. **Closed with tests in this change:**

| id | finding |
|---|---|
| MG-01 | `Pii.Classification.pii?/1` — the public "is this type PII" predicate — could be **inverted** with nothing noticing. Its owning suite tested `classify/1` exclusively; `pii?/1` had zero coverage. An inverted `pii?` is a total fail-open. |
| MG-02 | `classified?/1`'s unknown-type branch answered on **atom-ness** instead of non-PII-registry membership under `and`→`or`, making every atom "classified" and handing the C4 verifier a deliberately-plain column that is only plain because nobody classified it. |
| MG-03 | `ScopeMaskCase.assert_scope_masked!/3`'s anti-vacuity guard (`names == [] and handles == []`) survived `and`→`or`, which would have refused every **one-sided** call — the normal shape of a real mask proof. The masking test-infra's own guard had only its both-empty case tested. |
| MG-04 | `Delivery.Chokepoint.resolve_provider/3` returns `nil` when nothing is wired; `is_atom(nil)` is `true`, so the `and not is_nil(...)` half is the entire guard. Under `or` it returns `{nil, %{}}`, which reads downstream as a **resolved provider** — a fail-open onto a nil adapter. Untested. |
| MG-05 | `suppressed?/2`'s `== true` coercion (a backend answering `:probably` has not said yes) was unpinned; `!=` made it report suppressed and silently drop deliverable mail. |
| MG-06 | `suppressed?/2`'s documented **fail-closed-on-raise** promise ("a broken check must never silently let a send through") had no test; flipping that literal turns a crashed suppression backend into a green light for every send. |

Plus one finding **outside** the mutation score: the gate's rapid repeated `mix test` invocations
exposed a latent race in `samen_core/test/test_helper.exs`, where a previous run's lingering
connections defeat `storage_down` and the following `storage_up` answers `{:error, :already_up}` —
surfacing as a bare `MatchError`. Fixed by retrying the drop and then failing **loudly** with the
reason; `:already_up` is deliberately *not* tolerated, because the drop is what makes the schema
match the generated migrations, and accepting an un-dropped database would quietly run the suite
against a stale schema.

**Open items (ledgered `ACCEPTED_GAP`, `ref=ADR-049#MG-nn`).** Ordered by severity:

| id | target | finding |
|---|---|---|
| MG-19 | `approvals/gate.ex` | **Highest.** The approval-execution changeset's `authorize?: true` is what keeps an approved action inside its resource's own policies. The mutant turns the approval gate into a policy **bypass** and the owning suite does not notice. Needs a requester whom policy refuses, approved anyway, and still refused. |
| MG-20 | `policy/same_org_fk.ex` | **Second.** Inverting `all_belongs_to/1`'s filter hands the cross-org FK guard every *non*-belongs_to relationship, and the suite's cross-org refusal **still passes** — so either that refusal is produced by a different code path than the one it credits, or the validation is a no-op on the mutated set. Investigate before writing the test. |
| MG-07 | `files/chokepoint_guard.ex` | `sets_storage_key?/1`'s documented "an explicit nil is not a mint" clause is untested (fail-closed direction). |
| MG-08…10 | `pii/write_guard.ex` | `plaintext_write?/2`'s three round-trip clauses (`%Masked{}`, `vt_*` token, explicit nil) are untested; each mutant refuses a legitimate governed re-save (fail-closed direction). |
| MG-11/12 | `vault/change.ex` | The composite-except-`Address` cast branch is unexercised — no owning-suite target declares a composite vault field. One fixture pair closes both. |
| MG-13…15 | `vault/change.ex` | `subject_id/1` and `ensure_subject_attr/2`'s existing-pk paths and cond fallthrough are unexercised: no update-path vault write in the owning suite, so a fresh-UUID subject (which would orphan ciphertext from its row) goes unnoticed. |
| MG-16/17 | `vault/change.ex` | `repo!/1`'s three-step fallback chain has no test pinning its order or its raise; under test config every step resolves to the same repo. |
| MG-18 | `approvals/gate.ex` | The deliberate `authorize?: false` on the §4.4 re-derivation read is unpinned (fail-closed direction, but it silently changes who can be approved for what). |
| MG-21 | `policy/same_org_fk.ex` | `target_org_id/2`'s repo fallback order is unpinned (same shape as MG-16). |
| MG-22 | `policy/same_org_fk.ex` | The `:no_data_layer` bail-out needs *either* a missing repo or a missing table; the mutant requires both, so a half-configured data layer walks past it. |

One survivor is ledgered `EQUIVALENT` with a proof rather than a ref: `same_org_fk.ex`'s
`load_uuid/1` guard `is_binary(bin) and byte_size(bin) == 16` has a catch-all sibling
`defp load_uuid(other), do: other`. Widening to `or` admits other-length binaries into the clause,
where `Ecto.UUID.load/1` returns `:error` and the clause returns `bin` — byte-identical to what the
catch-all returns; non-binaries still fall through (`byte_size/1` raises inside a guard, which
reads as false). No input can observe a difference.

**Honest reading of the 71% score.** It is not a grade on the repo; it is a measurement of eight
deliberately-chosen guard modules against their declared owning suites, and its value is the named
list above, not the number. The two build-refused mutants are excluded from the denominator by
contract 2.

## 8 · How this changes the daily loop

- Before a milestone: `SAMEN_SABOTAGE=1 SAMEN_MUTATION=1 ./ci.sh`.
- While changing a guard: `scripts/mutate.sh --changed` (mirrors `sabotage.sh --changed`).
- Adding a watch-list row: run `scripts/mutate.sh --file <path>` first; commit it green or
  ledgered, never red.
- Closing a ledgered gap: write the test, re-run, and the obsolescence check (§3) will *require*
  you to delete the exemption — the ledger shrinks by construction as the tests land.

## 9 · Amendment (2026-09-23, issue #20) — owning tests are DECLARED ∪ DERIVED

§2's owning set was declared only (`targets.tsv` column 3, sabotage `TEST_FILES`). That broke the
last bullet of §8 in practice: PR #26 closed 14 ledgered gaps with proofs in NEW files
(`samen_core/test/hardening/*`), the gate never ran them, and the ledger could not shrink. Each
target's owning set is now UNIONED with `mutate.exs owners`: test files in the target's app whose
AST names one of its modules exactly (aliases expanded; a submodule never names its parent), plus
any file carrying `# MUTATION_OWNS: <repo-relative lib path>` — for proofs that drive a guard
through the resource that uses it, where following references transitively would make nearly
every test own `Samen.Vault.Change`. The specificity argument in §2 holds: a derived test named
the module (or claimed it, lint-checked), and the evidence section still names which test killed
each mutant. Cost: the tier-1 replay went from ~3 to ~5 min (the owning sets grew from 8 to 36
files). Self-test assertion 17 pins both rules and their negative controls.
