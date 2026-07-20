# Free-text third-party PII residue

**One-line summary:** two categories of plaintext freeform text exist outside the vault's
crypto-shred guarantee — operator-authored reason/detail fields, and tenant freeform content
columns — and both are defended by a value-shape scan plus human convention, not by proof. This
is a documented, bounded residue, not a solved problem.

Code: `Samen.PiiReasonScan`, `Samen.PiiValueShape`, `Samen.Cdc.Projection` (ADR-015),
`Samen.NonPii`. ADRs: ADR-002 §2.5 (operator reason/detail), ADR-015 (tenant freeform columns in
the CDC/aggregate plane).

---

## Where freeform plaintext can live

Samen's PII model has one strong guarantee: anything routed through a `pii_attribute` (a vaulted
column) is crypto-shreddable — `Samen.Erasure.shred/2` destroys the subject's key and every
vaulted copy, everywhere, becomes undecryptable at once. That guarantee is scoped to the vault.
Two channels sit **outside** it, both storing plaintext by design:

1. **Operator-authored reason/detail channels.** Impersonation-session `reason`s, reveal-request
   `reason`s, and audit-chain/audit-event `detail` strings
   (`imp_impersonation_session`, `rvr_reveal_request`, `aud_event.aud_detail`, and the
   hash-committed `aud_chain` payload). An operator types free text explaining *why* they are
   revealing or impersonating; that text is metadata about the *action*, not a vaulted subject
   attribute, so it is stored plaintext.
2. **Tenant freeform/notes columns.** Any tenant-authored `:string`/`:text`/`:map`/`:jsonb` column
   that is not vault-routed — e.g. a benignly-named `drv_notes` field, a dispatcher comment, a
   free-text ticket body. These are ordinary application content, not PII by declared intent, but
   nothing stops a tenant from typing a third party's name, phone number, or email into one.

## Why it is not crypto-shreddable

Crypto-shred works by destroying a per-subject DEK (ADR-001) — every value encrypted under that
key becomes unrecoverable. It has nothing to reach if the value was never encrypted under a
subject's key in the first place. Both channels above are ordinary plaintext columns:

- The reason/detail channel is *deliberately* plaintext and *deliberately* preserved through a
  shred — the audit chain's hash commits to `detail` (ADR-002 §2.3), so if a shred rewrote it,
  chain verification would break. Immutability wins on this field by design: "the record that an
  event happened is preserved" is the whole point of the chain, and `detail` is part of that
  record. `Samen.AuditChain`'s moduledoc states this explicitly, as does
  `Samen.PiiReasonScan`'s.
- The tenant freeform-column channel is plaintext because it was never classified as PII at all —
  it is ordinary content the tenant owns. A subject named inside someone else's freeform note
  is a *third-party* PII problem: the note's "owner" (the tenant record it belongs to) isn't
  necessarily the person named inside the text, so there is no single subject DEK the column
  could even be routed under without a redesign of what "subject" means for that field.

In both cases, a subject erasure request does not — and structurally cannot — reach text that was
never subject-keyed plaintext in the vault sense.

## Controls

Neither channel is left undefended; both get a fail-closed belt plus a documented convention,
with different maturity:

### Operator reason/detail — `Samen.PiiReasonScan` (shipped)

- **Fail-closed belt at write.** `Samen.PiiReasonScan.check/2` runs
  `Samen.PiiValueShape.classify_value/1` (email / SSN / phone shapes only — the space-separated
  name shape is deliberately excluded, since ordinary reasons have internal spaces and would
  false-positive constantly) against the whole reason/detail string. A reason that is *itself* a
  bare email/SSN/phone value is **rejected** before any row lands
  (`{:error, {:pii_shaped_reason, shape}}`), at the three write boundaries:
  `Sessions.open/1` (impersonation), `Grants.request/1` (reveal), and
  `AuditChain.Writer.write/2` (the chain append itself).
