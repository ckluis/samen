# Runbook — Breach notification

**Scope:** what to do when a suspected or confirmed unauthorized access/disclosure event needs to
be scoped, assessed, and (if required) reported. This runbook covers the **operational** steps —
containment, scoping via the audit trail, and remediation. It does **not** make the legal
determination of whether a notification obligation is triggered; see §4.

Code touched: `Samen.AuditChain`, `Samen.AuditChain.TenantView`, `Samen.Erasure`,
`Samen.Web.Settings.ApiKeys`, `Samen.BreakGlass`. The scope-enumeration helper
(`Samen.Dsar.affected_subjects/2`, referenced in §2) is **being added in F3** — if it is not yet
present in this checkout, fall back to the manual chain-read described in §2b.

---

## 1. Contain

Stop the ongoing exposure before scoping it — a breach that is still open makes every subsequent
step's numbers wrong.

- **Compromised credential (API key):** revoke it immediately via
  `Samen.Web.Settings.ApiKeys.revoke/3` (sets `revoked_at`; the deny-on-read query and
  `ApiKeyScope.authorized?/5` refuse it from that point). Do this BEFORE scoping — every minute a
  live key stays active widens the exposure window you are about to measure.
- **Compromised operator credential:** suspend the operator
  (`Samen.OperatorPlane.Suspension` — the same mechanism the break-glass breadth-budget
  auto-trip uses, `docs/runbooks/break-glass.md` §7) so every reveal path (routine reveal,
  impersonation, break-glass) denies for that operator immediately.
