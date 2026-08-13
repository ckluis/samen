# ADR-046 — Erasure completeness: making `Samen.Erasure`'s carve-out list complete, and checkable-by-construction

- **Status:** **Proposed**
- **Date:** 2026-08-13
- **Task:** Scope + design the Phase-3 "erasure completeness" cluster from ADR-045 §4.3
  (D1 / D3 / D4-T130 / D5 / D6 / D2 / D7) plus the unifying completeness verifier, and
  sequence it into BATON fix→verify batches. **This ADR authors no product code.** It is
  docs-only per the standing decompose-cross-cutting-changes rule: it touches no source, no
  test, no sabotage, no abbrev-registry row, no `schema.dict.json`. The build lands in the
  batches §5 sequences, each with its own gate.
- **Deciders:** the operator for the two genuine tradeoffs in §7 (D1's crypto approach, which
  amends ADR-035 §4.1; and building `Storage.delete` now, which makes T130 live). The rest is
  recorded design a BATON builder can execute without re-deriving.
- **Consumes (binding inputs):**
  - **ADR-045 §4.3** — the Phase-3 dispositions this ADR designs. IDs (D1…D7, T130) travel
    from the LUMINARY panel-3 report (`_orch/luminary-premerge/panel-3-data-privacy.md`,
    gitignored) so evidence stays traceable.
  - **ADR-035 §4.1** — the blind-index (`sys:bidx`) design D1 must amend.
  - **ADR-001** — the per-subject external-KMS key hierarchy and crypto-shred contract the
    "outside the DEK envelope" framing rests on.
  - **ADR-026** — the fail-honest storage-adapter contract `Storage.delete` (D4) must obey.
  - **ADR-002** — the T4.3 tenant hash chain D5's `org_id` binding rides.
  - **ADR-036 D6 / T3.8** — the Tier-1 `pii_declared` custom-bag containment rule D3 hardens.

---

## 1 · Context — the unifying finding, and the current shred/DEK model stated faithfully

`Samen.Erasure.shred/2` is a **key-destruction** job, not a copy-chase. One `Samen.Kms.shred/1`
destroys the subject's DEK in the external key store (outside Postgres/PITR), and every vaulted
value for that subject becomes permanently undecryptable across live / replica / backup-PITR /
CDC / rollup / audit at once — the ciphertext stays as useless bytes; the key is gone. Steps 2–5
(seal the `pii_vault` `shredded` sentinel, redact registered `non_pii!` columns, govern rollups,
write the report + audit) run in one Ecto transaction; step 1 (the key shred) runs first and
outside it, in the fail-safe direction. `erased?/1` keys on **actual key-material destruction**
(`key_material_present?/1 == false`), not the tombstone alone — real defence-in-depth.

The module's moduledoc (`erasure.ex:8-11`) states that key-shred reaches everything **except two
carve-outs**, both "handled explicitly here":

1. **trace-sink pseudonyms** — `Samen.Vault.pseudonym/1` computes `HMAC(psk_S, subject_id)` keyed
   off the **subject's own DEK** (`vault.ex:276` → `Kms.pseudonym(subject_id, subject_id)`). Because
   it is keyed on the subject's DEK, `shred` unlinks it for free — this is the pattern that works.
2. **`non_pii!` plaintext columns** — redacted row-level by `Samen.NonPii.redact_for_subject/3`.

**The panel found the carve-out list is incomplete — there are at least five.** The three
additional residues are each the *same mechanism*: a plaintext-or-linkable value that lives
**outside the per-subject-DEK envelope**, therefore outside the reach of key destruction, and that
no erasure arm touches:

- **D1 — `email_bidx`**, a keyed HMAC of the subject's email under `sys:bidx`, a **shared reserved
  KMS subject `Kms.shred/1` refuses to destroy by design** (`kms.ex:242,278-284`). Un-shreddable per
  subject; leaves an equality oracle over the enumerable email space forever.
- **D3 — `pii_declared: true` custom-bag values**, plaintext PII in a `public?: true` `:map` column
  that `PiiResolution` never resolves and `NonPii` (whole-column) cannot redact key-by-key.
