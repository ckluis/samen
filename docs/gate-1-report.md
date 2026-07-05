# GATE 1 — Phase-1 adversarial gate for `samen_core` (T1.10)

- **Date:** 2026-07-05
- **Gate:** Phase 1 adversarial review of `samen_core` + the `demo/` dogfood app. Four attack lenses
  (verifier evasion, egress leak, shred-vs-restore, doc drift) + a Gate-0 fix-task re-verification.
- **Inputs:** all `samen_core/reports/*` (T1.1–T1.9, audit-fixes, vault-stack-fixes, vault-stack-reaudit),
  `docs/plan.md` §7 Phase 1, `docs/gate-0-report.md`, the vision doc §runs CI-gate block
  (`~/Downloads/samen-foundry.html` lines 693–771), and direct inspection + execution of the code.
- **Gate rule applied (plan §6.4):** a refuted report claim or a false red-path is an automatic no-go.
  `green_with_caveats` is a **go only if** each caveat is a named in-phase fix task or an explicit,
  plan-sanctioned Phase-2 deferral.

---

## Verdict: **GO WITH CAVEATS**

Phase-1 `samen_core` is real, load-bearing, and honestly reported. Every headline guarantee I attacked
held: the vault write path fails closed on plaintext, `%Masked{}` masks on every serialization path
including HEEx, crypto-shred is physically proven against a real `pg_dump`/`psql` PITR round-trip, the
reveal-grant distinct-party invariant is enforced at BOTH the policy and DB-CHECK layers (verified with a
raw-SQL bypass attempt), and four of the five verifiers are fail-closed and correctly key on declarations
rather than name prefixes.

**One P1 finding is genuine and load-bearing:** the C3 `pii_reads` verifier **fails OPEN** when the host
app does not duplicate its Ash domains under the non-standard `:samen_core, :ash_domains` key — a blatant
PII leak then yields exit 0 (empirically confirmed). This is the single mandatory-in-phase fix. The
remaining caveats are minor robustness gaps and plan-sanctioned Phase-2 deferrals.

### Environment / gate results (run by me, not trusted from reports)

| Check | Result |
|---|---|
| `samen_core` `mix test --warnings-as-errors` | **321 passed** (9 properties, 312 tests); deterministic across seeds 917965 / 999 / 1 |
| `samen_core` `mix compile --warnings-as-errors --force` | exit 0, warning-clean |
| `demo` `mix test --warnings-as-errors` | 30 passed (3 properties, 27 tests) |
| `demo` CI gate (`MIX_ENV=test bash ci.sh`, the canonical entry via root `ci.sh`) | **ALL 6 PASSED** (compile + C1–C5) |
| `demo` CI gate (`bash ci.sh`, default dev env) | **FAILS at step 2** — see F3 |
| PITR physical round-trip (`vault_pitr_test.exs`, real pg_dump/psql on PATH) | 2 passed, **not skipped** |
| Reveal distinct-party DB CHECK (`rvg_distinct_party`) raw-SQL bypass | **rejected by Postgres** |

---

## Lens 1 — Verifier evasion

### F1 (MANDATORY, P1) — C3 `pii_reads` fails OPEN when the host app uses the standard Ash config key

**This is the one hard finding.** The C3 registry (`lib/samen/pii_reads/registry.ex:124`) discovers PII
resources exclusively from `Application.get_env(:samen_core, :ash_domains, [])`. If that key is empty —
which is the default for any consumer app that configures domains the standard Ash way
(`config :my_app, ash_domains: [...]`) — the PII taint set is empty and **every leak passes**. There is no
fail-closed guard against an empty PII registry.

**Empirically confirmed (anti-tautology probe, in `demo/`):**

```
EMPTY pii_attributes size: 0
EXIT with EMPTY registry: 0  (leaks found: 0)   # Logger.info(contact.full_name) + Logger.info(contact.pii_cnt_dob) — MISSED
FULL  pii_attributes size: 6
EXIT with FULL  registry: 1  (leaks found: 2)   # same leaks, CAUGHT
```

The finding is load-bearing by construction: the absence of the empty-registry guard IS the defect (there
is nothing to sabotage-then-revert; the probe above is the discriminating pair). The demo only passes
because `demo/config/config.exs` explicitly duplicates `config :samen_core, :ash_domains, [Demo.Crm]`. The
T1.9 report frames this as a "documentation/convention gap"; it is actually a **fail-open safety defect** —
a misconfigured consumer ships a silently-disabled C3.