- **Human convention (load-bearing).** "Reasons name the ticket/dispute, not the person." This is
  the primary control — the scan only catches the narrow case of a reason that *is* a bare
  PII-shaped value. A sentence that mentions a name in prose ("called re: Jane's account") is not
  shape-matched and passes the scan; the convention is what's supposed to stop that case from
  being written in the first place.

### Tenant freeform columns — `Samen.Cdc.Projection` default-deny (shipped, for the CDC/aggregate
plane) + a runtime scan (being extended in F3)

- **Default-deny for CDC/aggregate mirroring (ADR-015, shipped).** A freeform column
  (`:string`/`:ci_string`/`:text`/`:map`/`:jsonb`) is classified `:plaintext_pii` and **excluded**
  from the analytics/aggregate projection unless it is vault-routed OR explicitly two-reviewer
  cleared via `Samen.NonPii.register/1`. This closes the *silent-leak-to-analytics* mode
  specifically: a benignly named column no longer reaches ClickHouse/the aggregate plane just
  because nobody thought to flag it. It does **not** stop the column from existing, plaintext, in
  the primary Postgres table the tenant already owns — ADR-015 governs the CDC/aggregate mirror,
  not the live OLTP row.
- **Runtime value-shape scan on tenant free-text (F3, being extended).** The same
  `Samen.PiiValueShape`/`PiiReasonScan` machinery that guards operator reasons is being extended
  to run at the write boundary of tenant freeform fields, as a belt-and-suspenders check atop
  ADR-015's compile-time default-deny (ADR-015 §5 names this as the deferred WS-C item). Where
  this lands in F3, it catches the same narrow case as the operator scan: a freeform value that is
  *itself* a bare email/SSN/phone shape gets rejected or flagged at write time. It is the same
  heuristic with the same blind spot (see below).

## Residual risk

Both controls are **heuristics, not taint proofs**, and the gap they leave is the same shape in
both channels:

- **A shape scan only catches values that look like a whole email/SSN/phone.** A benignly named
  freeform column (`drv_notes`, a comment field, a ticket body) can hold a sentence that mentions
  a third party's name, or a phone number embedded in prose with surrounding text, or any PII that
  isn't itself a bare matched value — none of which the scan flags. This is the same shape as the
  documented ADR-015 gap (H-2 / roadmap G3): "a freeform column with no seed PII value and a
  non-suspicious name produces empty reasons → not flagged" — the runtime scan narrows this gap
  (it now inspects actual written values, not just column names) but does not close it, because
  prose-embedded PII does not match a value-shape regex.
- **Names are not gated at all.** Both scans deliberately exclude the space-separated-name shape,
  because ordinary text has spaces and the false-positive rate would make the control unusable.
  A name typed into either channel is invisible to the mechanism; only the human
  convention/process stands between a name and the plaintext channel.
- **This is a third-party problem, which makes "the subject" ambiguous.** Even where a control
  could theoretically catch a PII-shaped value in a tenant note, there is no single subject DEK to
  route it under — the note's owner (the record it's attached to) is not necessarily the PII
  subject named inside it. Closing this gap for real would require either (a) NLP-grade PII
  detection with a materially higher false-positive/negative tradeoff than a shape regex, or (b) a
  product decision to disallow free text in favor of structured fields wherever a third party
  might be named — neither is in scope today.

## Honest summary

This is a **documented, bounded residue**, defended in depth (default-deny mirroring +
write-time shape scan + human convention) but not eliminated. A benignly named freeform column,
or an operator reason written in prose, can carry third-party PII that no shipped mechanism will
catch. The mitigation is process (train operators/tenants on the convention) and monitoring (the
scans' `Logger.warning`/reject events are the observable signal that someone tried to write a
shape-matched value), not a claim that the gap is closed. Treat any freeform text field as
untrusted for the crypto-shred guarantee, regardless of what its column name implies.