- **D4 — stored file blobs**, raw unencrypted bytes in object storage that **no code path ever
  deletes** (zero `Storage.delete/2` callers in any `lib/`, confirmed §3). This is the same fact
  that keeps **T130** (clone `storage_key` aliasing) non-exploitable — so fixing D4 makes T130 live.

The durable fix is therefore not three point patches but **one completeness verifier** (§6) that
enumerates every such out-of-envelope residue and asserts erasure reaches each — the same
"checkable-by-construction" move the `oban_queues` parity gate made, so a *future* such value cannot
ship unerasable. The existing `pii_classify` baseline structurally cannot do this: `schema.dict.json`
**grandfathers** pre-existing columns, which is exactly how `email_bidx` slipped through.

D5 (retention drops `org_id` on the erasure event) and D6 (DSAR no org binding / plaintext default)
are adjacent erasure/DSAR-path defects, mechanical rather than design-hard. D2 (`SameOrgFk`
org-less-target arm refuses where its own docs say it passes) and D7 (`Csv.compact/1` unwraps a
nested `%Masked{}`) are one-liners carried here to close the Phase-3 queue in one pass.

---

## 2 · D3 reachability — the first action, answered: **LATENT (framework-hardening), not an active leak**

ADR-045 §4.3 makes the D3 disposition conditional on a reachability check: *does any shipped
resource actually declare a `pii_declared: true` custom-bag field that renders to an operator
surface?* **Answer: no. D3 is a latent framework-hardening gap, not an active masking hole.**

Evidence (grep over `samen_core`, `samen_web`, `demo`, `driftwood`, `pawchart` `lib/`, excluding
tests and `priv/templates`):

- Every occurrence of `pii_declared` / `tnt_pii_declared` is in the **framework mechanism itself** —
  `custom_fields.ex` (the `define/…` allocator, `classify_containment/2`), `custom_fields/schema.ex`
  (the `tnt_field` DDL, `default: false`), `custom_fields/change.ex` + `custom_objects/record_change.ex`
  (the write-time PII-shape rejection), `migration.ex:332` (the DDL default), `ai/catalog.ex:208`
  (surfaces the flag to the AI catalog). **None is a resource declaring a live `pii_declared: true`
  bag field.**
- `pii_declared` is a **runtime tenant capability**, not a compile-time resource declaration: an org
  turns it on by calling `Samen.CustomFields.define(…, pii_declared: true)` (`custom_fields.ex:125`),
  which writes a `tnt_field` row with `tnt_pii_declared: true`. That merely *lifts the write-time
  shape rejection* — the value still lands in the sealed jsonb bag, never the vault. **No shipped
  host seeds or defines such a field.** So there is no live surface today rendering `pii_declared`
  plaintext to an operator.

**Consequence for the fix (§4.2):** D3 is scoped as framework-hardening + a proof + a guard — NOT
as a merge-gating live leak. The hazard is real and reachable *the moment an adopter defines such a
field*: the bag is `attribute(:custom, :map, public?: true)`, so it flows into `Csv.columns/1`,
AshJsonApi `default_attributes/1`, and every generic renderer **unresolved on every plane**, and
`NonPii` (whole-column) has no bag-key redaction path. The fix closes the capability's two open ends
(masking + erasure) and adds a guard so a future `pii_declared` bag cannot ship both unmasked and
unerasable. It does **not** rate fix-before-merge, because nothing ships in that state today.

---

## 3 · Confirmations (read directly, not taken from the panel)

- **D1 mechanism confirmed.** `Samen.Auth.BlindIndex.compute/1` = `Base.encode16(HMAC-SHA256(k_bidx,
  normalize(email)))` under subject `"sys:bidx"` (`blind_index.ex:31,55-61`). `sys:bidx` is in
  `@reserved_subjects` and `Kms.shred/1` returns `{:error, :reserved_subject}` for it
  (`kms.ex:242,278-284`) — shredding it would break every login, so it is permanently un-shreddable.
  `email_bidx` is `allow_nil?: false` + unique on Credential (`identity/blueprint.ex:867`) and present
  on Invitation (`:670`); it is **not** vault-routed and **not** a `pii_attribute`, so no erasure arm
  reaches it. The pseudonym carve-out is reached *because* it is DEK-keyed (`vault.ex:276`); the blind
  index breaks exactly that pattern by keying on the shared, un-shreddable `sys:bidx`.