- **Compromised infrastructure (DB credential, host access):** rotate the credential/secret at
  its source (Postgres role password, Fly/host access token, etc. — outside Samen's code; follow
  your infra provider's rotation procedure).
- **Ongoing impersonation/reveal session:** if a live session or grant is the vector, the
  containment step is closing it — there is no separate "kill switch" beyond revoking the
  credential/role that opened it.

Record `t_contained` — the wall-clock containment completed. Everything from here scopes the
window `(t_exposure_start, t_contained]`.

## 2. Determine scope

The audit chain (ADR-002) is the evidence source: a per-org, hash-chained, tamper-evident,
append-only log of every reveal/impersonation/erasure event, sealed to a WORM anchor on a cron
(`docs/runbooks/pitr-gameday.md`'s sibling anchor mechanism). Use it to answer "who was touched,
by whom, when" — not guesswork.

### 2a. Preferred — `Samen.Dsar.affected_subjects/2` (F3, being added)

```elixir
Samen.Dsar.affected_subjects(org_id, window: {t_exposure_start, t_contained})
# => {:ok, [subject_id, ...]}
```

This enumerates every distinct `subject_id` touched by an audit-chain event in the window, for
the org(s) in scope. It is a read over `Samen.AuditChain` — it does not itself prove anything the
chain doesn't already carry; it exists to make "enumerate the affected subjects" a single call
instead of a hand-rolled query each time. If this module is not yet present in your checkout
(it lands in F3), use §2b.

### 2b. Manual chain read (works today)

1. Pull the org's chain: `Samen.AuditChain.TenantView.for_org(org_id)` returns the chain entries
   plus a `verify_chain` and `verify_against_anchor` status. **Check the verification status
   first** — if `verify_chain` or `verify_against_anchor` fails, the chain itself may have been
   tampered with (see `docs/runbooks/break-glass.md` §6 for what a tamper failure means and how
   to handle it); do not trust an unverified chain's contents for scoping.
2. Filter entries to `occurred_at` within `(t_exposure_start, t_contained]`.
3. Collect the distinct `subject_id` values across those entries — that is your affected-subject
   set.
4. Cross-reference `event_type` and `actor_id` on each entry to identify which actor(s) touched
   which subjects, and whether the events are `reveal` / `impersonation` / `erasure` / other.

### 2c. What the chain can and cannot tell you

- It tells you **which subjects had a reveal/impersonation/erasure event in the window**, by
  which actor. That is the authoritative "who was touched" answer for anything that went through
  a governed vault action.
- It does **not** by itself tell you whether the actor's access was *authorized* — that is a
  judgment call combining the chain's actor/event data with your own knowledge of the incident
  (was this actor's credential the one that was compromised? was this within their normal scope
  of work?).
- It does not cover access that bypassed the governed chokepoints entirely (e.g. direct DB access
  by someone with infra-level credentials, outside any Samen actor). If the incident involves
  infra-level access, the audit chain scopes the *application-layer* exposure; the infra
  provider's own access logs scope the rest.

## 3. Assess: was vaulted PII exposed, or only tokens?

This distinction changes the severity of the incident materially, so make it explicit before
moving to notification:

- **Tokens/ciphertext only exposed** (e.g. an attacker read rows containing `vt_*` vault tokens,
  or vault ciphertext, without a working reveal path) — **not a PII breach**. A `vt_*` token or
  raw ciphertext is useless without going through `Samen.Vault.reveal/3` on the correct plane with
  a grant/break-glass authorization; possession of the token/ciphertext alone does not disclose
  the underlying value. The vault stays crypto-shreddable regardless — if you want to close the
  exposure permanently for the affected subjects, `Samen.Erasure.shred/2` remains available (see
  §5).
- **Plaintext PII actually resolved** — this happened if the audit chain shows `reveal` or
  `impersonation` events in the window against subjects whose plaintext the actor should not have
  had, OR if there is evidence of decryption outside the governed path (e.g. KMS access logs
  showing unusual `Decrypt` calls against the subject's DEK, outside any Samen-recorded reveal).
  This is a genuine PII exposure for the affected subjects.
- **Operator-authored free text** (impersonation/reveal reasons, audit `detail`) — this is
  plaintext by design (ADR-002 §2.5, `Samen.PiiReasonScan`) and is readable by anyone with chain
  read access on that org. If the incident is "an attacker read the audit chain itself," check
  whether any `detail` field was written in violation of the "reasons name the ticket, not the
  person" convention — see `docs/free-text-pii-residue.md` for the full treatment of this
  channel. This is a separate, narrower exposure surface than the vault.

Write down which case applies, and for which subjects — this is the fact pattern counsel needs.

## 4. Notification obligations

**Samen provides the evidence trail; it does not make the legal determination.** The chain gives
you a defensible, tamper-evident answer to "what happened, to whom, when" — that is the input to
a legal/compliance decision, not the decision itself.

General landscape (non-exhaustive, consult counsel before acting on it):

- **GDPR** (if any affected subject or the controller is in EU scope): Article 33 requires
  notifying the supervisory authority "without undue delay and, where feasible, not later than 72
  hours" after becoming aware of a breach, for breaches likely to result in a risk to
  individuals' rights and freedoms. Article 34 may require notifying the affected individuals
  directly for high-risk breaches.
- **US state laws:** notification triggers and timelines vary by state (and by the type of data
  exposed — many statutes define "personal information" narrowly, e.g. SSN/financial/health data
  combined with a name, and may not trigger on other PII types). There is no single US federal
  standard; the applicable law depends on the residency of the affected subjects.
- **Sector-specific obligations** (HIPAA, GLBA, etc.) may apply depending on the tenant's
  industry and the data types involved — this is tenant/deployment-specific and outside what
  Samen's code can determine.

**What to hand counsel:** the scoped subject list (§2), the exposure window
(`t_exposure_start`–`t_contained`), the token-vs-plaintext assessment (§3), and the chain's
verification status (§2b step 1) as evidence the record has not been tampered with. Counsel
determines which jurisdictions' clocks started, when, and what the notification content and
timeline must be. **Do not notify, or decide not to notify, based on this runbook alone.**

## 5. Remediation

- **Rotate keys.** Any credential implicated in the incident (API keys via
  `Samen.Web.Settings.ApiKeys.revoke/3`, operator credentials, infra secrets) gets rotated, not
  just the one that triggered containment — assume the blast radius is at least as wide as what
  §2 found until proven otherwise.
- **Revoke API keys via the bounded-expiry/last_used surfaces.** `Samen.Web.Settings.ApiKeys.list/2`
  surfaces `last_used_at`, `expires_at`, and `revoked?` per key — use it to find every key that
  was active during the exposure window (not just the one you already suspect) and revoke any
  that shouldn't still be live. A key's bounded expiry (`ApiKeyScope.bounded_expiry/2`, F3.4)
  means an unrotated key ages out on its own, but do not rely on expiry alone during an active
  incident — revoke explicitly.
- **Break-glass review.** If any break-glass reveals occurred in the window (they are logged to
  the local hash chain and reconciled into the central chain — `docs/runbooks/break-glass.md`),
  review each one's `reason` against the incident: was it a legitimate emergency response, or
  part of the incident itself? Check `Samen.BreakGlass.Reconciliation` output for the window.
- **Consider erasure for affected subjects** if the exposure is severe enough that the subjects
  (or counsel) want the underlying data made permanently unrecoverable going forward:
  `Samen.Erasure.shred/2` — this does not undo the exposure that already happened, but it closes
  the door on any further exposure of the same vaulted values (crypto-shred makes every copy,
  including anything an attacker already exfiltrated as ciphertext, permanently undecryptable).
- **Post-incident:** file the drill/incident evidence (scope, timeline, root cause, what
  contained it) the same way `docs/runbooks/pitr-gameday.md` §G treats drill evidence — a written
  record, not tribal knowledge.

## 6. What samen provides vs. does not

| Samen provides | Samen does not provide |
|---|---|
| A tamper-evident, per-org audit trail of every reveal/impersonation/erasure event (`Samen.AuditChain`) | A legal determination of whether notification is required |
| A scoped, verifiable "who was touched, when, by whom" answer (§2) | Jurisdiction-specific timelines or notification content |
| A clear token-vs-plaintext exposure distinction (§3) | Detection of exposure that bypassed the governed chokepoints entirely (infra-level access) |
| Credential revocation and crypto-shred remediation levers (§5) | Legal counsel, PR/communications guidance, or regulator liaison |

Consult counsel. Samen gives counsel a defensible fact pattern; it does not replace them.