**Compounding:** the discovery key is **inconsistent across the verifier suite** — C1 `catalog_parity`
(`samen.verify.catalog_parity.ex:219`) and C4 `pii_classify` (`samen.verify.pii_classify.ex:129`) both
discover from `Mix.Project.config()[:app]` (the portable host-app key, e.g. `:demo`), while C3 alone
hardcodes `:samen_core`. So on a standard consumer, C1/C4 work and C3 silently no-ops — the worst kind of
inconsistency (partial green hides the hole).

### Verifier evasions that are CLOSED (I tried, they held)

- **Explicit-`source:` unprefixed column** (`attribute :ssn, :string, source: :ssn`): the abbrev opt-out in
  `AbbrevStorage` (`source in [nil, name] -> prefix; else honor`) lets an unprefixed physical column
  through the transformer — but the C2 `prefixes` verifier scans every physical column of every
  `tam_table` resource against its registered abbrev and flags it. Backstop holds.
- **Whole uncatalogued resource / ghost table:** Gate-0 fix #5 ghost-table check
  (`catalog_parity.ex:218`) discovers resources from domains and flags any with an AshPostgres table absent
  from `tam_table`. Holds.
- **`reveal_*`-named non-reveal function leak** (S0.7 spike's evasion): C3 keys reveal-scope suppression on
  the persisted `:samen_pii_reveal_actions` MapSet (real Ash `reveal :action` marker), not a lexical
  prefix. `def reveal_report/1` is a flagged leak (closed-evasion corpus case E1). Gate-0 fix #6a holds.
- **Aliased sink** (`alias Logger, as: L; L.info(...)`): resolved from module context and flagged (E4).
- **Self-approved reveal grant via raw SQL:** rejected by the `rvg_distinct_party` DB CHECK constraint
  (verified live against `demo_test`). Policy layer AND DB layer both enforce distinct-party.

### F2 (carry-to-P2) — C3 sink list is small; several real sinks are unmodeled

C3 only recognises `Logger`, `IO`, `OpenTelemetry.Tracer/Span`, and bare `*_sink`/`emit_event` calls. A
plaintext PII read passed to `:telemetry.execute/3`, `Sentry.capture_message/1`, `File.write/2`,
`send/2`, or an `Ecto` insert into a non-vault table sails past C3 today. This is **within the doc's stated
bound** ("a dataflow match, NOT a sound taint proof"; the J2 sink-schema allow-list is the Phase-2
backstop) — so it is not a Phase-1 acceptance failure, but the sink inventory should grow and the J2
allow-list (T2.7) is the real closure. Note the `rvg_reason`/`rvq_reason`/`rvl_detail` audit columns are
allow-listed as "operator-authored free text"; if a host misuses them to carry subject content, C3 is the
only catch — and F1 means C3 may be silently off. The two compound.

---

## Lens 2 — Egress leak

No plaintext egress path found. `%Masked{}` (`lib/samen/masked.ex`) carries only `{token, label}` — never
plaintext — and implements `String.Chars`, `Inspect`, `Jason.Encoder`, `Phoenix.HTML.Safe`, and
`to_iodata/1`, all returning `"••••"`. The struct structurally contains no plaintext, so no serialization
path can leak by omission. Confirmed:

- **HEEx render** (Gate-0 fix #1): `Phoenix.HTML.Safe` impl is compiled (`phoenix_html ~> 4.1` is a real
  dep) and the demo's `DemoWeb.ContactLive` renders `%Masked{}` fields; `live_view_masked_test.exs` +
  `masked_render_test.exs` prove `"••••"` with no raise. The S0.5 unmet acceptance clause is closed.
- **Write path fails closed:** `Samen.Type.VaultField.dump_to_native/2` refuses any non-token value with
  `:error`, so a resource whose `Vault.Change` didn't run cannot persist plaintext to the domain column
  (the create/update raises). The one domain column IS the token column — no plaintext side column exists
  (verified: all 5 patient PII columns are `text` token columns).
- **Single decrypt chokepoint:** `Samen.Chokepoint` structurally asserts exactly one sanctioned
  `Crypto.decrypt(` call site in `vault.ex`; a planted second call is a red-path.

Residues (documented, non-blocking, confirmed not leaks): composite reveal returns the JSON-encoded binary
rather than a typed `%FullName{}` (plaintext still exits only via `reveal/3`); read-path `%Masked{}` carries
the generic `:vault` label (labels never carry plaintext); the `Chokepoint` scanner is a literal string
match an aliased `C.decrypt(` evades (C3 is the real check — and F1 applies).

---

## Lens 3 — Shred vs restore

Crypto-shred is the strongest part of the kernel and I could not break it.

- **Physical PITR round-trip proven, not mocked:** `vault_pitr_test.exs` writes PII → `pg_dump` → shred →
  `psql` restore into a fresh DB → the restored ciphertext survives but `Vault.reveal` returns
  `:shredded`/`:unavailable`. The strongest variant points the key store at an empty dir (DB-only restore)
  and still denies. `pg_dump`/`psql` are on PATH, so the test RAN (2 passed, not skipped). A non-vacuous
  sanity guard proves that WITHOUT the shred the same pipeline DOES decrypt.
- **Attestation is a positive tombstone, not mere absence:** `erased?/1` (`erasure.ex:257`) requires ALL
  of `attest == :shredded` AND `key_material_present? == false` AND `0 active vault rows`. `:absent` fails
  closed (does not count as erased) — the Gate-0 P2 defence-in-depth (a tombstone written while the DEK
  survives is NOT an erasure) is genuinely wired (`LeakyShredAdapter` red path in
  `shred_key_material_test.exs`).
- **Shred is key-first, outside the DB tx:** `Erasure.shred/2` destroys the external DEK before sealing
  DB tiers; a KMS outage fails closed (`{:error, {:kms_shred_failed, reason}}`) with no fabricated
  attestation, no sentinel, no report. The DB-tier seal (sentinel + non_pii! redaction + audit + report)
  is one `Ecto.Multi`.
- **Pseudonym unlinks on shred** (RQ5): the trace-sink pseudonym rides the same DEK; one shred unlinks it.

Deferral (plan-sanctioned, not a Phase-1 gap): the **post-shred oracle** (`no_plaintext_pii --subject
<uuid> --tiers all`) is Phase-2 (T2.9). Phase-1 ships CI-mode only. See F4.

---

## Lens 4 — Doc drift + Gate-0 fix re-verification

### Gate-0 fix tasks #1–#6 — all landed (re-verified)

| Fix | Where | Status |
|---|---|---|
| #1 LiveView `%Masked{}` renders `••••` | `masked.ex` `Phoenix.HTML.Safe` impl + `phoenix_html` dep | **LANDED** — HEEx render tests green |
| #2 abbrev ordering + C2 backstop | `AbbrevStorage.after?(BelongsToAttribute)` + `prefixes.ex` physical check | **LANDED** — FK prefix + C2 verified |
| #3 fragment-extension allow-list gate | `resource.ex:135 verify_fragment_extensions!` via `Code.ensure_compiled/1` | **LANDED** — rogue-fragment red path in `resource_red_path_test.exs` |
| #4 `catalog_sync` refuses `@disable_ddl_transaction true` | `migration.ex __guard_ddl_transaction__!` | **LANDED** (per T1.2 report; runtime guard) |
| #5 resource↔tam_table ghost check | `catalog_parity.ex:218 ghost_table_check` | **LANDED** — demo probe (ghost column) exit 1 |
| #6 C3 keys on real `reveal :action`, resolves aliases, real registry | `pii_reads.ex` + `registry.ex` + `RevealActions` transformer | **LANDED** — closed-evasion corpus E1–E4 caught |
| #7 oracle `:absent==FAIL` + store-config assert | — | **Correctly Phase-2 (T2.9)**; `erased?/1` already fails closed on `:absent` |

### Doc-vs-implementation drift

- **F3 (minor, P1-robustness):** the vision §runs CI gate is `compile && catalog_parity && prefixes &&
  pii_reads && pii_classify && no_plaintext_pii` — `demo/ci.sh` implements exactly these 6 steps and passes
  under `MIX_ENV=test` (the canonical invocation the root `ci.sh` uses). But run **directly**
  (`bash demo/ci.sh`, default dev env) it **FAILS at step 2**: the `catalog_parity_allow_list`
  (`cnt_notes`, `cnt_subject_id` — the intentional `non_pii!` shadow columns) is configured only in
  `config/test.exs`, so in dev the two shadow columns are flagged as uncatalogued. The gate is green as
  *intended* (root ci.sh forces test env), but the obvious direct invocation is red. Move the allow-list
  to a shared config and/or have `demo/ci.sh` self-select the env.
- **F4 (carry-to-P2, plan-sanctioned):** the doc presents `mix samen.verify.no_plaintext_pii --subject
  <uuid> --tiers all` as "what you show an auditor." Phase-1 ships CI mode only and the task's
  `OptionParser` will **raise** on `--subject`/`--tiers` rather than print a "Phase-2" message. Plan scopes
  this to T2.9. Acceptable deferral; a graceful "post-shred mode is Phase 2" message would be kinder.
- **F5 (carry-to-P2):** plan B3 / T1.2 deliverable is a **committed** `schema.dict.json`. The
  `mix samen.catalog.dump` task exists, but no `schema.dict.json` is committed in `demo/` or `samen_core/`.
  Consequence: C4's "new column" baseline is empty, so C4 runs in its most-conservative "all columns are
  new" mode (fail-safe — it does not weaken C4). Commit the artifact and wire the dump into CI.
- **F6 (housekeeping):** a stale `demo/erl_crash.dump` (4.8 MB, "Runtime terminating during boot" — the
  normal artifact of a verifier `:erlang.halt(1)`) is checked into the demo working tree; the root `ci.sh`
  leaves `spikes/s03_fragments` and `spikes/s04_catalog_tx` commented out (their mechanisms are ported into
  and tested in `samen_core`, so not a coverage gap — just spike-suite drift).

### Honestly-reported residues I confirmed accurate (not drift)

Composite JSON reveal, `%Masked{}` `:vault` label, `AwsKmsDynamo` not exercised against live AWS (ADR-001
§8.1 "no live AWS in CI"), T1.9 coverage 68% (< 90% target — driven by Mix-task CLI paths + auto-derived
`Inspect` impls; key functional modules are 82–100%). All match the reports.

---

## Fix tasks

1. **[F1 · MANDATORY-IN-PHASE · P1]** Make C3 `pii_reads` **fail closed on an empty PII registry**: if the
   built registry has zero PII attributes, the mix task must EXIT 1 with a diagnostic ("no PII resources
   discovered — configure `ash_domains`; refusing to pass a vacuous check"), not exit 0. AND unify
   domain discovery across verifiers: C3 should discover from `Mix.Project.config()[:app]`'s `:ash_domains`
   (as C1/C4 do), falling back to `:samen_core` only as a legacy alias. Add a red-path test:
   empty-registry + planted leak → exit 1.
2. **[F3 · MANDATORY-IN-PHASE · P1]** Make the demo CI gate green in its default environment: move
   `catalog_parity_allow_list` to a shared config (or `config/dev.exs`) and/or have `demo/ci.sh` export
   `MIX_ENV=test`. Running `bash demo/ci.sh` directly must not fail on the two intentional shadow columns.
3. **[F5 · carry-to-P2]** Commit `schema.dict.json` (via `mix samen.catalog.dump`) for the demo and wire
   the dump/check into CI so C4's baseline is real (satisfies plan B3 "committed artifact").
4. **[F2 · carry-to-P2]** Grow the C3 sink inventory (`:telemetry.execute`, `Sentry.*`, `File.write`,
   `send/2`) and land the J2 sink-schema allow-list (T2.7) as the laundered-leak / unmodeled-sink backstop.
5. **[F4 · carry-to-P2]** When `--subject`/`--tiers` are passed to `no_plaintext_pii` in Phase 1, print a
   clear "post-shred oracle is Phase-2 (T2.9)" message instead of an `OptionParser` raise.
6. **[F6 · housekeeping · P1]** Remove/gitignore `demo/erl_crash.dump`; either re-enable the s03/s04 spike
   rows in root `ci.sh` or delete them with a note that the mechanisms are covered in `samen_core`.

---

## Gate decision

**GO WITH CAVEATS.** Phase-1 `samen_core` delivers the load-bearing idioms with fail-closed proofs that
survive adversarial probing: vault write-fails-closed, `%Masked{}` egress masking (HEEx included),
physically-proven crypto-shred + PITR resistance, dual-layer distinct-party reveal grants, and four of five
verifiers that key on declarations and fail closed. All six Gate-0 fix tasks (#1–#6) genuinely landed and
their red paths re-verified. The one real hole — **C3 fails open on a misconfigured / standard-convention
consumer (F1)** — plus the **demo gate being red in its default env (F3)** are the two mandatory-in-phase
fixes; both are contained config/guard changes, not re-architecture. The rest are plan-sanctioned Phase-2
deferrals and housekeeping. Proceed to Phase 2 once F1 and F3 land.