- **D4 / T130 confirmed.** Repo-wide grep for `Storage.delete` callers in any `lib/` returns **zero**
  (the only near-hit is an unrelated `Map.delete`). Both adapters *define* `delete/2`
  (`storage/local.ex:70` — idempotent, `:ok` on `:enoent`; `storage/s3.ex` — fail-honest
  `:not_configured`), and the behaviour declares it (`storage.ex:71`), but nothing calls it.
  `Samen.Clone` copies `storage_key` **verbatim** as an ordinary attribute (its own moduledoc:
  "a `storage_key` reference … the referenced file is RE-LINKED, never deep-cloned or re-uploaded"),
  so a clone and its source **alias the same blob**. T130 is non-exploitable *only* because no delete
  path exists — the instant one does, deleting one aliasing row destroys the other's bytes.
- **D5 confirmed.** `retention.ex:253` builds `shred_opts = if repo, do: [repo: repo], else: []` and
  never threads `org_id`, though the row was just read — so `Erasure.shred/2` falls back to
  `AuditChain.global_org()` (`erasure.ex:80`) and the erasure lands on `"__global__"`, which
  `TenantView.for_org/2` refuses as "not a tenant org". No shipped host configures a `:shred`
  retention spec today — framework defect awaiting first adopter.
- **D6 confirmed.** `Dsar.export_subject/2` defaults `:plane` to `:tenant` (plaintext) and takes
  `:grant?` as a caller-asserted option consulted against no grant checker (`dsar.ex:81-82`);
  `walk_vault/3` and `walk_audit/2` filter on `subject_id` with **no org predicate**
  (`dsar.ex:115,143`). The O9 audit-write precondition already shipped (P2-B); the org-binding and
  grant-check gaps remain. No host wires DSAR to a route today — framework API hazard.

---

## 4 · Per-item design

### 4.1 · D1 (HIGH) — recomputable `email_bidx` after erasure · **a genuine crypto decision → §7**

**The purpose the fix must preserve.** `email_bidx` is an *equality-only, pre-authentication* lookup
index: sign-in, password reset, and invite-matching find a Credential/Invitation **by email before any
subject or org context exists**, and it carries the global "one account per email" uniqueness
invariant. Any fix that breaks pre-auth lookup or global dedupe is a non-starter.

**What must become true after erasure:** an erased subject's email must no longer be **confirmable**.
Today the stored `email_bidx = HMAC(k_bidx, email)` plus the login endpoint gives anyone an equality
oracle over the enumerable email space, forever — post-shred included.

**Options.**

- **(a) Shred/rotate `k_bidx`.** *Rejected.* `k_bidx` is **shared across every subject**; there is no
  per-subject key to destroy. Rotating it invalidates *every* live subject's index at once (all
  logins break) unless every index is recomputed — which requires revealing every subject's vaulted
  email. Global key rotation is a legitimate operation but it is **orthogonal to per-subject erasure**
  and cannot be the erasure arm.
- **(b) Re-key `email_bidx` on the subject's own DEK** (the pseudonym pattern). *Rejected — it
  destroys the index's purpose.* Pre-auth lookup is **circular** under this scheme: at sign-in you
  have an email but not yet a subject, so you cannot compute `HMAC(DEK_subject, email)` without first
  knowing which subject — the very thing the index exists to find. It also breaks global dedupe (two
  subjects with the same email would produce different indexes). The pseudonym works precisely because
  it is looked up *after* the subject is known; the blind index is not.
- **(c) Row-level tombstone `email_bidx` on erasure of the owning principal.** *RECOMMENDED.* On shred
  of the subject that owns the index row, overwrite `email_bidx` with a **fresh 32-byte random unique
  sentinel** (same 64-hex shape, so it satisfies `allow_nil?: false` + unique with **no schema
  migration and no `allow_nil` relaxation**). The sentinel has no `HMAC(email)` preimage, so the
  equality oracle finds nothing for the erased subject; every **live** subject's index is untouched
  (lookup + dedupe fully preserved); and a legitimate **re-registration** with the same email later is
  correctly allowed (fresh subject, fresh real index). This is the arm the completeness verifier (§6)
  then asserts is reached.
