# ADR-048 — Context compaction inside the ADR-046 erasure envelope: a dual-view transcript, a re-scrubbed summary, three-level overflow recovery, and withdrawal propagation on shred

- **Status:** **PROPOSED** (2026-08-26) — **draft only.** Nothing here is ratified; every ruling
  in §10 is **OPEN (needs-operator-input)**. The operator ratifies or amends, per the ADR-046 §7 /
  ADR-047 §9 convention.
- **Date:** 2026-08-26
- **Build status:** **NOT STARTED — no code exists and none is authored here.** This ADR authors
  no product code: it touches no source, no test, no sabotage, no migration, no mix task, no
  abbrev-registry row, no `schema.dict.json`. It is docs-only per the standing
  decompose-cross-cutting-changes rule. The build, if ratified, lands in the batches §9 sequences,
  each behind its own adversarial gate. Code fragments below are **illustrative shapes, not
  shipped modules** — no module named in §4–§7 exists today.
- **Task:** ADR-047's loop has **no compaction story at all.** `context_cutoff`, `token_budget`,
  `context.window` and `overflow_recover` return **zero hits** across `samen_core/lib` and
  `samen_web/lib` (re-checked at `c41e169`; all 30 `compact` hits are CSV/UI helpers), nothing
  truncates or summarizes the loop's `:history`, and budget exhaustion is **terminal** — the last
  assistant turn is never promoted (`Samen.AI.Agent`, the `{:error, :budget_exhausted, run}`
  arm). `Samen.AI.Agent`'s own moduledoc says it plainly: *"performs no transcript compaction in
  v1."* ADR-047 §11's residual list names **no** compaction residual, and ADR-046 has **no
  derived-artifact rule**. Design the contract that closes all four halves of that hole at once —
  because a compactor built without the erasure half would create exactly the out-of-envelope
  residue ADR-046 exists to make impossible.
- **Deciders:** the operator, for the six decisions in **§10** and the open questions in **§11**.
  The two genuine tradeoffs are (a) whether a **model-written summary** may re-enter a governed
  transcript at all, and (b) whether a derived artifact inherits a **withdrawal** structurally
  (containment) or by propagation (a walk) — this ADR rules **both**, and recommends containment
  first with propagation only for what containment provably cannot reach.