- **(d) Per-subject individually-shreddable derived key.** *Rejected* — same circularity as (b) for
  pre-auth lookup; strictly more machinery for no gain.

**Recommendation: (c), tombstone-in-place with a random sentinel.** It is the only option that makes
the erased subject un-confirmable while preserving pre-auth lookup and global dedupe, and it needs no
migration.

**Why this is a genuine operator decision (→ §7), not a code tweak** — it amends **ADR-035 §4.1**, and
two sub-questions have real blast radius:

1. **Tombstone vs. destroy the row.** ADR-045's fix sketch floats "destroy the Credential/Invitation
   rows." That is coherent for a full account deletion but heavier; tombstoning `email_bidx` already
   kills the oracle *and* the login (lookup fails), while preserving the row for any FK
   (`User.credential_id`) / audit reference as a dangling-but-present principal. Recommend tombstone.
2. **The org-less, cross-org Credential.** Credential is **org-less — one human, N orgs**
   (`identity/blueprint.ex:799-801`). A *per-tenant data-subject* erasure (e.g. driftwood erasing a
   CDL holder, subject_id = a per-org record with no Credential) must **not** touch a shared login
   credential — doing so would break that human's access to their *other* orgs. So the blind-index arm
   must fire **only when the erased subject IS the principal that owns the index** (Credential's own
   `subject_id == credential_id`; the Invitation's own subject), i.e. a *principal-account* erasure,
   never a per-org data-subject shred. The builder wires the arm to locate index rows by the owning
   principal's subject_id, not by walking domain FKs. **This scoping is the load-bearing correctness
   condition and belongs in the ADR-035 amendment.**

**Build shape (once the decision lands):** register `email_bidx` (Credential + Invitation) as a new
**derived-linkable erasure arm** — the blind-index analogue of `NonPii` — keyed on the owning
principal's subject_id, tombstoning to a random sentinel. Add an erasure red-path: shred a principal →
its `email_bidx` no longer equals `HMAC(k_bidx, email)` and the email is no longer confirmable via
`compute/1`, with a positive control that a *non-erased* principal's index still matches (anti-vacuity).
Schema-touch: none expected (sentinel fits the existing column) — **confirm during build; if a link
column or index is added, the batch regenerates `schema.dict` via the sanctioned task + FULL gate.**

### 4.2 · D3 — `pii_declared` bag PII · framework-hardening (latent, per §2)

Two open ends of the `pii_declared` capability, plus a guard:

1. **Mask on the operator plane (mask-by-omission).** Route `pii_declared` bag keys through the
   masking seam so an operator without a grant never receives them in the clear. `PiiResolution.resolve/4`
   iterates *declared* `pii_attribute`s only (`pii_resolution.ex:119`); a `pii_declared` bag key is not
   one. Recommended shape: teach the resolver (and the surfaces that render `custom`) to consult the
   org's `tnt_field` catalog for `tnt_pii_declared: true` keys and **omit/`••••`** them on a masked
   plane, exactly as `%Ash.ForbiddenField{}` is omitted today. Because it is a *runtime* per-org set
   (not a compile-time attribute), the resolver reads it from `tnt_field`, so the fix is data-driven,
   not a new attribute macro. (Alternative, cheaper but blunter: **refuse `pii_declared: true` at the
   `define` chokepoint** until routing exists — closes the hazard by forbidding the capability. Prefer
   masking; note refusal as the fallback if masking proves too invasive for one batch.)
2. **Make it reachable by Erasure (per-key redaction).** `NonPii` redacts whole *columns*; the bag is
   one `:map` column with many keys. Add a **bag-key redaction arm** to erasure: on shred of the
   subject owning a bag row, null the `pii_declared` keys (identified from `tnt_field`) in that row's
   `custom` map, leaving non-PII keys intact. Register it so the completeness verifier (§6) asserts it.
3. **Guard.** A `MaskingCase` three-proof (tenant clear · operator masked · sabotage twin) for a
   `pii_declared` bag field on at least one surface (CSV or JSON:API), **plus** the completeness
   verifier's assertion that a `pii_declared`-capable bag column has both a masking arm and an erasure
   arm — so a future adopter's `pii_declared` field cannot ship both unmasked and unerasable.

### 4.3 · D4 / T130 (MED) — no file-blob deletion; clone aliases `storage_key` · **must ship together**

This is a **new capability** (a delete path that does not exist), so its surface is scoped carefully.

**`Storage.delete` chokepoint.** Introduce a single governed deletion entry point (the delete twin of
`Samen.Files.upload/3` — the only `storage_key` mint) that:
- calls the configured adapter's `delete/2` (already defined, fail-honest, idempotent);
- is **fail-honest** (ADR-026): an unconfigured adapter returns `{:error, :not_configured}`, never a
  faked `:ok` — a deletion that did not happen must not report success on a compliance path;
- is **chokepoint-guarded** — like `ChokepointGuard` refuses ungoverned `storage_key` *mints*, deletion
  runs only through this path (who may call it: the erasure/retention drivers and the File
  destroy action, never ad-hoc callers), **fail-closed**, and **audited** (a token-only "blob deleted"
  event; never the filename or key in the clear).

**Ref-counting (the T130 half — non-negotiable to ship together).** Because `Clone` aliases
`storage_key`, N File rows can point at one blob. A delete keyed on the blob would destroy a
still-referenced clone's bytes. Two coherent shapes:

- **(i) Reference count / last-reference delete (RECOMMENDED).** Delete the blob only when the *last*
  File row referencing that `storage_key` is destroyed/shredded; earlier deletes drop the row and
  decrement. Simple, no re-upload, matches the "shallow re-link" clone semantics already documented.
- **(ii) Re-tokenize clones to independent blobs at clone time.** Make `Clone` copy the *bytes* (a
  governed re-upload) so every File owns its own blob, then delete is unconditional. Cleaner isolation
  but changes clone's documented shallow-copy contract and adds a re-upload cost; heavier.

Recommend **(i)** — it preserves clone's contract and localizes the change to the delete path. The
build lands `Storage.delete` **and** ref-counting **in one batch**, with a red-path proving: a
shredded subject's blob is **gone** from storage, AND an aliasing clone **cannot** be resurrected /
its bytes destroyed by the other's deletion (both directions), plus a positive control that a
single-reference blob *is* deleted. **T130 goes live the moment `Storage.delete` exists — they MUST
ship in the same batch, never separately** (ADR-045 §3 sequencing note; restated here as a hard
constraint).

*Out of scope, named:* encryption-at-rest for blobs (`Local.put/3` writes raw bytes). Erasure of blobs
is by **deletion**, not crypto-shred — the DEK envelope never covered blob bytes. This ADR does not add
at-rest blob encryption; it makes deletion reach them. Named as a residual, not silently dropped.

### 4.4 · D5 (MED) — retention shred lands on `__global__`

Thread `org_id` from the just-read row into `shred_opts` in `retention.ex`'s `:shred` arm
(`retention.ex:237-259`): resolve the row's org (the retention spec knows the resource; add an
`org_field` to `Retention.Spec`, defaulting to `:org_id`) and pass `org_id:` to `Erasure.shred/2` so
the erasure event rides that org's T4.3 chain (ADR-002) instead of falling back to `AuditChain.global_org()`.
Mechanical. Reachability caveat: no shipped host configures a `:shred` spec, so this is closing the
framework defect ahead of the first adopter. Schema: `Spec` is a plain struct (no DB) — **no schema.dict
touch** unless an `org_field` needs persistence (it does not; it is config).

### 4.5 · D6 (MED) — DSAR no org binding / plaintext default

Two changes to `Dsar.export_subject/2`:
1. **Require an org predicate** on both `walk_vault/3` and `walk_audit/2` (`dsar.ex:115,143`): add
   `:org_id` as a required option and filter `v.org_id == ^org_id` / `e.org_id == ^org_id`, so an
   export cannot gather another org's rows for a caller-supplied `subject_id`. (Vault rows carry no
   `org_id` today — **confirm during build**; if they do not, bind via the domain row's org or make
   `org_id` a hard required arg that the caller must have authorized. This is the one D6 unknown:
   whether `pii_vault` is org-taggable or the org must be asserted by the caller's scope. Flag it.)
2. **Check the grant, don't trust it.** Consult `Reveal.grant_checker/0` for the operator plane rather
   than taking `:grant?` as a caller-asserted boolean; default remains fail-closed (masked). The
   moduledoc's "NO cross-tenant leakage" claim then holds for *orgs*, not only planes.

Reachability: no host wires DSAR to a route — framework API hazard. If (1) requires tagging vault rows
with org, that batch regenerates `schema.dict` + FULL gate; otherwise docs/logic only.

### 4.6 · D2 / D7 — the two one-liners

- **D2 (MED).** `Samen.Policy.SameOrgFk`'s org-less-target arm returns `{:error, :target_has_no_org_id}`
  (`same_org_fk.ex:170-176`), which `validate_relationship/3` routes into `add_error` — refusing the
  write, the **opposite** of both its own inline comment ("treat as a pass … no mismatch") and the
  verifier moduledoc ("returns `:target_has_no_org_id` and passes"). **Decide which is correct** (the
  documented intent — *pass* — is right: an org-less target has no org to mismatch) and make code and
  docs agree: return the pass result from that arm, and add a test asserting a write whose FK targets
  an org-less row **succeeds** (with a positive control that a genuine cross-org mismatch still refuses).
  Latent today (all 39 call sites pass explicit org-scoped `relationships:` lists), but it breaks the
  documented bare-`change` default the scope-authoring guide §10 tells hosts to use.