- **Consumes (binding inputs):**
  - **ADR-046** — erasure completeness (in force, 2026-08-13; build COMPLETE E1–E8). Its §1
    framing is the spine of §7 here: a residue is *a plaintext-or-linkable value living outside
    the per-subject-DEK envelope*; the pattern that **works** is the trace-sink pseudonym
    (`HMAC(psk_S, subject_id)` keyed off the subject's **own** DEK, so `shred` unlinks it for
    free); the pattern that **fails** is `email_bidx` (keyed off a shared, deliberately
    un-shreddable subject). Its §6 completeness verifier and §7#5 open decision (the
    *about-a-subject* boundary) both bind.
  - **ADR-047** — the AI agent loop (ratified 2026-08-17; A1–A7 shipped). §4.3's six numbered
    scrub points, §4.4's categorical exclusion of grant plaintext from agent runs, §6's
    fail-honest budgets and the **non-configurable** floor (§9#3), §7.4's transcript erasure
    arm, §9#2 masked-only runs, §9#4 the 90-day transcript retention, and §11's consequence list.
    **This ADR amends none of them.** Where it looks like it might, §6 and §7 say exactly why it
    does not.
  - **ADR-043 §3.1 / §6.1 / §7.2** — INV-7, the EG2 class, the chokepoint pipeline and the
    per-turn `:history` re-scrub (§3.2a, `Samen.AI.Chokepoint.rescrub_history/2`), and the M3
    ruling that **grants categorically never unlock embedding** because *vectors outlive grants
    and defeat crypto-shred* — the sentence §7 D1 generalizes to every derived artifact.
  - **ADR-047 §4.3a / §4.3b / §5.1a and §10a rows 25–28** — the four seams landed this session
    (T181–T184), described in §3 as **existing substrate**, not as work.
  - **ADR-014 / ADR-024 / ADR-026** — the fail-honest adapter contract. A run that did not finish
    must not return a value that looks like it did. §6 restates this floor verbatim rather than
    paraphrasing it, because §6 is the section most likely to be misread as softening it.
- **Sources (OSS scan, `findings/001+005+006+016+034+038+047`).** Patterns only; every mechanism
  below is a native re-implementation:
  Ankole (Apache-2.0) — withdrawal propagation into derived artifacts, citation-required blocks;
  OSA (Apache-2.0) — the staged compaction pipeline and 413-recovery collapse;
  Pepe (MIT) — the context-watermark trigger and the micro-compaction/prompt-cache tradeoff;
  Alloy (MIT) — the hook chain (already shipped, T181);
  Condukt (MIT) — the registry/redaction lanes (already shipped, T183/T184);
  Sagents (Apache-2.0) — the dual-view AgentState-vs-DisplayMessage transcript shape;
  **Neoharness (UNLICENSED)** — the three-level overflow ladder, taken **clean-room from the
  finding's prose only**; no line of its code was read, translated, or adapted.
- **Binds (implementing batches):** C1–C4 (§9), **none filed** — the batches are recorded design,
  not backlog rows, and are filed only if and when the operator ratifies.

---

## 1 · Context — what exists, what is absent, and why the absence is not benign

**What exists.** The loop persists exactly **one** artifact: the run row's vault-routed
`:transcript`, a JSON `{"goal": _, "lines": [...]}` sealed inside the per-run DEK envelope keyed
on the run's **own id** (the `Samen.Identity.Totp` precedent), revealed at every turn boundary
through the one decrypt chokepoint and threaded as `:history` into `Samen.AI.complete/4`, so
§3.2a's re-scrub plus the step-4 `vt_` scan and `safe_segment?/1` run over **every prior line on
every turn**. A shredded or unavailable transcript is a fail-honest terminal
(`:transcript_unavailable`) — *an erased run can never keep executing on cached text*. The
transcript carries a default 90-day `:shred` retention spec (§9#4), and ADR-047 §10a row 2 records
that the E7 completeness gate grew a **transcript arm**, so the envelope is gated, not asserted.

**What this session added (substrate, already shipped).** `Samen.AI.Agent.Hook`'s seven-point
ordered chain, **including `:after_compaction`, declared and dispatchable with no call site
because v1 ships no compactor** (T181, §10a row 25); `Samen.AI.Agent.Ingress.sanitize/1`, the
chokepoint's INGRESS direction (T182, §4.3a); `Samen.AI.ToolSurface`, the closed four-surface
registry (T183, §5.1a); `Samen.AI.Agent.Secrets.redact/1`, the secrets lane distinct from `pii_*`
(T184, §4.3b). §4–§7 below consume all four and add **no fifth seam**.

**What is absent.** Everything about context management:

| absent thing | evidence at `c41e169` |
|---|---|
| any context-window accounting | `context_cutoff` / `token_budget` / `context.window` / `overflow_recover`: **0 files** in `samen_core/lib` + `samen_web/lib` |
| any transcript compactor | 30 `compact` hits, all CSV/UI helpers; `Samen.AI.Agent`'s moduledoc: *"performs no transcript compaction in v1"* |
| any overflow recovery | a provider "prompt too long" normalizes to the content-free `:provider_error`; there is no retry, no fold, no distinct terminal |
| any derived-artifact erasure rule | ADR-046 §6's four discovery classes are columns and blobs; a *derived summary* is not among them |
| any UI/LLM view separation | one `:transcript`, read by both the loop and `Samen.Web.AI.AgentLive` |

**Why the absence is not benign, stated honestly.** Today the loop is safe *because* it cannot
compact: 8 turns × 60k input tokens with masked-only content rarely overflows, and when it does,
it fails closed. So this is a **runway** problem, not a live defect — and the honest framing
matters, because it is what makes a staged answer (§11 O-1) legitimate. But the moment anyone
adds a compactor, four things go wrong **at once**, and each of them is a governance regression
rather than a bug:

1. Compaction rewrites `lines` — the same bytes the tenant saw. The audit trail becomes a lie.
2. A summary is **new model-written text about masked content**. If it re-enters `:history`
   without the §4.3/§4.3a/§4.3b treatment, compaction becomes a **laundering channel** that
   re-admits precisely the injected instructions and incidental secrets T182 and T184 just closed.
3. A summary is a **derived artifact**. Put it anywhere but the run's own DEK envelope — a memo
   table, a fact store, an embedding — and it is an out-of-envelope residue of exactly the
   `email_bidx` species: derived from PII-adjacent text, outliving the key destruction meant to
   reach it. ADR-043 M3 already ruled this for vectors; nobody has generalized it.
4. Overflow recovery is the single most tempting place in the codebase to promote a partial
   answer, because "we ran out of room, here's what we had" *feels* helpful. §9#3's floor says no,
   and says it non-configurably.

Those four are the four halves of one contract, which is why they are one ADR and not four.

---

## 2 · Decision drivers

1. **The erasure envelope is the constraint, not a checkbox.** Any compaction artifact that
   escapes the per-run DEK envelope is a new residue, and ADR-046's whole thesis is that the
   *next* such value must not be able to ship. Compaction must be designed inside-out from that.
2. **The fail-honest floor is non-configurable** (§9#3). Recovery may buy runway; it may never
   buy a partial answer.
3. **No fifth seam.** T181–T184 landed four; the T181→T184 ordering exists specifically to
   prevent seam proliferation. Compaction extends the declared `:after_compaction` point and the
   two shipped `ToolResult` content-transform clauses. It adds no new dispatch point.
4. **Determinism where the replay needs it.** The loop is at-least-once, never exactly-once: the
   provider call between checkpoints can genuinely repeat, the turn row does not. A compactor that
   re-summarizes on replay would make the *history itself* non-replayable, which is worse than
   re-charging tokens.
5. **Neutralize, never drop; name, never hide.** T182's discipline. A withdrawn span becomes a
   visible marker, not a silent gap.
6. **Two ADRs must stay unamended.** ADR-046's arms and ADR-047's §4/§6/§9 rulings are shipped and
   gated. Where this design pushes on them, it either fits inside them or names an open question —
   it does not improvise around them.

---

## 3 · Decision (summary)

Five rulings, each detailed in its own section:

- **R1 — Split the transcript into two views over ONE shred unit** (§4). An LLM-facing view that
  compaction may rewrite, and an append-only UI-facing view that it may not, both sealed under the
  **same** per-run DEK. The split is about **rewritability, never about privilege**: both views are
  masked identically, and neither ever holds a `{:grant_span, …}`.
- **R2 — A summary is untrusted content and re-enters through the full ingress path** (§5). The
  summarization call is an ordinary governed `complete/4` egress; its **output** is treated exactly
  like a tool result — `Secrets.redact/1`, then `Ingress.sanitize/1`, then §4.3's render rules,
  then §3.2a on every subsequent turn. Compaction must not be a scrub-laundering channel.
- **R3 — Three levels of overflow recovery, terminating in a NEW honest terminal** (§6): pre-turn
  deterministic fold, one mid-turn fold-and-retry, then `:context_exhausted` — distinct from
  `:budget_exhausted` so "we ran out of room" is legible from "we ran out of allowance". **No
  partial answer is promoted at any level.**
- **R4 — Containment first: every compaction artifact lives inside the run's own DEK envelope**
  (§7 D1), which makes run-shred withdrawal free. Compaction output is **categorically ineligible**
  for embedding and for any cross-run memory store.
- **R5 — Propagation for what containment cannot reach** (§7 D2): a token-only, **pseudonym-keyed**
  provenance index outside the sealed body, a withdrawal walk registered as an ADR-046 erasure arm
  with its own completeness-gate discovery class, and a fail-honest `:source_withdrawn` terminal
  for a live run whose folded source has been withdrawn — the `:transcript_unavailable` precedent
  applied one level down.

---

## 4 · Dual-view transcript — the LLM-facing view and the UI-facing view

**The problem, precisely.** The loop's `:history` source and the tenant's rendered record are the
*same bytes*. `Samen.Web.AI.AgentLive` re-reads the run row on every navigation and action (there
is no PubSub push — §10a row 15). So a compactor that folds turns 1–4 into one summary line does
not merely shrink the prompt: it **deletes what the tenant was shown**. That is not a UX
regression, it is an audit-integrity regression, and it is the reason no compactor can be bolted
onto the current shape.

**The ruling.** The transcript becomes two ordered views over one shred unit:

```
%{ "goal"     => _,
   "llm_view" => [seg, ...],   # the working set the loop threads as :history — COMPACTABLE
   "ui_view"  => [seg, ...],   # the rendered record the tenant saw — APPEND-ONLY
   "folds"    => [fold, ...] } # the compaction ledger (see §5, §7)
```

Non-negotiables, each an assertion site:

1. **One DEK, one shred unit.** Both views stay fields of the same JSON blob sealed under the run's
   own DEK, on the run row, under the run's own 90-day `:shred` spec. They are deliberately **not**
   two tables with two retention specs: splitting the views must not multiply shred units, or §7.4's
   erasure arm and the E7 transcript arm would each need a second target. ADR-046's discovery
   classes are therefore **unchanged by R1** — a property this ADR claims because the envelope is
   literally the same one, not because it was re-audited.
2. **Equal masking.** Both views hold the §4.3-rendered masked binaries. The UI view is **not** a
   privileged view; it sees exactly what the model sees. This is the one place the Sagents source
   pattern is most likely to be misread — there, the display record exists partly because raw
   history is unfit for humans. Here, agent runs are **masked-only on every plane** (§9#2), so the
   split buys rewritability and nothing else. Any future proposal to widen the UI view is a §9#2
   amendment and belongs in its own ADR.
3. **The UI view is never a `:history` source.** The loop threads `llm_view` and only `llm_view`.
   If the UI view could re-enter, compaction would be defeated on the next turn and the fold ledger
   would describe a history the model never saw.
4. **Compaction is append-and-mark, not delete.** Folding turns 1–4 appends a summary segment to
   `llm_view` and replaces the folded segments with a single bounded marker
   `[folded: turns 1–4 → fold #1]`; `ui_view` gains one appended line saying a fold happened, and
   loses nothing. A reader of the UI view can always answer *"what did this run actually say?"*
5. **Every segment is addressable.** Segments carry a stable `{run_id, seq}` id and a content
   digest. §7's withdrawal walk needs an address, and the *only-still-matching* rule needs a digest.

**Migration note (design, not code).** The shipped shape is `{"goal", "lines"}`. The honest
migration is a **reader-side** one: `lines` is read as `ui_view` **and** `llm_view` when the new
keys are absent, so an in-flight run written before the change keeps executing. No backfill, no
migration of sealed bytes — the envelope is opaque to the migration by construction, which is a
consequence of vault-routing worth stating out loud.

---

## 5 · Chokepoint re-scrub of summaries — compaction is not a laundering channel

The §3.2a per-turn history re-scrub already ships (`Samen.AI.Chokepoint.rescrub_history/2`) and is
**the substrate to extend, not to duplicate**. What it does today with a summary segment is
correct-but-incidental: an untagged segment takes the `other -> other` branch and is then `vt_`
scanned by step 4, with `safe_segment?/1` as the fail-closed last line. That is necessary and
**not sufficient**, because it governs the summary's *re-entry* and says nothing about its *birth*.

**The ruling — a summary is born as untrusted content and is treated exactly like a tool result.**
Six points, each an assertion site, mirroring §4.3's numbering deliberately:

1. **The summarization call is an ordinary governed egress.** It is a `Samen.AI.complete/4` through
   `seal/3` with the *same* `egress_opts/3` `Keyword.take/2` allowlist and `grant_egress?: false`
   pinned last (§4.4). No new provider face, no second chokepoint entry, nothing added to the
   allowlist. Its input is already-masked history, so **no new egress class opens** — the bytes
   going out are bytes that already went out on a prior turn.
2. **The summarizer prompt is a compile-time literal, EG5 `vt_`-free** — the A6 ruling for the
   driftwood goal prompt applied verbatim (§10a row 20), **not** a tenant-authored
   `Samen.AI.Prompt` row. A tenant must not be able to author the instruction that decides what
   gets carried forward, or "summarize by quoting every masked field verbatim" becomes a tenant
   capability.
3. **The returned summary runs the full INGRESS path before it touches the transcript**:
   `Samen.AI.Agent.Secrets.redact/1` **then** `Samen.AI.Agent.Ingress.sanitize/1` — that order,
   for T184's stated reason (ingress noise inserted between an unrecognized secret's label and its
   value cannot defeat vendor-prefix detection, which is internal to the token) — then §4.3#2's
   render semantics, and the segment is appended to `llm_view` as an ordinary **untagged** binary.
   **This is the central property of §5.** A model asked to summarize attacker-influenced tool
   output will happily reproduce an injected instruction or an incidental API key in its own
   words. A summary that skipped ingress would re-admit, under the loop's own signature, exactly
   what T182 and T184 close at the tool boundary.
4. **Re-entry is unchanged and unspecial.** On every subsequent turn the summary is re-scrubbed by
   §3.2a like any other segment and `vt_` scanned by step 4. The property *"the transcript at rest
   contains no vault plaintext and no `vt_*` token"* (§4.3#3) is therefore **asserted for summary
   segments directly**, not inherited by argument.
5. **Fail-closed, and the failure is not silent.** If the summarization completion refuses
   (`:pii_egress_refused`), or the summary fails `safe_segment?/1`, or ingress collapses it to
   nothing, **the fold does not happen**. The run continues *uncompacted* and, if it then cannot
   fit, takes §6 level 3. It never partially folds, never drops the offending span and keeps the
   rest, and never silently proceeds with a shorter history than the ledger claims. One new bounded
   `@error_kind`: `:compaction_refused`.
6. **`:after_compaction` finally gets its caller — and only after all of the above.** T181 declared
   the point with no call site precisely so that this design would extend the existing chain
   instead of adding a fifth seam. It fires **after** the summary has passed §5#3 and been appended,
   never before, so a hook can observe only governed bytes. The point stays **narrowing-only**: it
   accepts `:block` (skip this fold; the run continues under §5#5's uncompacted path) and `:halt`
   (a real terminal), and — a deliberate divergence worth stating — **it must not accept
   `{:edit, _}`**, because an edit here would be a host rewriting governed transcript text after
   the scrub, which is the one thing the ingress path exists to prevent. A hook that raises fails
   the fold closed (`:hook_error`), never runs it unhooked.

**Consequence for prompt caching, named.** Folding rewrites the prefix of `llm_view`, which
invalidates provider prompt-cache reuse for that run from the fold point forward — the tradeoff the
Pepe finding documents between whole-fold and per-turn micro-compaction. This design chooses
**whole-fold** (fewer, larger, ledgered events) over micro-compaction (steady cost, cache-hostile,
and — decisively here — one provenance edge *per turn per source*, which makes §7's walk large and
its non-vacuity floor weak). Named as a cost, not hidden; carried to §11 O-5.

---

## 6 · Three-level overflow recovery — and the fail-honest floor it may not touch

Today: budget exhaustion is a terminal `:budget_exhausted`, the last assistant turn is **never**
promoted, sabotage 240 keeps that refutable, and a provider "prompt too long" is indistinguishable
from any other `:provider_error`. Level-by-level, adapted clean-room from the Neoharness finding's
prose and OSA's staged pipeline:

**Level 1 — pre-turn, deterministic, no model call in the selection.** Before `seal/3`, if the
assembled `:history` exceeds a `context_cutoff_tokens` watermark (host config; default a fraction
of `max_input_tokens`, e.g. 70% of 60k), fold the **oldest eligible span**. Four things are never
foldable: the goal, the tool definitions (compile-time static per §4.2), a **protected recent
tail** (default the 2 most recent turns), and — **ruling UXD-17 explicitly** — **a prior fold's own
summary segment**. Selection is oldest-first and **whole turns only**, and a fold summary is a
*segment* appended beside a `[folded: …]` marker (§4 non-negotiable 4), never a turn, so it was
already excluded by that rule under one reading; this item removes the second reading rather than
leaving the two to disagree. **Consequence, stated so it is not inferred:** folds stay **one level
deep** — a later fold can consume unfolded turns but never another fold's summary, so no fold ever
cites another fold's provenance (see §7.2's note). A half-folded turn would put a tool call in the
ledger without its result.

> **The determinism rule, and why it is load-bearing.** The *selection* is a pure function of
> `{run_id, turn_index, view state}`; the *summary text* is not, because a model wrote it. The loop
> is at-least-once by design. So the fold is persisted as a numbered ledger entry **in the same DB
> transaction that advances the run cursor** (the A2 checkpoint shape), and a replay that finds an
> existing fold entry for its turn index **reuses it** — the `find_or_reuse_turn/3` /
> `Samen.Sequences.find_or_create_step_send/2` row-reuse pattern, one level down. Posture stated as
> the loop states it: the summarization *call* can genuinely repeat; the *fold* does not. Without
> this rule a crash-replay would produce a different `llm_view` than the pre-crash run, which is a
> worse failure than re-charging tokens for one summary.
>
> **Ruling UXD-18 — the two-checkpoint shape this needs, stated rather than assumed.** Persisting
> the fold entry only in the cursor-advance transaction means a crash *before* that transaction
> commits leaves nothing to reuse — there is no ledger row yet. This mirrors the turn-row shape
> already shipped one level down (`agent.ex:100-105`, RP-AG-7): a `:proposed` row is written
> **before** the slow provider call, and the same transaction that advances the cursor finalizes it
> to `:done`. The fold ledger adopts the identical two-checkpoint shape: a `:proposed` fold-entry
> row is persisted for the turn index **before** the summarize call, and the cursor-advance
> transaction finalizes it. A replay that finds an existing `:proposed` (or `:done`) row reuses it
> and does not re-invoke the summarizer; only a crash *before* that pre-call write causes a genuine
> re-summarize, with no ledger row yet committed to reconcile against.

**Level 2 — mid-turn, exactly one recovery attempt.** A provider "prompt too long" response
normalizes to a new bounded `@error_kind` `:context_overflow` (today it collapses into the
content-free `:provider_error`, which is honest but useless). On it: fold inline and retry
**exactly once**, tracked by a counter on the **same turn row** — one turn index, two provider
attempts, no loop. Three constraints:
- the failed attempt's tokens still count toward `max_input_tokens` (it was a real call);
- the retry boundary **re-checks the kill-switch, the durable cancel flag, and every budget**, for
  the same reason the loop re-checks them at every turn boundary and not only at run start
  (sabotage 244's target) — a recovery path that skips the kill-switch is a kill-switch with a hole;
- if the single retry also overflows, it is **level 3**, not a second retry.

**Level 3 — a NEW honest terminal.** `{:error, :context_exhausted, run}`: a terminal distinct from
`:budget_exhausted`, because "this run outgrew its context window" and "this run spent its
allowance" are different facts for an operator, and collapsing them into one error kind is the kind
of small dishonesty that makes a health surface useless.

> **The floor, restated verbatim and unweakened.** *The last assistant turn is not promoted to a
> result.* Not at level 2's failed attempt, not at level 3, not ever. The UI copy is
> *"Stopped — this run outgrew its context window after one recovery attempt. This is not a partial
> answer."* §9#3's floor is **non-configurable and is not an operator decision**; nothing in §10
> or §11 below offers to make it one. The `ui_view` (§4) keeps every rendered line, so a tenant can
> see exactly where and why it stopped — which is the honest alternative to a partial answer, and
> the reason §4 and §6 are the same ADR.

**Budget accounting for folds — a genuine ruling, not a detail.** Summarization calls consume real
tokens and real wall-clock. They **count** toward `max_input_tokens`, `max_output_tokens` and
`deadline_seconds`; they **do not** count toward `max_turns` or `max_tool_calls`. Rationale: a fold
is not a step the model chose, and charging it as a turn would let a compaction storm silently
consume the turn budget the tenant was promised — a run that spent 4 of 8 turns compacting would
report "budget exhausted" while having done half the work it claimed. Carried to §10 row 4.

**New bounded `@error_kinds` introduced by §5 + §6** (the closed-enum discipline; an unlisted kind
degrades to `:unknown`, so each must be added deliberately): `:context_overflow`,
`:context_exhausted`, `:compaction_refused`, and — from §7 — `:source_withdrawn`.

---

## 7 · Withdrawal propagation on shred — the derived-artifact rule ADR-046 does not have

ADR-046 rules columns, bags and blobs. It has **no rule for a value derived from those things by a
model.** A fold summary is exactly that. This section supplies the missing rule, in two parts,
deliberately ordered: containment does the work, propagation handles only the residue.

### 7.1 · D1 — Containment (primary, structural)

**Ruling.** Every compaction artifact — fold summaries, extracted durable facts, memos, working
notes, any text a summarizer produced from a run's history — is sealed **inside the same per-run
DEK envelope as the transcript it derives from**, on the run row, under the run's own 90-day
`:shred` retention spec. There is no second home.

**The categorical prohibition that follows.** Compaction output is **ineligible for pgvector
embedding and for any cross-run memory store, fact table, or cache.** ADR-043 M3 already ruled the
principle for grants — *vectors outlive grants and defeat crypto-shred* — and this generalizes it to
every derived artifact: a memo readable after its run's key is destroyed is an out-of-envelope
residue of exactly the `email_bidx` species, and the E7 gate would be right to fail on it. If
cross-run agent memory is ever wanted, it is a **different ADR's decision** (the decision-graph
memory ruling, which is a separate open item), and this rule binds it: such a store must be
subject-DEK-keyed or it does not ship.

**Why containment is the right primary.** ADR-046 §1 already tells us which pattern works. The
trace-sink pseudonym survives review precisely because it is *keyed off the subject's own DEK*, so
`shred` unlinks it **for free**, with no chase, no walk, no completeness argument. `email_bidx`
fails for the mirror reason. Containment buys the same property for summaries: shred the run, and
its folds are undecryptable bytes — not because anything walked them, but because the key is gone.
A propagation-first design would be a copy-chase, which is precisely the architecture ADR-046 §1
says `Samen.Erasure` deliberately is **not**.

### 7.2 · D2 — Propagation (the residue containment cannot reach)

Containment covers **run shred**. It does not cover withdrawals that happen *inside a live run*:

| withdrawal | reached by containment? | handled how |
|---|---|---|
| the run's own retention shred / account erasure | **yes, for free** — key destroyed | nothing to do (D1) |
| a **per-subject erasure while the run is live** | no — the fold already exists, sealed under the *run's* DEK, not the subject's | §7.3 walk |
| a **tool-result source withdrawn** (row destroyed, or a blob deleted via E4/E8 `delete_file`) | no | §7.3 walk |
| a **grant lapsing mid-run** | **not applicable** — §4.4 excludes grant plaintext from agent runs categorically, so no fold can ever contain a `{:grant_span, …}` | named and excluded, not handled |

That last row is deliberate: the obvious fourth case is already structurally impossible, and saying
so is cheaper and more honest than shipping a mechanism for it.

**A fifth case, closed by §6's ruling rather than by this section (UXD-17).** A fold whose
*source* is itself a prior fold's summary segment would be a nested-withdrawal path this table
does not name. §6's never-foldable list now rules it out structurally: a fold summary is never
itself eligible for a later fold, so no fold ever cites another fold's provenance, and every
`source_marker` the §7.3 walk matches is always a leaf record's, never a fold's. The propagation
walk therefore never needs a fold-to-fold hop — there is no second-generation summary for it to
reach, and no transitive hole for §7.3 to have.

### 7.3 · The mechanism — a pseudonym-keyed provenance index and a bounded walk

**Provenance (the Ankole citation rule, adapted).** Every fold entry records, per source segment:
the segment's `{run_id, seq}` id, its content digest, and a `source_marker` for each record the
folded turns consumed — the `{resource, record_id, subject_ref}` triple already available at render
time. **Token-only. No values, ever** — this is `RunRecord.bounded_outcomes/1`'s default-deny
posture, the same one the turn log uses.

**Where the index lives, and the trap in it.** The index must live **outside** the sealed body, or
the withdrawal walk would have to decrypt every run's DEK envelope to find its own targets — slow,
and a fresh INV-7 surface. But an index row that reads *"subject S appeared in run R"* is a
**plaintext-linkable value outside the DEK envelope** — the `email_bidx` failure mode, reinvented,
in the very ADR written to prevent it.

**The resolution — reuse the pattern ADR-046 says works.** `subject_ref` is stored as the
**DEK-keyed pseudonym** `Samen.Vault.pseudonym/1` = `HMAC(psk_S, subject_id)`, keyed off the
subject's **own** DEK. Then:
- before the shred, the erasure job can compute the pseudonym and match index rows exactly;
- **after** the shred, every remaining index row is permanently unlinkable — the key is gone —
  so the index self-erases with the subject, for free, exactly like the trace-sink pseudonym;
- the walk never decrypts a transcript to do its job, and a shredded run's index rows are inert.

> **The ordering constraint this creates — stated, not glossed.** ADR-046 §1 runs the key shred
> (step 1) **first and outside** the steps-2–5 transaction, in the fail-safe direction. That
> ordering is correct and this ADR does **not** propose changing it. The requirement is weaker: the
> pseudonym must be **computed before `Kms.shred/1` destroys the key** and carried as a value into
> the steps-2–5 transaction, where the withdrawal arm runs alongside the other redact-class arms.
> **Correction (UXD-19): `shred/2`'s pre-step-1 region does not assemble the erasure report** — it
> is option unpacking only (`erasure.ex:206-245`); the report is built at step 5, *inside* the
> steps-2–5 `Multi`, after the key is gone. There is no existing pre-flight computation to
> piggyback the pseudonym onto — it must be added, either as a new first line of `shred/2` before
> `Kms.shred/1`, or computed and passed in by `shred/2`'s caller. The conclusion is unaffected by
> the correction: adding that computation is still a parameter capture, not a reordering. Whether
> the shipped call sites can supply it unchanged is the one thing in §7 this draft cannot settle
> from the ADRs alone — **§11 O-3**.

**The walk** (`Samen.AI.Agent.Compaction.withdraw/2`, illustrative name), registered as an ADR-046
**erasure arm keyed on `subject_id`**, so `mix samen.verify.erasure_completeness` **discovers** it:

1. Match index rows by pseudonym, bounded to the retention window (a shredded run is skipped, not
   decrypted).
2. **Only still-matching** (Ankole's rule): if a segment's current digest differs from the digest
   recorded at fold time, the walk **stops on that segment and records a conflict** rather than
   clobbering it. Later edits win; the walk never rewrites something it does not recognize.
3. **Invalidate by neutralizing, never by deleting** (T182's discipline): the fold's body is
   replaced by a fixed bounded marker `[withdrawn: fold #n, source withdrawn]`. Length is not
   preserved and the marker is uniform, so the transform is many-to-one and carries no residual
   signal about what was there.
4. **The `ui_view` is not rewritten.** It gains one appended line recording that a withdrawal
   occurred; its original rendered lines stand. Rewriting the record of what a tenant was shown, in
   order to hide an erasure, is the audit lie §4 exists to prevent — and it is unnecessary, because
   agent runs are masked-only (§9#2), so the UI view holds no vault plaintext to erase and is
   reached by the run's own retention shred regardless.
5. **A live run whose fold was invalidated terminates fail-honest**, new bounded kind
   `:source_withdrawn`. It does not silently continue on a smaller context and it does not re-fold
   from the same withdrawn source. This is `:transcript_unavailable`'s existing precedent applied
   one level down — *an erased run can never keep executing on cached text*, and a fold whose source
   was withdrawn is cached text.
6. Idempotent and re-runnable: a second walk over an already-marked fold is a no-op.

**Gate obligation.** A **new discovery class** in `mix samen.verify.erasure_completeness` —
*derived-summary segments* — extending the transcript arm ADR-047 §10a row 2 added rather than
adding a parallel arm, with the same non-vacuity floor (empty discovery fails) and a sabotage that
removes the withdrawal arm and must flip a **named** assertion.

### 7.4 · The boundary this ADR does NOT settle

**Free text about a third party.** ADR-047 §11 already carries it: free text about a third party in
a goal prompt is reached by the run's own retention shred, **not** by that third party's erasure —
the same boundary ADR-046 §7#5 rules for *about-a-subject* blobs. A fold summary inherits this
boundary exactly and **does not widen it**: a summary of masked history is masked; a summary of
free text about a third party is free text about a third party, contained in the run envelope and
shredded with it, no sooner. This ADR **points at** the boundary and asks that the two be ruled
together (**§11 O-2**); it does not settle it unilaterally, because it is a
retention-vs-erasure policy call, not a mechanical one.

---

## 8 · Proof obligations (design; nothing built)

| # | Obligation | Shape |
|---|---|---|
| P1 | A summary that skips the ingress path is refutable | Sabotage: drop `Secrets.redact/1` + `Ingress.sanitize/1` from the summary path; a named red asserting an injected instruction and a vendor-prefixed key in summarized tool output are both neutralized in the persisted `llm_view` must flip — with a positive control that ordinary summary prose survives intact |
| P2 | Compaction never rewrites the UI view | Sabotage: point the fold at `ui_view`; a named red comparing the pre/post-fold `ui_view` must flip |
| P3 | The fail-honest floor survives recovery | Sabotage: promote the last assistant turn on `:context_exhausted`; extends sabotage 240's target to the new terminal |
| P4 | Level 2 retries exactly once | Sabotage: drop the retry counter; a red asserting two attempts per turn row must flip |
| P5 | The kill-switch is re-checked at the retry boundary | Sabotage: skip the re-check on retry; the sabotage-244 shape, one level down |
| P6 | Fold reuse on replay | Red, two cases per the §6 two-checkpoint ruling (UXD-18): crash **after** the pre-call `:proposed` write — the replay must reuse that row, not re-summarize (`meta: %{"replayed" => true}`); crash **before** it — the replay legitimately re-summarizes, since no ledger row exists yet to reuse |
| P7 | Withdrawal reaches folds | New `erasure_completeness` discovery class + a red: shred a subject, assert every citing fold is marked, plus the anti-tautology positive control that a **non**-erased subject's fold survives |
| P8 | The provenance index is unlinkable after shred | Red: after shred, no index row resolves to the subject; asserted on the pseudonym, not on absence of rows |
| P9 | `:after_compaction` cannot widen | Red: a hook returning `{:edit, _}` at that point is refused (`:hook_error`), never applied |
| P10 | INV-7 holds on the new surface | `ai_prompt_masking` + the permanent red-team EG2 arm re-run with a vault-seeded canary inside a **folded** span — the canary must not reappear in the summary |

---

## 9 · Build plan sketch (recorded design; NOT filed as backlog rows)

| batch | scope | gate |
|---|---|---|
| **C1** | Dual-view transcript (§4) + the reader-side migration. **No compactor.** | P2; the E7 transcript arm re-run byte-identical |
| **C2** | Levels 1 + 3 with a **deterministic, non-model** fold (drop-with-marker, no summarizer) + `:context_overflow` / `:context_exhausted` | P3, P4, P6 |
| **C3** | The summarizer: §5's full ingress path + `:after_compaction`'s call site + `:compaction_refused` | P1, P9, P10 |
| **C4** | Withdrawal: provenance index, the walk, the new discovery class, `:source_withdrawn` | P7, P8 |

C1+C2 deliver runway and honesty **without any model-written text entering the transcript**, which
is why §11 O-1 asks whether that is the whole of v1.1.

---

## 10 · Decisions for the operator

All **OPEN — needs-operator-input**. Nothing below is taken.

| # | Decision | Options | Recommendation | Status |
|---|---|---|---|---|
| **1** | **May a model-written summary enter a governed transcript at all?** | (a) yes, through §5's full ingress path · (b) no — deterministic fold only, never model-written · (c) yes, but only for runs that never persist | **(a)**, with (b) as the C1+C2 staging. (c) repeats the mistake §9#2 rejected: making a governance property depend on whether a run happened to be resumed. | **OPEN** |
| **2** | **Do the two views multiply shred units?** | (a) one blob, two keys, one DEK · (b) two rows, two retention specs | **(a).** (b) forces a second erasure arm and a second E7 target for zero benefit. | **OPEN** |
| **3** | **Is compaction output categorically ineligible for embedding / cross-run memory?** | (a) yes, categorical · (b) allow with a subject-DEK-keyed store · (c) allow, retention-bounded | **(a).** ADR-043 M3's reasoning generalizes; (b) is the right *future* door and §7.1 leaves it open for the memory ADR to walk through, but opening it here would ship the first cross-run derived store in the same batch that designs it. | **OPEN** |
| **4** | **Do folds spend the turn budget?** | (a) tokens+deadline yes, turns/tool-calls no · (b) everything yes · (c) folds are free | **(a).** (b) lets a compaction storm eat the turns a tenant was promised; (c) is not fail-honest — the tokens are real and are billed. | **OPEN** |
| **5** | **How many mid-turn recovery attempts?** | (a) exactly one · (b) two · (c) until the watermark clears | **(a).** Each attempt is a full-price provider call on an already-oversized prompt; (c) is a budget hole disguised as resilience. | **OPEN** |
| **6** | **Does an invalidated fold terminate the run?** | (a) terminate `:source_withdrawn` · (b) continue on the shortened context · (c) re-fold from the surviving sources | **(a).** `:transcript_unavailable`'s precedent. (b) reasons over text whose source was withdrawn; (c) re-derives from a source set that no longer includes what was withdrawn, and quietly changes what the run believed. | **OPEN** |

---

## 11 · Open questions for the operator

- **O-1 — Is C1+C2 the whole of v1.1?** The absence of a compactor is a **runway** problem, not a
  live defect (§1): masked-only 8-turn runs rarely overflow, and when they do they fail closed.
  Landing the dual view plus deterministic folding plus the honest terminal — **with no
  model-written text in the transcript** — closes the audit-integrity and honesty halves and defers
  every governance question §5 raises. **Recommendation: yes, stage it**, and treat C3+C4 as a
  second ratification with real usage data behind it.
- **O-2 — Rule the third-party free-text boundary together with this ADR, or keep it open?**
  ADR-046 §7#5 (about-a-subject blobs) and ADR-047 §11 (third-party free text in a goal) are the
  same question; §7.4 shows a fold inherits it without widening it. **Recommendation: rule them
  together**, since a summary makes the boundary more visible without changing it.
- **O-3 — Can a new pre-shred computation carry a pseudonym into the steps-2–5 transaction?**
  §7.3 needs the subject's pseudonym computed **before** step 1 destroys the key, without
  reordering ADR-046's fail-safe step order. No such computation exists today (UXD-19: `shred/2`'s
  pre-step-1 region is option unpacking only, `erasure.ex:206-245`); this draft asserts adding one
  is a parameter capture, not a reordering, but it **cannot verify that from the ADRs alone** — it
  is the one implementation fact C4 must confirm before its design is final. If it turns out no
  call site can supply it unchanged, the fallback is an index keyed on a **separately shreddable**
  derived key, and that fallback needs its own crypto review (it is a `k_bidx`-shaped decision, and
  `k_bidx` is the one that went wrong).
- **O-4 — What is the default `context_cutoff_tokens` watermark?** Proposed: 70% of
  `max_input_tokens` (42k of the ratified 60k), host-configurable, floor non-configurable at
  "never fold the goal, the tool defs, or the 2 most recent turns."
- **O-5 — Whole-fold or micro-compaction?** §5 recommends **whole-fold** and names the
  prompt-cache-invalidation cost. Micro-compaction is steadier on cost but cache-hostile and
  multiplies §7's provenance edges by roughly the turn count, weakening the walk's non-vacuity
  floor. **Recommendation: whole-fold.**
- **O-6 — Does `:context_exhausted` warrant its own operator-health column?** It is the signal that
  an agent definition's goal has outgrown its budget shape — arguably more actionable than
  `:budget_exhausted`. Cheap either way; ruled here only so it is not discovered later.

---

## 12 · Consequences

**Positive.** ADR-046 gains the derived-artifact rule it does not have, stated in its own idiom
(containment via the subject-DEK pattern that already works, propagation only for the residue).
ADR-047's `:after_compaction` point stops being a declared-with-no-caller loose end and gets the
caller it was declared for — one seam extended, not a fifth added. The dual view makes long-run
compaction possible **without** rewriting what a tenant saw, and levels 1–3 replace an
indistinguishable `:provider_error` with two legible terminals. And the three content transforms
this session shipped (`Secrets.redact/1`, `Ingress.sanitize/1`, the §4.3 renderer) are reused on
the summary path rather than re-derived, so compaction inherits their proofs instead of needing new
ones.

**Negative / named.**
- **This is a real build, staged across four batches**, and C4 is the expensive one: an erasure arm,
  a new discovery class, a pseudonym-keyed index and a bounded walk are not a weekend.
- **Prompt-cache reuse is invalidated from the fold point forward** (§5). Real cost, named.
- **Compaction is a strictly worse history.** A folded run has demonstrably less context than an
  unfolded one; folding is a *degradation* chosen over a terminal, and the ledger exists so it is
  a visible one.
- **C3 puts model-written text into a governed transcript for the first time.** §5's six points are
  the reason that is defensible; O-1's staging is the reason it need not be decided today.
- **The index is a new structure outside the sealed body.** §7.3's pseudonym keying is what makes it
  safe, and O-3 is the one open link in that argument — named rather than assumed.
- **`:source_withdrawn` will terminate runs that a user thinks are fine.** That is the fail-honest
  cost, and it is the same cost `:transcript_unavailable` already imposes.

**Neutral.** The chokepoint's public heads, `PiiResolution`, `Samen.Pii.Info`, the four-way tool
intersection, the E3 approvals path, ADR-043 §6.2, and the ratified budgets and retention (§9#3,
§9#4) are all consumed **unchanged**. This ADR amends no ratified decision in ADR-046 or ADR-047;
where it presses on one (§6's floor, §7.3's step order, §7.4's third-party boundary) it either fits
inside it or carries an open question in §11.

---

## 13 · See also

- **ADR-046** — erasure completeness: §1 (the shred/DEK model and the two patterns), §6 (the
  completeness verifier and its discovery classes), §7#5 (the about-a-subject boundary).
- **ADR-047** — the agent loop: §4.3 (the six scrub points), §4.3a/§4.3b (ingress + secrets),
  §4.4 (grant exclusion), §5.1a (tool surfaces), §6 (budgets, breakers, the turn log), §7.4
  (transcript erasure), §9#2/#3/#4, §10a rows 2 and 25–28, §11.
- **ADR-043** — §3.1 INV-7/EG2, §3.2a the per-turn re-scrub, §6.1/§7.2 grants, M3 (vectors outlive
  grants).
- **ADR-014 / ADR-024 / ADR-026** — the fail-honest contract §6 restates rather than paraphrases.
- **OSS scan findings** `001` (Ankole), `005` (OSA), `006` (Pepe), `016` (Neoharness —
  **UNLICENSED, clean-room, prose only**), `034` (Alloy), `038` (Condukt), `047` (Sagents).