- **D7 (LOW).** `Csv.compact/1` unwraps any struct via `Map.from_struct/1` (`csv.ex:291`), so a
  **nested** `%Samen.Masked{}` would serialize as `{"token":"vt_…",…}`, defeating the module's
  "NEVER a `vt_*` token" guarantee. One clause closes it: `defp compact(%Masked{} = m), do: m` (before
  the generic struct clause), plus a MaskingCase proof exercising a container-nested masked value.
  Unreachable today (no shipped resource nests a `%Masked{}` in a container attribute).

---

## 5 · The BATON batch sequence

Ordered fix→verify batches, house "one deliverable per agent, adversarial gate per phase" shape. Each
batch ends with: sabotages flip named tests + revert byte-exact, suites + every `ci.sh` green
before/after, a phase commit. **Schema** = regenerates `schema.dict` via the sanctioned task + runs the
FULL root gate. **Masking** = ships `MaskingCase` three-proofs + is checked by the OPUS masking verifier.

| # | Batch | Scope | Schema? | Masking? | Dependencies / notes |
|---|---|---|---|---|---|
| **E1** | **D2 + D7** — the two one-liners | `SameOrgFk` org-less arm passes (code=docs) + test; `Csv.compact(%Masked{})` clause + nested-masked MaskingCase proof | no | **yes** (D7) | Independent, lowest-risk; ships first to bank the quick correctness wins and warm the gate. |
| **E2** | **D5** — retention `org_id` binding | thread org into `:shred` `shred_opts`; `Spec` gains `org_field` (config, not DB); red-path: retention shred rides the tenant chain, not `__global__` | no | no | Depends on nothing. Mechanical. |
| **E3** | **D6** — DSAR org binding + grant check | org predicate on both walks; `grant?` via `Reveal.grant_checker/0` | **maybe** (only if `pii_vault` must be org-tagged — resolve the §4.5 unknown first) | no | Resolve the org-tagging unknown at batch start; if it forces a column, this becomes a schema batch. |
| **E4** | **D4 + T130** — `Storage.delete` chokepoint + ref-count | governed fail-honest delete path (audited, fail-closed) **and** clone `storage_key` ref-count / last-reference delete, **in one batch**; wire into File destroy + retention `:delete`/`:shred`; red-path both directions | **likely** (a ref-count column on File / a blob-ref table) | no | **HARD: D4 and T130 ship together — never one without the other** (delete makes T130 live). New capability — scope who may call delete. Adds a sabotage. |
| **E5** | **D1** — `email_bidx` erasure arm | **operator decision (§7) must land first**; then the derived-linkable arm (tombstone to random sentinel), scoped to principal-account erasure; ADR-035 §4.1 amendment; erasure red-path + anti-vacuity positive control | **likely no** (sentinel fits existing column; **confirm** — if a link column/index is added, this is a schema batch) | no | Blocked on §7 decision. The crypto-sensitive batch — verify the un-confirmability red path carefully. |
| **E6** | **D3** — `pii_declared` masking + bag-key erasure | mask-by-omission for `tnt_pii_declared` bag keys via the resolver reading `tnt_field`; per-key erasure arm; MaskingCase three-proof on ≥1 surface | no (reads `tnt_field`, no new column) | **yes** | Latent (framework-hardening). Can run in parallel with E4/E5 in principle, but land after E5 so the erasure-arm registry pattern is settled. |
| **E7** | **completeness verifier** (the unifying fix) | new gate enumerating out-of-envelope residues and asserting each has an erasure arm; non-empty-discovery floor; wired into `ci.sh` + both generator ci templates; sabotage | no | no | **Lands LAST** — it asserts the arms E1–E6 built. A registry/marker touch may be needed so discovery is exhaustive; that is code, not schema. |

Rationale for order: quick correctness wins first (E1–E2), then the mechanical framework-API fixes
(E3), then the new-capability batch that unblocks T130 (E4), then the crypto-decision batch (E5), then
the hardening + proof (E6), and finally the verifier (E7) that makes the whole class checkable — it
must come last because it asserts the arms the earlier batches register. E5 is gated on the §7 operator
decision and may be reordered after E6 if the decision is slow; nothing else depends on E5.

---

## 6 · The erasure-completeness verifier (the durable framework fix)

**One-paragraph design.** A new structural gate (`mix samen.verify.erasure_completeness`, the
`oban_queues`/`SameOrgFk` shape) that **discovers** every plaintext-or-linkable value living *outside
the per-subject-DEK envelope* and **asserts** an erasure arm reaches each — failing closed on empty
discovery (the non-vacuity floor `pii_classify` lacks). Discovery enumerates, from the live schema +
registries rather than from a grandfathering baseline: (a) **derived-linkable columns** — keyed-HMAC /
blind-index columns whose value is a function of PII, discovered by an explicit `derived_linkable`
registry marker (introduced with E5's `email_bidx` arm) so a new one *must* register; (b) **`pii_declared`-capable
bag columns** — any `public?: true :map` column that a `tnt_field` may mark `tnt_pii_declared: true`,
asserting both a masking arm and a bag-key erasure arm exist (E6); (c) **`storage_key` columns** —
asserting a `Storage.delete` erasure/retention arm reaches the referenced blob (E4); (d) the already-covered
`non_pii!` columns and DEK-keyed pseudonyms, asserted still-covered. For each discovered residue the gate
asserts a **registered arm keyed on subject_id** exists (redact / tombstone / delete), and the suite
carries a red-path per class proving a shredded subject's value in that class is actually gone plus a
positive control that a non-erased subject's value survives (anti-tautology). Non-vacuity is enforced
two ways: discovery must be **non-empty** (email_bidx + storage_key exist today, so an empty set is a
discovery bug and fails), and a **sabotage** that removes any one erasure arm must flip the named
assertion. This turns "the carve-out list is complete" from a moduledoc claim into a gated invariant:
a future out-of-envelope value cannot ship without either registering an arm or failing the gate.

The verifier deliberately does **not** consume `schema.dict.json` for its residue set — that baseline
grandfathers pre-existing columns, which is the exact mechanism that let `email_bidx` ship unerasable.
It discovers from the live schema + the arm registry, so "pre-existing" confers no exemption.

---

## 7 · Decisions for the operator

| # | Decision | Options | Recommendation |
|---|---|---|---|
| **1** | **D1 — how to make an erased subject's email un-confirmable** (amends **ADR-035 §4.1**) | (a) rotate/shred shared `k_bidx` · (b) re-key per subject on DEK · (c) **tombstone `email_bidx` to a random unique sentinel on principal-account erasure** · (d) per-subject shreddable derived key | **(c).** Only option that kills the equality oracle for the erased subject while preserving pre-auth lookup + global dedupe, with **no migration**. (a) is not per-subject; (b)/(d) break pre-auth lookup (circular — can't key on a subject you don't yet know) and dedupe. |
| **1a** | **D1 sub-decision — tombstone vs. destroy the Credential/Invitation row** | tombstone `email_bidx` in place · destroy the row | **Tombstone.** Kills the oracle and the login while preserving the row for FK/audit reference. |
| **1b** | **D1 sub-decision — what triggers the blind-index arm** (Credential is **org-less, one human N orgs**) | fire on any subject shred · fire **only** on principal-account erasure (subject == credential/invitation owner) | **Principal-account only.** A per-tenant data-subject shred must NOT tombstone a shared login credential — that would break the human's access to their *other* orgs. Load-bearing; belongs in the ADR-035 amendment. |
| **2** | **D4 — build `Storage.delete` now, given it makes T130 live** | build now (delete + ref-count in one batch, E4) · defer (T130 stays blocked-safe, blobs stay unerasable) | **Build now, together.** Erasure genuinely does not reach blobs today; the fix and T130's ref-count re-tokenization **must ship in one batch**. Deferring keeps a real (if latent) erasure gap open. |
| **3** | **D4 ref-count shape** | (i) last-reference delete / ref-count · (ii) re-tokenize clones to independent blobs at clone time | **(i).** Preserves clone's documented shallow re-link contract; localizes the change to the delete path. |
| **4** | **D3 masking approach** | mask-by-omission via resolver reading `tnt_field` · refuse `pii_declared: true` at the `define` chokepoint until routed | **Mask-by-omission.** Keeps the capability usable; refusal is the fallback if masking proves too invasive for one batch. Latent either way (no shipped `pii_declared` field). |

---

## 8 · Consequences

**Positive.** The design turns a five-item carve-out gap into six scoped, independently-gated batches
plus one durable verifier that makes the whole class checkable-by-construction — so the *next*
out-of-envelope value cannot ship unerasable. D1's real crypto tradeoff is laid out with a recommended
option and its two load-bearing sub-decisions (tombstone; principal-account scope) surfaced rather than
buried. The D3 reachability question is answered with evidence (latent), so the operator is not asked to
merge-gate a non-live leak. D4/T130's "ship together" constraint is restated as a hard batch boundary.

**Negative / accepted.** This ADR fixes nothing — it is a design + queue. Two batches carry genuine
unknowns the builder must resolve at batch start, named here rather than papered over: **E3/D6** — whether
`pii_vault` is org-taggable or the org must be caller-asserted (decides if D6 is a schema batch);
**E5/D1** — whether the sentinel-tombstone truly needs no schema change (expected none; confirm). E1's D7
clause and E2/D5 are latent (no live trigger), so their value is future-adopter safety, not a live-leak
close — stated plainly so urgency is not overclaimed. Blob **encryption-at-rest** is explicitly out of
scope; D4 makes erasure reach blobs by *deletion*, not by bringing them into the DEK envelope — a named
residual. And E5 depends on a human decision (§7), which is a real scheduling cost.

**Neutral.** Docs-only. No source, test, sabotage, registry, or `schema.dict.json` change in this ADR.
The ADR index (`docs/adr/README.md`) gains one row and its "46 ADRs total" line advances to 47 in the
same pass (the claim-evidence discipline that governs this repo governs its index).

## 9 · See also

- **ADR-045 §4.3** (`ADR-045-premerge-review-dispositions.md`) — the Phase-3 dispositions this ADR designs.
- **ADR-035 §4.1** (`ADR-035-identity-spine.md`) — the blind-index design D1 amends (decision §7).
- **ADR-001** (`001-key-hierarchy.md`) — the per-subject KMS envelope the "outside the DEK" framing rests on.
- **ADR-026** (`026-files-storage-adapter-fail-honest.md`) — the fail-honest contract `Storage.delete` obeys.
- **ADR-002** (`002-worm-anchor.md`) — the T4.3 tenant chain D5's `org_id` binding rides.
- **ADR-036 D6 / T3.8** (`ADR-036-rich-types.md`) — the `pii_declared` containment rule D3 hardens.
- `_orch/luminary-premerge/panel-3-data-privacy.md` (gitignored) — the panel evidence every D-ID traces to.
- `samen_core/lib/samen/erasure.ex` (the carve-out moduledoc), `auth/blind_index.ex`, `kms.ex` (`sys:bidx`
  refusal), `vault.ex:276` (the DEK-keyed pseudonym pattern D1 cannot reuse), `files/storage.ex` +
  `clone.ex` (D4/T130), `retention.ex:253` (D5), `dsar.ex` (D6).
