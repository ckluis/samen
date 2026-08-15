# ADR-047 — The AI agent loop: first-party durable multi-step tool use, governed by the EG2 egress class

- **Status:** **PROPOSED** (stays PROPOSED until A7 lands; the §9 operator decisions were
  **ratified 2026-08-14 — all seven TAKEN as recommended**, unblocking A1).
- **Date:** 2026-08-14
- **Build status:** **NOT STARTED.** This ADR authors no product code. It is docs-only per the
  standing decompose-cross-cutting-changes rule: it touches no source, no test, no sabotage, no
  abbrev-registry row, no `schema.dict.json`, no `mix.exs`, and adds **zero dependencies**. The
  build lands in the seven BATON batches §8 sequences, each with its own adversarial gate.
- **Task:** Close the **EG2 gap** recorded by the Jido evaluation (`_orch/jido-eval-report.md`
  §2.3 / §4): ADR-043 §3.1 declares EG2 — *"tool/function definitions, tool args, and
  tool-result re-entry into a prompt"* — a governed egress class, and the chokepoint already
  ships `:history` with per-turn grant re-scrub (§3.2a) **precisely to serve multi-turn loops**,
  but nothing implements it. Every shipped AI surface is single-shot. Close it **first-party**,
  inside the AST anti-bypass probe's and the sabotage harness's coverage.
- **Deciders:** the operator, for the seven decisions in **§9** (autonomous-write policy, grant
  plaintext in a persisted transcript, default cost budgets, transcript retention, streaming
  deferral, verifier placement, and the v1 slice) — **all seven ratified 2026-08-14 exactly as
  recommended and marked TAKEN in §9**. Everything else is recorded design a BATON builder
  executes without re-deriving.
- **Consumes (binding inputs):**
  - **ADR-043 §3.1 EG2** — the declared-but-unimplemented egress class this ADR implements;
    **INV-7** (§3.1), the chokepoint pipeline (§3.2), the **per-turn history re-scrub** (§3.2a),
    the **EG6** observability contract (§3.2b), **§6.1** masked-by-default egress +
    `grant_plaintext_egress`, **§6.2** *"AI writes do not exist: AI outputs are drafts and
    proposals … anything with side effects goes through the E3 approvals engine"* — which
    **binds §5.3 of this ADR and is deliberately not amended**, §7.2 (grants never unlock
    persisted egress), §10 (the permanent red-team tier + the ≥90% context-assembly bar).
  - **ADR-039** — the automation engine: `Samen.Automation.Action` (the 8-kind registry),
    `Automation.Compile` → `Reactor.Builder` with per-step compensation, `Automation.Run`
    (AshStateMachine) + `RunRecord`'s bounded-outcome allowlist, `Automation.Health` /
    `Breaker`, `EventCapture`'s same-transaction Oban enqueue, `Automation.Context`.
  - **ADR-037 §5.6 / §5.7 / §5.8 / §5.9** — ash_ai REJECT (hand-built kernel); Reactor,
    AshStateMachine, AshOban ADOPT. The Jido evaluation re-confirmed the same verdict one
    package over: adopting an agent framework moves prompt assembly outside the two gates that
    make samen's AI claims defensible. **This ADR adds no dependency.**
  - **ADR-014 / ADR-024 / ADR-026** — the fail-honest adapter contract. Budget exhaustion,
    provider failure, and tool failure all return honest errors; **no partial answer is ever
    dressed as a result.**
  - **ADR-040 §4** — the E3 approvals engine + the `Samen.Approvals.Gate` face (requester ≠
    approver at both the policy and `<abbrev>_distinct_party` DB-CHECK layers), which is how a
    mutating tool executes.
  - **ADR-046** — the erasure-completeness gate. This ADR must not create a new out-of-envelope
    residue; §7.4 states how the transcript is reached and why the E7 discovery classes are
    unchanged.
  - **ADR-042** — the plane/client model (masking resolved server-side; the LiveView never
    branches on plane). **T144** — the operator-only analytics gate (`Samen.AI.Analytics`
    `platform_actor?/1`, impersonation-refused-first), which constrains which actions may
    become tools (§5.2).
  - **CLAUDE.md** — framework-first ≈0-LOC vertical mounts; the abbrev registry is HANDS-OFF
    (every new resource reserves through `mix samen.abbrev.reserve`, driven by the generator).
- **Binds (implementing batches):** A1–A7 (§8).

---

## 1 · Context — what exists, what is missing, and the exact size of the hole

**What exists.** `Samen.AI.Chokepoint` (`samen_core/lib/samen/ai/chokepoint.ex`, 539 LOC) is
simultaneously the only site that mints a `%Samen.AI.MaskedPayload{}` and the only site that
invokes a `Samen.AI.Provider` callback. `seal/3` is a fixed-order fail-closed pipeline: resolve
`:bindings` through `Samen.Api.PiiResolution` in egress mode → **re-scrub `:history` against the
current turn's grant state** → assemble → scrub by **allowlist** (`safe_segment?/1` admits only
`vt_`-free binaries, bounded primitives, sealed payloads, and lists thereof; every map, tuple,
keyword list, struct, and atom refuses) → seal. `safe_metadata?/1` extends the same allowlist to
`:grounding`/`:meta` as a bounded map recursion over **keys and values**. Provider errors
normalize to a content-free `{:provider_error, provider}` (EG6); `%MaskedPayload{}` is
Inspect-redacting; `Samen.AI.ChokepointAntiBypassProbeTest` AST-scans **every app's `lib/`** for
out-of-chokepoint constructions; `scripts/sabotages/` carries 239 patches, two of which
(`44-d2-ai-egress-history-remask-bypass`, `45-t65-ai-egress-scrub-shape-blind-tuple-hole`) are
*already* about multi-turn re-scrub and the EG2 tool-args tuple hole.

For orchestration, samen owns: `Samen.Automation.Action` (8 governed kinds), `Automation.Compile`
→ runtime `Reactor` graphs with reverse-order compensation, `Automation.Run` (AshStateMachine) +
`RunRecord`'s default-deny `bounded_outcomes/1` allowlist, `Automation.Health` + `Breaker`
(rate trip + operator kill-switch), `EventCapture`'s **in-transaction** `Oban.insert`, and
`Samen.Sequences` — a durable multi-step engine with a **never-nil `next_send_at` watchdog** and
row-reuse idempotency (`find_or_create_step_send/2`) that is the closest shipped precedent for
what this ADR builds.

**What is missing, stated exactly.** Grep confirms no `tools:` / `tool_use` / `tool_choice`
anywhere in `samen_core/lib`, `samen_web/lib`, or `samen_anthropic/lib`, and **no `lib/` caller
passes `history:`**. `Samen.AI.Verbs.run/3` → one `complete/4`. Search → one `embed`. The support
operator → ground → draft → E3 approval. `Samen.AI.Mcp` inverts the direction (samen is the MCP
*server*; the loop runs in the external agent's process, which is exactly why it is safe and why
it is not this gap). **The missing piece is dynamic step selection — the model choosing step
N+1 — inside samen's own process.**

**Honest sizing.** The Jido report's "~150–300 LOC" figure is right *for the step-selection core
alone* — a recursive turn function over `Samen.AI.complete/4` really is ~250 LOC. It is not the
cost of shipping this at samen's standard. Durability with crash-safe tool idempotency,
EG2-correct tool-def and tool-result scrubbing, effect-classed tool gating through E3, a
fail-honest budget, an interruptible run, two rendered surfaces with MaskingCase three-proofs, a
coverage verifier, a generator, and nine sabotage patches come to roughly **2,000–2,400 authored
non-test LOC** (§8). Stating both numbers is the point: the *novel* mechanism is small; the
*governed* mechanism is not, and the difference is why this is built rather than adopted.

**Why now, and why the requirement is now driven.** The Jido report closed with "revisit only if
a driving multi-step agent requirement is accepted in an ADR." This ADR is that acceptance. The
driving requirement is product-level: every shipped AI surface answers one question and stops. A
tenant asking "why is shipment 4471 late and who should own it?" needs the model to look, then
look again based on what it found, then propose an action — three governed steps the platform
declares it governs (EG2) and cannot currently perform.

---

## 2 · Decision drivers

1. **INV-7 must hold on every hop, and the hops multiply.** A single-shot call has one egress.
   An N-turn loop has N prompt egresses, N tool-definition egresses, and up to N tool-result
   re-entries — and the result of a *governed read* is exactly the shape (`%Masked{}` structs,
   `%Ash.ForbiddenField{}`, nested records) the segment allowlist refuses. Every one of those
   must be a **named scrub point**, not an assumption (§4).
2. **The registry is the allowlist, and it must narrow, never widen.** ADR-039's 8 governed
   actions already refuse non-PII-violating predicates at write time and send only through
   `Samen.Delivery.Chokepoint`. A model choosing among them must not be able to reach anything
   the registry does not contain, and *within* the registry must not reach anything its own
   definition did not name.
3. **ADR-043 §6.2 is binding, not advisory.** *"AI writes do not exist … anything with side
   effects goes through the E3 approvals engine."* An agent with autonomous write tools would
   amend that ruling. This ADR does **not** amend it (§5.3), and flags the amendment as an
   operator decision (§9#1) rather than taking it silently.
4. **Durability must not weaken the same-transaction enqueue guarantee** `EventCapture` and
   `Samen.Sequences` depend on, and must not make a tool call replay a side effect.
5. **Fail-honest, always.** A budget-exhausted run must not return a truncated answer. A failed
   tool must not be summarized away. A keyless CI must be able to prove all of it (M9).
6. **Erasure must not regress.** A durable transcript is tenant data at rest. ADR-046's gate
   must stay green with **no new out-of-envelope residue and no new named residual** (§7.4).
7. **≈0-LOC vertical adoption.** The loop lives in `samen_core`/`samen_web`; a vertical's
   authored surface is a ~5-line agent module plus one router macro call. The leverage guard
   applies (CLAUDE.md).
8. **Zero new dependencies.** Reactor, AshOban, AshStateMachine, Oban, Phoenix.PubSub are
   already adopted and already carry org-scoping, plane discipline, and a policy actor. Nothing
   an agent framework offers is worth moving prompt assembly outside the AST probe's reach.

---

## 3 · Decision (summary)

Build **`Samen.AI.Agent`** — a first-party, durable, interruptible multi-step loop over
`Samen.AI.complete/4`, whose tools are governed `Samen.Automation.Action`s and whose every
provider-bound byte still passes `Samen.AI.Chokepoint.seal/3`. Eight load-bearing decisions:

1. **Checkpoint-per-turn, batch-per-job** (§4.1): a durable `Samen.AI.Agent.Run` row is the
   cursor; an Oban worker executes turns until a per-job turn budget, committing a checkpoint
   **between the tool decision and the tool execution**; a never-nil `next_turn_at` watchdog +
   an AshOban due-scan trigger recovers any lost job. Tool idempotency is a **turn row keyed
   `{run_id, turn_index}`**, reused on replay — the `Samen.Sequences` shape, not Oban uniqueness.
2. **Tools are a four-way narrowing intersection** (§5.1): registry ∩ **explicit per-action
   opt-in** (`tool_schema/0`, default `:not_a_tool`) ∩ the agent definition's `tools:` list ∩
   the run actor's own policy envelope. No existing action becomes a tool by accident.
3. **Tool definitions are EG2 egress and ride a new scrubbed `:tools` field on
   `%MaskedPayload{}`** (§4.2), scrubbed by `safe_metadata?/1`. Schemas are **static per action
   module** — never derived from tenant data — enforced structurally by the verifier.
4. **Tool results re-enter only as rendered, egress-resolved binaries through `:history`**
   (§4.3), so §3.2a applies on every subsequent turn and `safe_segment?/1` is the last line.
   Vault-routed fields render `••••` (mask-by-omission on the AI plane).
5. **Grant plaintext is categorically excluded from agent runs** (§4.4): the transcript
   persists, and INV-7 forbids grant plaintext in *any* persisted egress (§7.2). An agent run is
   masked-only even with a live grant and `grant_plaintext_egress: true`. This is a
   **clarification of ADR-043 §6.1's "ephemeral" clause, not an amendment**.
6. **Mutating tools do not execute; they propose** (§5.3): an `effect: :write` tool opens an E3
   approval through `Samen.Approvals.Gate`, the run parks in `:awaiting_approval`, and a human
   who is never the requester approves — at which point the Gate re-invokes the action **as the
   requester, `authorize?: true`** (consent, never escalation). ADR-043 §6.2 holds unamended.
7. **Fail-honest budgets and a genuine interrupt** (§6): max-turns, max-tool-calls, token, and
   wall-clock budgets; exhaustion is a terminal `:budget_exhausted` error, never a partial
   answer. `cancel/2` is durable and re-checked at every turn boundary — samen's first real
   interrupt semantics, framed honestly ("stopping after the current step").
8. **Everything is provable keyless** (§7): a deterministic `Samen.AI.Provider.Scripted`, a
   shipped-in-`lib` `Samen.AgentCase` proof kit, nine new sabotage patches, two new
   `ai_prompt_masking` structural checks, a new `samen.verify.agent_coverage` gate, an EG2 arm
   on the permanent red-team tier, and MaskingCase three-proofs on both new rendered surfaces.

---

## 4 · Loop architecture (design question A)

### 4.1 · Durability: where the loop lives and how a crash behaves

**Options.**

- **(a) In-process loop, Oban only at the job boundary.** `Samen.AI.Agent.run/3` recurses in the
  worker process; one job = one whole run. *Rejected.* A node restart mid-run loses every turn's
  work and, worse, loses the record that a tool already fired — so an Oban retry re-executes
  side effects with no dedupe key. It also cannot express `:awaiting_approval` (a run that must
  survive hours), and it holds a DB connection and a provider budget for the run's whole life.
- **(b) One Oban job per turn.** Each turn enqueues the next. *Rejected as the primary shape.*
  It buys crash granularity that (c) already has, at the cost of N scheduler round-trips per
  run, N job rows, and a queue-latency floor on every turn — and it does **not** solve tool
  idempotency, because the dedupe unit is still the tool call, not the job. Oban's own
  `unique:` cannot express "this tool already ran" across the pruning horizon (the exact
  reason `Automation.RunRecord` carries a tier-2 `dispatch_key` alongside RunWorker's tier-1
  uniqueness).
- **(c) Checkpoint-per-turn, batch-per-job, watchdog-recovered — RECOMMENDED.** The durable
  `Samen.AI.Agent.Run` row is the cursor (`current_turn`, `state`, `next_turn_at`, budgets
  consumed). One Oban job executes turns until a per-job turn budget (`@turns_per_job`,
  default 4) or a terminal/parked state, then either finishes or re-arms. Every turn writes
  **two** checkpoints:
  1. **the decision** — `turn_index`, chosen tool kind, validated args digest, `:proposed`;
     committed *before* any side effect;
  2. **the outcome** — status, bounded meta, rendered result, `:done`.
  A crash between (1) and (2) is recovered by the watchdog, which replays turn `N` and finds
  the existing `:proposed` turn row — the tool executes **at most once** because the executor
  reuses that row as its idempotency key (`Samen.Sequences.find_or_create_step_send/2`'s
  row-reuse pattern, verbatim in shape). Posture is stated plainly, as Sequences does:
  **at-least-once delivery, never claimed exactly-once**; the dedupe is the turn row.

**Restart semantics.** `next_turn_at` is **never `nil`** while a run is non-terminal — the
Sequences invariant, adopted because a `nil` cursor is unselectable by the due-scan `where`
clause and produces a permanent silent stall. A run in flight sets `next_turn_at = now + 600s`
(the in-flight watchdog); a parked run sets it to its approval deadline; a terminal run sets it
`nil` exactly once. An AshOban trigger `:agent_turn_due` on queue `:automation_timers` with an
**explicit `scheduler_cron("* * * * *")`** and pinned `scheduler_module_name`/`worker_module_name`
(so `mix samen.verify.oban_queues` / `Samen.Jobs.QueueParity` can see it) re-arms anything the
watchdog finds due.

**The same-transaction enqueue guarantee is preserved, not bypassed.** An agent run started from
a tenant write (the `EventCapture` path) enqueues its first job via `Oban.insert` inside the
triggering action's `after_action` — the identical idiom `Samen.Sequences`' `:advance_due` uses,
so the job exists iff the write committed. Tools that themselves enqueue (`enqueue_reminder`)
keep their own guarantee unchanged, because they run inside their own governed action's
transaction. **Slow I/O — the provider call and the tool's own egress — is deliberately outside
any transaction**, exactly as `Samen.Delivery.Chokepoint.send/2` is in Sequences' worker.

**Retry authority lives in one place.** The worker returns `:ok` to Oban for every business
outcome (tool failure, provider failure, refusal, budget exhaustion); only a fetch-chain failure
returns `{:error, _}`. The run row's watchdog is the single retry authority — Sequences' rule,
adopted because two retry authorities produce compounding re-execution.

**Reactor.** `Automation.Compile` is *not* reused for the agent loop: a Reactor graph is
statically built before it runs, and the whole point here is that step N+1 is chosen after step
N returns. Reactor is still used **within** a turn: a write tool that is approved executes
through the existing `Automation.ActionStep` path so per-step compensation (`undo/3`) is
unchanged. Stated so no one later "unifies" them and loses compensation.

### 4.2 · Where tool definitions ride (EG2, half one)

A tool definition is a bounded, static map: `%{name:, description:, params: [%{name:, type:,
enum:, required?:}]}`. It cannot ride `segments` — `safe_segment?/1` refuses every map, by
design, and that refusal is exactly what sabotage 45 protects.

**Options.** (i) flatten schemas to text and prepend as segments — loses the structure real
providers need and re-introduces an ad-hoc encoding; (ii) ride `grounding[:tools]` — already
scrubbed by `safe_metadata?/1`, zero struct change, but contaminates the field whose contract is
"catalog-derived grounding metadata" and whose **parity test against `mix samen.catalog.dump`**
(§8/D9) is a shipped invariant; (iii) **add a `:tools` field to `%MaskedPayload{}`, scrubbed by
`safe_metadata?/1` — RECOMMENDED.**

(iii) wins because the chokepoint is the only minter (so adding a field costs nothing
structurally), `safe_metadata?/1` already recurses **keys and values** with `vt_` scanning and
charlist-rendering checks, the D9 grounding-parity contract stays clean, and a provider adapter
gets an unambiguous EG2 field to map onto its vendor `tools:` parameter. `seal/3` gains one more
`scrub_metadata/1` call in the same `with` chain; the `Inspect` impl renders **only the tool
count**, never names or descriptions.

**Static-schema rule (the load-bearing constraint).** A tool schema MUST be a compile-time
constant of its action module. A schema whose `enum` was populated from live records would be a
silent EG2 egress of tenant data on every turn. Dynamic choices are resolved by *calling a read
tool*, never by baking values into a definition. Enforced structurally (§7.2 check (d)).

### 4.3 · Tool-result re-entry — the exact scrub points (EG2, half two)

This is the hop the Jido report named as the one samen "does not have." Spelled out end to end;
each numbered point is an assertion site, not a description.

1. **Execution plane.** The tool runs as the run's **owner actor** — the initiating member's
   real scope, re-resolved at turn time (the `Automation.RunWorker` owner-resolution rule: a
   removed owner ⇒ `:owner_unavailable`, never silent re-attribution). Reads go through
   `Samen.Policy.OrgScope` (cross-org rows do not exist) and `Samen.Api.PiiResolution`. **The
   chokepoint never elevates, substitutes, or synthesizes an actor** (INV-2).
2. **Render (the new module: `Samen.AI.Agent.ToolResult.render/2`).** The action's `{:ok, meta}`
   and any records it carries are resolved through `Samen.Api.PiiResolution.resolve/4` **in
   egress mode** (`egress: true`, `grant_egress?: false` — §4.4) and flattened to an ordered
   list of **binaries**. `%Samen.Masked{}` → `"••••"`. `%Ash.ForbiddenField{}` → `"••••"`.
   `nil` → `"••••"` (the chokepoint's own `render_value/1` semantics, reused rather than
   re-derived). Anything the renderer does not recognize is **dropped with a bounded
   `[unrenderable:<field>]` marker, never `inspect/1`-ed** — an `inspect` here would be the
   freeform-text leak `RunRecord.bounded_outcomes/1` exists to prevent.
3. **Persist.** The rendered binaries are appended to the run's transcript (§7.4) and the
   bounded turn row. Because step 2 already masked, **the transcript at rest contains no vault
   plaintext and no `vt_*` token** — a property asserted directly, not inferred.
4. **Re-enter.** On turn N+1 the transcript's rendered lines are passed as `:history` to
   `Samen.AI.complete/4`, so `Samen.AI.Chokepoint.rescrub_history/2` (§3.2a) runs over them.
   They are ordinary (untagged) segments — the agent **never** emits a `{:grant_span, …}` tag,
   because §4.4 excludes grant plaintext entirely — so they take the `other -> other` branch and
   are then `vt_`-scanned by step 5 like any segment.
5. **Refuse (the last line).** `seal/3`'s `safe_segment?/1` allowlist runs over the assembled
   payload. If the renderer ever regresses and emits a map, tuple, keyword list, struct, or atom,
   the payload **refuses `{:error, :pii_egress_refused}`** — fail-closed, payload-free. The
   renderer is defense; the allowlist is the guarantee. This is deliberate belt-and-braces: the
   sabotage in §7.1 breaks the renderer and asserts the *refusal* is what the test sees.
6. **Echo the tool call itself.** The model's own tool call (kind + args) also re-enters as
   history. It is rendered to a single `vt_`-free binary by the same renderer — **never passed
   as the raw arg map**. This is precisely the hole sabotage 45 documents: a raw `vt_*` token
   wrapped in an EG2 tool-args tuple once egressed. The new sabotage (§7.1#2) re-proves it on
   the agent path.

**Tool arguments are untrusted model output.** They are parsed, then validated by the action's
own **write-time `validate/2`** — the same validator the Workflow changeset uses — before
execution. Invalid args are a **fail-honest tool error fed back to the model as a bounded
message** (`"invalid_args: <bounded reason>"`), never a raise and never a silent coercion. An
arg referencing a subject attribute must reference a **condition-eligible** one (ADR-039 §5.2's
oracle gate), which structurally excludes vault fields from arg space.

### 4.4 · Grant plaintext is categorically excluded from agent runs

ADR-043 §6.1 admits grant-covered plaintext into **ephemeral completion payloads only**, and
§7.2 is categorical that grants never apply to persisted egress. An agent run's history **is
persisted** — that is what makes it resumable. Therefore:

> **An agent run resolves masked on every plane, regardless of any live reveal grant and
> regardless of `grant_plaintext_egress`.** `Samen.AI.Agent` passes `grant_egress?: false`
> explicitly at every `complete/4` call; the transcript can never contain a `{:grant_span, …}`
> tag; §3.2a's re-mask path is therefore vacuous *for agent runs by construction*, not by luck.

This is a **clarification** of §6.1's "ephemeral" clause applied to a new persisted surface, not
an amendment: nothing in §6.1 is weakened, and the one permitted exception is unchanged for
single-shot completions. It is nonetheless product-visible (an agent answers about PII-bearing
fields shape-only, always), so it is carried as **operator decision §9#2** with the
recommendation to take it.

The alternative — hold history in memory for one job batch and admit grant plaintext within it —
was considered and rejected: it makes a run's masking depend on whether it happened to be
resumed, which is the worst possible property for an invariant to have.

---

## 5 · The tool surface (design question B)

### 5.1 · Tools are governed Automation.Actions, and the intersection narrows four ways

```
callable_tools(agent, actor) =
      Samen.Automation.Action.registry()          # 1. the governed allowlist (ADR-039)
    ∩ {a | a.tool_schema() != :not_a_tool}        # 2. explicit per-action opt-in, default OFF
    ∩ agent.definition.tools                      # 3. the agent's own declared list
    ∩ {a | authorized?(a, actor)}                 # 4. the run actor's real policy envelope
```

Two optional callbacks are added to `Samen.Automation.Action`, both **fail-closed by default**,
so **no shipped action becomes a tool without an explicit edit**:

```elixir
@callback tool_schema() :: map() | :not_a_tool   # default :not_a_tool  — not a tool
@callback effect()      :: :read | :write        # default :write       — approval-gated
@optional_callbacks tool_schema: 0, effect: 0
```

`effect/0` defaulting to `:write` matters: an action that forgets to declare falls under the
approval gate rather than executing autonomously. The 8 shipped kinds are all side-effecting
(`notify`, `send_email`, `mutate_record`, `assign_owner`, `add_tag`, `escalate`, `webhook`,
`enqueue_reminder`), so an agent with only the current registry could look but never *see*.
Batch **A3** therefore adds two **read-effect** actions to the same registry —
`"search_records"` (org-scoped tsvector + semantic search through the shipped
`Samen.AI.Embeddings.search/3`) and `"fetch_record"` (a governed single-record read projected to
catalog-declared, condition-eligible fields) — rather than inventing a second read-tool registry.
**One registry stays the one allowlist**; that is the whole reason the registry is trustworthy.

**Excluded by rule, named so no one adds them later:** `Samen.AI.Analytics.ask/4` is not a tool.
T144 would refuse it for any tenant actor anyway (`platform_actor?/1`, impersonation refused
first), and offering a tool that always fails is a dead end, not honesty. `webhook` is not
opt-in-eligible in v1 (arbitrary model-chosen egress to a model-chosen URL is a new egress class
this ADR does not govern). Neither exclusion is enforced by taste: both are structural verifier
lines (§7.2 check (e)).

**Recursion guard.** An agent run carries `depth` and `chain` (the `Automation.Context` idiom).
An agent tool may not start another agent run at `depth > 0` in v1; the attempt is a bounded
`:depth_exceeded` tool error. This reuses the shipped loop-provenance fields rather than a new
mechanism.

**Context construction.** Tools receive a `%Samen.Automation.Context{}` — but its
`@enforce_keys` include `:workflow_id`, and an agent run is not a workflow. Rather than stuff a
run id into a field that means something else (a lie the Health surface would then render), the
struct gains one **optional, additive** field `:origin` (`{:workflow, id} | {:agent, run_id}`),
exactly as T40 added four optional fields without breaking any `%Context{}` match, and
`workflow_id` becomes nil-able **only** when `origin` is `{:agent, _}`. A single builder,
`Samen.AI.Agent.Context.build/2`, is the only site that constructs an agent-origin context.

### 5.2 · What reaches the LLM, and what does not

| EG2 artifact | route | scrub |
|---|---|---|
| tool **definitions** | `%MaskedPayload{tools: [...]}` (§4.2) | `safe_metadata?/1` — keys **and** values recursed, `vt_` scanned, charlist rendering scanned, structs refused |
| tool **call** the model emitted (kind + args), echoed next turn | `:history` binary via `ToolResult.render/2` | `safe_segment?/1` after §3.2a |
| tool **result** | `:history` binaries via `ToolResult.render/2`, after `PiiResolution` egress-mode resolution | `safe_segment?/1` after §3.2a |
| prior **assistant** text | `:history` binary | `safe_segment?/1` after §3.2a |
| the **goal** prompt | the versioned `Samen.AI.Prompt` resource (PII-scanned at write; may not contain `vt_`) | unchanged (EG1) |
| catalog **grounding** | `:grounding`, unchanged | `safe_metadata?/1`, D9 parity test unchanged |

Native provider tool-calling is supported without touching the `Samen.AI.Provider` behaviour:
`%Samen.AI.Completion{}` gains an **optional `:tool_calls` field (default `[]`)** — the struct's
field list was explicitly deferred to T64 in ADR-043 §11, so this is in-contract. An adapter that
supports native tool use maps the vendor response into that bounded field; an adapter that does
not leaves it empty and the agent falls back to parsing a bounded JSON envelope out of
`Completion.text` (the Prompt resource instructs the format). `tool_calls` is provider
**ingress**, so INV-7 does not govern its arrival — but its contents are untrusted model output
that becomes EG2 egress on the next turn's echo, which is why §4.3#6 exists.

### 5.3 · Mutating tools do not execute — they propose

ADR-043 §6.2 rules that AI outputs are drafts and proposals and that anything with side effects
goes through E3. This ADR **honors it unamended**:

- an `effect: :read` tool executes inline in the turn;
- an `effect: :write` tool **opens an approval** via `Samen.Approvals.Gate` —
  `kind_for(resource, action)`, `subject_ref = "samen:<abbrev>:<id>"`, `requested_by` = the
  **AI service principal** already shipped for the support operator (§6.3), which is a real,
  auditable identity that holds no reveal grants and is **denied the approve action by policy**;
- the run transitions to `:awaiting_approval` with a deadline and a non-nil `next_turn_at`;
- a human — never the requester, enforced at both the policy and `<abbrev>_distinct_party`
  DB-CHECK layers — approves, and `Gate.on_approve/2` re-invokes the action **as the requester,
  `authorize?: true`, inside the decision transaction**. Approval adds second-party consent,
  never privilege escalation. A handler error rolls the whole decision back: the approval stays
  `pending`, nothing executed;
- the approval handler resumes the run by clearing `next_turn_at` to `now` and enqueuing the
  next turn — inside that same transaction (the `EventCapture` idiom), so a resumed run exists
  iff the approval committed;
- rejection terminates the run `:rejected` with the honest outcome surfaced to the tenant.

Red path (the RP-AI-6 analog, and the batch A4 gate): **no path from an agent turn to a mutating
governed action without an approve event**, with the approve-then-execute positive control.

---

## 6 · Safety rails (design question C)

**Budgets — four, all fail-honest.** Per run: `max_turns` (default 8), `max_tool_calls`
(default 12), `max_input_tokens` / `max_output_tokens` (default 60k / 8k, summed from
`Completion.usage`), and `deadline_seconds` (default 600). Exhaustion of any budget is a
**terminal state `:budget_exhausted` with a bounded `error_kind`**, and the run's result is
`{:error, :budget_exhausted}`.

> **Never a partial answer.** The last assistant turn is **not** promoted to a result. The UI
> says "Stopped at the turn/token budget — this is not a partial answer." This is the ADR-014
> fail-honest contract applied to a new surface: a run that did not finish must not return a
> value that looks like it did. Sabotage §7.1#4 exists precisely to keep this refutable.

**Circuit breakers — two, both reusing shipped shapes.**
- *Rate trip*: the `Samen.Automation.Breaker` shape — count agent runs per org (and per agent
  definition) in a fixed window from the run log itself (no second counter), and past the
  configured threshold trip the **same operator kill action a human uses**, with reason
  `:rate_tripped`, idempotently, audited. Only ever trips; re-arming is explicit-operator-only.
- *Provider trip*: consecutive normalized provider errors past a threshold park the agent
  definition rather than burning budget across every tenant during an outage. Fail-honest: the
  run's error is `{:provider_error, provider}` (already content-free), never a fabricated answer.

**Kill-switch is re-checked at every turn, not at run start.** A run is long-lived; the
`Automation.RunWorker` "already-queued half" lesson (a run of a paused workflow finalizes
`:skipped`, never fires) generalizes: an operator kill or a tenant cancel between turn 3 and
turn 4 must stop turn 4. Sabotage §7.1#7 asserts it.

**Audit + turn log — token-only, matching the E4 pattern.** Per turn the run records exactly:
`turn_index`, `tool_kind`, **arg key names only** (never values), `status`, `error_kind` (closed
enum), `input_tokens`, `output_tokens`, `duration_ms`, `provider`, `simulated?`. This is
`RunRecord.bounded_outcomes/1`'s default-deny allowlist reused verbatim — `plain_map?/1` refuses
anything struct-shaped, so a Reactor error or an Exception can never be `inspect`ed into the log,
and `safe_error_kind/1` degrades an unknown kind rather than rejecting the finalize. The
`AuditEvent` line per run is likewise token-only: run id, agent name, turn count, terminal state,
token totals. **No prompt text, no tool arg values, no result text, ever.**

---

## 7 · Proof obligations (design question F)

### 7.1 · New sabotage patches (nine)

Each is a `scripts/sabotages/*.patch` with the house header (`SABOTAGE:` / `APP:` /
`TEST_FILES:` / `MUST_FAIL:`), applied → the named tests must FAIL → reverted → SHA-256
byte-exact. Listed with the invariant each keeps refutable.

| # | Sabotage | Named test must fail |
|---|---|---|
| 1 | tool-def scrub bypass — `seal/3` copies `:tools` into the payload without `scrub_metadata/1` | *a `vt_`/canary-bearing tool definition is REFUSED fail-closed* |
| 2 | tool-result raw re-entry — `ToolResult.render/2` returns the raw record/arg map instead of rendered binaries | *a raw tool result/arg map is REFUSED at the chokepoint (`:pii_egress_refused`)* |
| 3 | egress-mode drop — the renderer resolves without `egress: true` | *tool results re-enter MASKED (`••••`), never plaintext* |
| 4 | budget dishonesty — exhaustion promotes the last assistant turn to `{:ok, …}` | *budget exhaustion is fail-honest, never a partial answer* |
| 5 | allowlist escape — the tool resolver calls `Action.module_for/1` directly, skipping the four-way intersection | *an agent cannot call a tool outside its own definition / not opted in* |
| 6 | write-without-approval — an `effect: :write` tool executes inline | *no path from an agent turn to a mutating action without an approve event* |
| 7 | kill/cancel checked once — re-check moved from per-turn to run start | *a cancelled (or operator-killed) run executes no further turn* |
| 8 | turn-row idempotency removed — the executor creates a new turn row on replay | *a replayed turn does not re-execute its tool* |
| 9 | transcript masking twin — the agent LiveView renders the unresolved value | the MaskingCase red assertion (`assert_masked_dom!/2`) on the agent transcript surface |

Patch 2 is the direct descendant of the shipped `45-t65-ai-egress-scrub-shape-blind-tuple-hole`
(the EG2 tool-args tuple hole) and patch 3 of `44-d2-ai-egress-history-remask-bypass` (the
multi-turn re-scrub) — both existing patches are re-read at A3 to make sure the agent path does
not route around what they protect.

### 7.2 · Verifier additions

**`mix samen.verify.ai_prompt_masking` gains two structural checks** (it is the INV-7 gate; these
are INV-7 facts):

- **(d) tool-schema boundedness + staticness.** Every module exporting `tool_schema/0` returns a
  map whose leaves are binaries/atoms/numbers/booleans/lists/maps, contains no `vt_`, and is
  **compile-time constant** (no call into `Ash.read`, `Repo`, `Application.get_env`, or any
  function of tenant data — an AST check on the function body, the anti-bypass probe's technique).
- **(e) tool eligibility.** Every module exporting `tool_schema/0` also exports `effect/0`; every
  `effect: :write` tool is reachable only through `Samen.Approvals.Gate`; `"webhook"` and any
  analytics action are **not** opt-in eligible; every `Samen.AI.Agent` definition's `tools:` list
  is a subset of the opted-in registry.

**New: `mix samen.verify.agent_coverage`** (house shape — `run/1` →
`Samen.Verifier.halt_if_violations/2`, `violations/1` callable without halting; wired into
`ci.sh`, the `ci_sh.eex` template step list, and the generated-app gate). It asserts:

1. every registered agent module ships the mandated `AgentCase` red-path test files (the G26
   generator discipline, applied to agents);
2. every opted-in tool declares both callbacks and carries a per-tool test;
3. the agent-run resource carries a retention `:shred` spec (§7.4) — erasure reach is a coverage
   fact, not a hope;
4. **non-vacuity floor:** discovery must find ≥1 agent and ≥1 opted-in tool, else FAIL. The
   ADR-046 E7 lesson — *a gate that discovers nothing verifies nothing* — applied here.

*Placement note (operator decision §9#6):* checks 1–3 could have been folded into
`ai_prompt_masking`. Recommendation is a separate task, because `ai_prompt_masking` means "INV-7
holds structurally" and diluting it with DX-coverage assertions makes a failure of that gate
ambiguous — the thing a security gate must never be.

### 7.3 · Red-team + MaskingCase

**The permanent red-team tier (ADR-043 §10.2) gains an EG2 arm** in
`samen_core/test/ai_eval/ai_plane_redteam_test.exs`: a `describe "EG2 — tool definitions, tool
args, tool results"` block with, at minimum — a canary-seeded record fetched by `fetch_record`
and asserted `••••` in `Provider.Fake.sent_payloads/0`; a tool definition carrying a canary in a
description; a model-emitted tool arg carrying a `vt_*` token; a **multi-turn agent run under an
expired grant** (the §3.2a case, now on the agent path); a budget-exhaustion run asserted honest
under `CaptureLog` + attached telemetry (EG6); and an allowlist-escape attempt. Pass remains zero
canary plaintext and zero `vt_*` in **any** recorded payload, vector row, transcript row, log
line, telemetry event, or rendered error.

**MaskingCase three-proofs** ship for both new rendered surfaces (the tenant agent transcript
LiveView and the operator agent-health LiveView): tenant plane clear, operator-without-grant
`••••` with no `vt_*` in DOM/CSV/API, sabotage twin proving the assertion refutable
(`assert_leak_detected!/2`). The operator surface additionally asserts the **transcript is not
rendered at all** on the operator plane (§8/A5) — mask-by-omission, not mask-by-styling.

### 7.4 · Erasure — how agent transcripts and checkpoints are reached

An agent run holds three kinds of tenant data at rest:

1. **the goal / user free text** — tenant keystrokes, which the platform's own §3.2-step-2(d)
   rule treats as consented but which may still contain PII;
2. **the rendered transcript** — masked by construction (§4.3#3), so it carries no vault
   plaintext and no `vt_*`; but it may echo (1);
3. **the bounded turn log** — ids, enums, counts. No PII by allowlist.

**Decision:** (1) and (2) are stored in a **vault-routed attribute** on the agent-run resource —
`pii do vault(:pii_transcript); pii_attribute(:transcript, :string, vault: :pii_transcript);
reveal(:reveal_agent_run) end` — so they live **inside the DEK envelope**, keyed on the run row's
own id (the framework's per-row crypto-shred unit, `Samen.Vault.Change.resolve_subject_id/1`).
(3) stays a plain bounded jsonb column, like `Automation.Run.outcome`.

Consequences, stated honestly:

- **No new out-of-envelope residue.** `mix samen.verify.erasure_completeness`'s three discovery
  classes (derived-linkable `_bidx` columns, `pii_declared` bags, `storage_key` blobs) gain **no
  new member**, and no new named residual appears. A1/A2's gate obligation is to run that
  verifier before and after and show the residual list byte-identical.
- **Subject-level reach is by retention, exactly as for `Automation.Reminder`'s vaulted note.**
  A run's DEK is keyed on the run, not on the person the run discussed — the same posture every
  shipped domain row with a vaulted free-text field has. A **default retention `:shred` spec on
  the agent-run resource** (90 days, §9#4) is therefore shipped in A2 and wired into
  `default_specs` so `mix samen.gen.app` is complete by construction, closing the window rather
  than leaving it open indefinitely.
- **The "about-a-subject" boundary is the same one ADR-046 §7#5 names**, not a new one: free text
  a tenant typed *about* a third party is reached by the run's own retention shred, not by that
  third party's erasure. Recorded as a **carried-forward residual with an explicit pointer to
  ADR-046 §7#5**, so the two are ruled on together rather than drifting apart.

---

## 8 · Build plan — the BATON batch sequence

Ordered fix→verify batches, house shape: one deliverable per agent, fan-out concurrency 1,
**gate tasks run in the foreground (synchronous blocking Bash, never backgrounded-and-awaited)**.
Each batch ends with: its sabotages flip the named tests and revert byte-exact; suites +
`./ci.sh` green before and after; a phase commit in `git log --oneline -5` house style.
**Schema** = reserves abbrevs via `mix samen.abbrev.reserve` (driven by the generator — the
registry is never hand-edited), regenerates `schema.dict` via the sanctioned task, and runs the
FULL root gate. **Masking** = ships MaskingCase three-proofs.

| # | Batch | Scope | Schema? | Masking? | Sabotages / test obligations |
|---|---|---|---|---|---|
| **A1** | **The loop core, keyless, tool-free** | `Samen.AI.Agent` behaviour + `use` macro + validated `definition/0`; `Samen.AI.Agent.Run` resource (AshStateMachine: `queued → running → {succeeded, failed, cancelled, budget_exhausted}`) + turn rows; `Samen.AI.Provider.Scripted` (deterministic scripted turns, `simulated?/0 == true`, `%MaskedPayload{}` head-match); `Samen.AgentCase` in `samen_core/lib`; `:history` threading through `complete/4`; budgets; `cancel/2` | **yes** (2 resources + abbrevs) | no | S4 (budget honesty), S7 (cancel per-turn); tests: N-turn history accumulates and re-scrubs; max-turns terminates; **anti-vacuity** — every red assertion paired with a positive control |
| **A2** | **Durability, idempotency, breakers, erasure** | Oban worker + AshOban `:agent_turn_due` trigger (explicit `scheduler_cron`, pinned module names); never-nil `next_turn_at` watchdog; `{run_id, turn_index}` turn-row reuse; same-transaction launch enqueue; `Breaker`-shaped rate trip + provider trip; operator kill-switch; bounded turn log (`bounded_outcomes/1` reuse); **vault-routed transcript + default retention `:shred` spec** | **yes** (transcript vault route) | no | S8 (replayed turn double-executes); tests: crash-between-decision-and-execution replays without re-firing; nil-watchdog stall detected; `mix samen.verify.oban_queues` green; **`mix samen.verify.erasure_completeness` residual list byte-identical before/after** |
| **A3** | **The tool surface — read tools + EG2 scrubbing** | `tool_schema/0` + `effect/0` optional callbacks (defaults `:not_a_tool` / `:write`); two read actions (`search_records`, `fetch_record`) opted in; `%MaskedPayload{}` `:tools` field + `scrub_metadata` call + Inspect count-only; `%Completion{}` `:tool_calls` field; `Samen.AI.Agent.ToolResult.render/2`; arg parse → `validate/2` gate; four-way intersection resolver; `Automation.Context` `:origin` field + `Agent.Context.build/2` | no | **yes** (tool-result masking three-proof) | S1 (tool-def scrub bypass), S2 (raw re-entry), S3 (egress-mode drop), S5 (allowlist escape); re-read shipped sabotages 44 + 45 and confirm the agent path does not route around them |
| **A4** | **The write surface — propose-then-approve** | `effect: :write` routes to `Samen.Approvals.Gate`; run parks `:awaiting_approval` with deadline; approval handler resumes in-transaction; rejection terminates honestly; AI service principal reused as requester and denied approve by policy; depth/chain recursion guard | no | no | S6 (write-without-approval); **RP-AI-6 analog**: no path from an agent turn to a mutating action without an approve event, with the approve-then-execute positive control; requester ≠ approver proven at both layers |
| **A5** | **The surfaces — tenant + operator** | `Samen.Web.AI.AgentLive` (per-turn progress, transcript, approve/reject cards, cancel button); `Samen.Web.Operator.AgentHealthLive` (bounded turn log, kill/rearm — the `AutomationHealthLive` mirror); id-only PubSub envelopes + per-viewer re-read (the Chat/Notifications precedent); clause-per-outcome renderer extending `Samen.Web.AI.Components.ai_result/1` | no | **yes** (three-proof on both surfaces) | S9 (transcript masking twin); tests: operator plane renders **no transcript at all**; `:not_configured` renders `Samen.AI.configuration_hint/0` verbatim; `:budget_exhausted` renders the honest copy; SIMULATED badge driven by `Completion.simulated`, never parsed from text |
| **A6** | **The v1 vertical slice — driftwood support triage, ≈0-LOC** | `samen_agent_routes` router macro; a ~5-line `Driftwood.Support.TriageAgent`; also mounts `samen_ai_routes` (today **no vertical mounts it** — the AI kit has a seam with no adoption proof; close that gap here); dogfood evidence recorded | no | no | leverage guard: authored vertical LOC ≤ ~10; end-to-end proof — multi-turn + read tool + masked person fields + a write proposal + approval + budget, all keyless under `Provider.Scripted` |
| **A7** | **The gates** | `mix samen.verify.agent_coverage` (+ non-vacuity floor); `ai_prompt_masking` checks (d) + (e); the EG2 `describe` arm on the permanent red-team tier; `mix samen.gen.agent` + its templates + a `gen_agent_probe.exs` wrapped by `ci.sh`'s `run_gen_probe` (byte-exact abbrev-registry restore, SIGINT-safe) | no | no | **Lands LAST** — it asserts what A1–A6 built. Sabotage: remove any one coverage assertion → the named gate test flips. Verifier tests drive the true exit code via `System.cmd/3` (house discipline) |

**Rationale for the order.** A1 proves the loop is real and honest before anything can fire a
side effect. A2 makes it survive a restart *before* tools exist, so idempotency is designed
rather than retrofitted. A3 opens the EG2 surface with **read-only** tools, so the first
tool-shaped egress carries no write risk. A4 adds writes only once the approval seam is the only
door. A5 is UX on a mechanism that is already correct. A6 proves ≈0-LOC adoption end to end.
A7 lands last, ADR-046 E7's shape, because a coverage gate that runs before the thing it covers
exists can only be vacuous.

**Estimated authored scope (non-test).** A1 ≈ 500 · A2 ≈ 350 · A3 ≈ 400 · A4 ≈ 200 · A5 ≈ 450 ·
A6 ≈ 100 (of which ~10 in driftwood) · A7 ≈ 450. **≈ 2,450 LOC core**, plus roughly the same
again in tests, plus 9 sabotage patches. The dynamic-step-selection core the Jido report sized at
150–300 LOC is real and is inside A1 — the rest is durability, EG2 governance, proof, and
honesty, which is the part that cannot be bought from a dependency.

---

## 9 · Decisions for the operator

All seven were **ratified by the operator on 2026-08-14, each exactly as recommended**, and are
marked **TAKEN** below (the ADR-046 §7 convention). The ADR's **Status stays PROPOSED until A7
lands** (the batch plan is the implementation; the ratification unblocks A1).

| # | Decision | Options | Recommendation | Taken |
|---|---|---|---|---|
| **1** | **Autonomous writes.** May an agent execute a mutating tool without a human approve? This would **amend ADR-043 §6.2** ("AI writes do not exist … anything with side effects goes through E3"). | (a) **propose-then-approve for every mutating tool** (§6.2 unamended) · (b) autonomous-with-audit for a bounded low-risk subset (e.g. `add_tag`) behind a per-agent `autonomous_writes:` opt-in · (c) fully autonomous with audit | **(a).** ADR-043 §6.2 is a shipped ruling with a DB-CHECK behind it; an agent is exactly the actor it was written for. (b) is a coherent v2 once A1–A7 have a green red-team and real usage data, and the design leaves room for it (`effect/0` already classes the tools); taking it now would mean the first autonomous AI write in the platform ships in the same batch as the loop that decides it. | **TAKEN — (a)**: every mutating tool is propose-then-approve; ADR-043 §6.2 holds **unamended** (binds A4). |
| **2** | **Grant plaintext in agent runs.** May a live reveal grant + `grant_plaintext_egress: true` admit plaintext into an agent run? | (a) **never — agent runs are masked-only** · (b) admit it, and persist the transcript with the `{:grant_span, …}` tag · (c) admit it only for runs that never persist (in-memory batch) | **(a).** The transcript persists, and INV-7 §7.2 is categorical that grants never apply to persisted egress. (b) puts grant plaintext at rest, contradicting §7.2. (c) makes masking depend on whether a run happened to be resumed — the worst property an invariant can have. **Product cost, named:** an agent answers about PII-bearing fields shape-only, always. | **TAKEN — (a)**: never — agent runs are masked-only on every plane, `grant_egress?: false` at every `complete/4` call (§4.4; binds A1+). |
| **3** | **Default budgets / cost posture.** | as proposed · tighter · looser · per-org overrides only | **PROPOSED defaults:** `max_turns 8`, `max_tool_calls 12`, `max_input_tokens 60_000`, `max_output_tokens 8_000`, `deadline_seconds 600`, rate trip 60 runs/org/hour. All host-configurable. The **floor** — exhaustion is fail-honest and never a partial answer — is not configurable and is not an operator decision. | **TAKEN — as proposed**: `max_turns 8` / `max_tool_calls 12` / `max_input_tokens 60_000` / `max_output_tokens 8_000` / `deadline_seconds 600` / rate trip 60 runs/org/hour, all host-configurable; the fail-honest floor is **non-configurable** (binds A1's budget engine, A2's breaker). |
| **4** | **Transcript retention window.** How long does a vault-routed agent transcript live before the default `:shred` retention spec destroys its DEK? | 30 · **90** · 365 days · never (keep until account erasure) | **90 days.** Long enough for support and dispute review, short enough that a run's echoed free text is not an indefinite liability. Shipped as a `default_specs` entry so `mix samen.gen.app` is complete by construction; hosts may lengthen or shorten. | **TAKEN — 90 days**, in the DEK envelope, shipped as a `default_specs` `:shred` entry (binds A2). |
| **5** | **Token streaming.** Should turns stream provider deltas to the LiveView? | ship in v1 · **defer to v2, named** | **Defer, named.** Streaming is a *second* provider egress surface with its own EG6 shadow: partial deltas would bypass `seal/3`'s whole-payload scrub unless the chokepoint grows a streaming contract, which is a separate ADR. v1 streams **turn-level progress** (id-only PubSub + per-viewer re-read), which is the honest and useful 80%. Recorded as a residual, not silently dropped. | **TAKEN — deferred to v2, named**: v1 streams turn-level progress only; token streaming needs its own chokepoint contract (a future ADR). Carried as a named residual (§11). |
| **6** | **Verifier placement.** Do the agent-coverage assertions live in `ai_prompt_masking` or a new task? | fold in · **new `samen.verify.agent_coverage`** | **New task.** `ai_prompt_masking` means "INV-7 holds structurally"; mixing DX-coverage assertions into it makes a red gate ambiguous. The two genuinely-INV-7 checks (tool-schema boundedness, tool eligibility) *do* go into `ai_prompt_masking` — that split is the point. | **TAKEN — new `mix samen.verify.agent_coverage`**; the two INV-7 checks (d)/(e) go into `ai_prompt_masking` (binds A7). |
| **7** | **The v1 slice.** Which single feature proves the whole chain? | **driftwood support triage agent** · a pawchart vet-record agent · a demo-only agent · a CRM next-step agent | **Driftwood support triage.** It exercises every link in one run: multi-turn planning, a read tool over vault-routed Person fields (masking is *load-bearing*, not incidental), a write proposal through the approval Gate, budget exhaustion on a hard case, and the operator health surface. It also closes a real gap — **`samen_ai_routes` is currently mounted by no vertical**, so the AI kit has a mount seam with no adoption proof. A demo-only agent would prove the loop but not the ≈0-LOC leverage guard. | **TAKEN — driftwood support triage** (binds A6, which also mounts `samen_ai_routes` in a vertical for the first time). |

---

## 10 · Deferred sub-decisions (explicit, with owners)

| deferred | to |
|---|---|
| `Samen.AI.Agent.Run` field list beyond `{state, current_turn, next_turn_at, budgets, origin, depth, chain}`; the `use Samen.AI.Agent` macro's exact compile-time verifier set | A1 |
| `@turns_per_job` tuning; watchdog interval; the provider-trip threshold | A2 |
| the `tool_schema/0` map's exact spelling; the text-envelope fallback grammar; `fetch_record`'s field-projection rule beyond "catalog-declared + condition-eligible" | A3 |
| ~~the approval `kind` naming for agent-proposed actions; the deadline default~~ — **decided at A4**: ONE registered kind `"ai_agent_write"` (`Samen.AI.Agent.WriteProposal.kind/0`), tenant plane; deadline default **24h**, host-configurable via `config :samen_core, Samen.AI.Agent.WriteProposal, deadline_seconds:` | A4 |
| the per-turn progress copy; the operator health columns | A5 |
| the driftwood goal prompt's content (a versioned `Samen.AI.Prompt` row) | A6 |
| `samen.gen.agent`'s switch set and emitted test files | A7 |

Nothing in §4 (the scrub points), §5.3 (propose-then-approve), §6 (fail-honest budgets), or §7
(the proof obligations) is deferrable.

### §10a · A2 implementation deviations (consolidated record, written at A3)

The A2 verifier found five places where the shipped A2 diverges from this ADR's letter. Each is
recorded here with its justification; **none weakens a §9 ratified decision** — the fail-honest
floor, masked-only agent runs, the ratified budgets/retention, and the §4/§6/§7 non-deferrables
are untouched by all five.

| # | Deviation | ADR letter | As shipped | Justification |
|---|---|---|---|---|
| 1 | **`bounded_meta/1` naming.** | §6 says the turn log reuses "`RunRecord.bounded_outcomes/1` verbatim". | `Samen.AI.Agent.bounded_meta/1` — a NEW function in the same default-deny posture (plain string-keyed scalar maps only; structs/rich terms dropped, never `inspect`-ed; degrade, never reject). | `bounded_outcomes/1` is coupled to the Automation Run outcome shape (`status`/`error_kind` envelope), not a generic map filter; importing it would have meant exporting a RunRecord internal for a foreign row type. The POSTURE is reused verbatim; the function is the turn log's own. Proven non-vacuous by the A2 jsonb red-path tests. |
| 2 | **Erasure-gate output line.** | §7.4 / A2's gate obligation: `mix samen.verify.erasure_completeness` residual list "byte-identical before/after". | The verifier's output gained a line: A2 ADDED a transcript arm to the completeness discovery (the vault-routed `arn` transcript + its 90-day retention spec is now a discovered, asserted class — sabotage 245 flips when the arm is dropped). The pre-existing residual entries are unchanged. | "Byte-identical" was written assuming A2 adds no discovery; the stricter reading — the gate must now SEE the transcript, or removing its retention arm would be silent — is the one that keeps RP-AG-11 real. A weaker, unchanged gate would have been the actual violation. No new out-of-envelope residue and no new named residual (§7.4's real obligation) holds. |
| 3 | **Four sabotages, not one.** | The §8 A2 row lists "S8 (replayed turn double-executes)". | A2 shipped FOUR patches: 242 (S8 replay reuse), 243 (never-nil watchdog dropped), 244 (kill-switch re-check dropped), 245 (erasure transcript arm dropped). | Strictly additive proof surface: §7.1's table lists kill-recheck (S7) and the watchdog/erasure invariants as obligations of the batches that ship them; A2 shipped those mechanisms, so it shipped their refutations rather than deferring them to a later batch that would not be editing this code. More refutation, same invariants. |
| 4 | **`Provider.Scripted` state in `:persistent_term`.** | The A1 design described a process-local scripted double. | Script + recording live in `:persistent_term` (cross-process; agent suites run `async: false` + `reset/0`). | A2's Oban worker executes turns in whatever process runs the job (drain, watchdog replay, crash-simulation Task); a process-local script would make the worker path fail `{:error, :not_configured}` for scripted work — a dishonestly-honest double. The fail-honest floor (no script ⇒ never `{:ok, _}`) is unchanged. Flagged by A1, required by A2, kept at A3 (the tool-turn worker parity test depends on it). |
| 5 | **`:fail` (and `:cancel`) transition from `:queued`.** | §8/A1 sketches `queued → running → {terminals}`. | The state machine admits `:fail` and `:cancel` from `:queued` as well as `:running`. | A durable `:queued` run can die before its first turn (agent unresolvable, owner gone, transcript shredded mid-queue, tenant cancel before the worker picks up). Without `queued → failed/cancelled`, those runs could either stall forever (violating the never-nil watchdog's *purpose*) or be forced through a fake `:running` hop (a lie in the audit trail). `:exhaust` remains `:running`-only — a queued run cannot exhaust a budget it never spent. |

#### A4 implementation deviations (rows 6–10, written at A4)

Numbering continues the table above. **None weakens a §9 ratified decision** — propose-then-approve
(§9#1) is honoured *more* strictly than the letter, masked-only runs (§9#2), the ratified budgets
and the non-configurable fail-honest floor (§9#3), and the 90-day retention (§9#4) are untouched.

| # | Deviation | ADR letter | As shipped | Justification |
|---|---|---|---|---|
| 6 | **E3 Face 1, not `Samen.Approvals.Gate`.** | §5.3: an `effect: :write` tool "opens an approval via `Samen.Approvals.Gate` — `kind_for(resource, action)`, `subject_ref = "samen:<abbrev>:<id>"`". | A Face-1 handler registered by kind, `Samen.AI.Agent.WriteProposal` (`kind: "ai_agent_write"`, `subject_ref: "samen:atn:<turn_id>"`), the shape ADR-043 §6.3 / T70's `ReplyHandler` already uses. | `Samen.Approvals.Gate` is the **Face-2 change** for *a bounded Ash transition on an existing record with no arguments beyond the record itself* (its own moduledoc, ADR-040 §4.4). An agent tool call is neither: it is a `Samen.Automation.Action` invoked with model-chosen args. §5.3 is written in ADR-040 §4's vocabulary; the mechanism it *describes* — open, park, distinct human decides, execute inside the decision transaction, roll everything back on handler error — is the Face-1 contract verbatim, reused at ≈0 new engine LOC. `Gate` itself is untouched, so T34's "runs as requester, not approver" property is not weakened. `kind_for/2` is still the right spelling for a gated Ash transition; it is not the right spelling for this. |
| 7 | **Execution carries the APPROVER's authority, not the requester's.** | §5.3: on approve the Gate "re-invokes the action **as the requester**, `authorize?: true`" (ADR-040 §4.4's rule). | `execute_approved/3` builds the executing principal from `ctx.actor` — the **DECIDING** party (the `Samen.Approvals.Handler` contract's own definition of `ctx.actor`). A third layer refuses the AI principal as the executing actor even at that seam directly. | On this path the requester is the **AI service principal**, so executing "as the requester" would mean an agent causing a governed mutation to execute *with AI authority* — exactly what **ADR-043 §6.2** ("AI writes do not exist") forbids, §9#1 ratified unamended, and §5.3 itself cites as binding. It is also not what the shipped §6.3 precedent does: `ReplyHandler` does not send as the AI principal either. ADR-040's "requester, not approver" rule exists so an approver cannot **escalate a human requester** beyond their own envelope; it is not a licence to grant a machine principal write authority. Net effect: the AI principal holds no write authority anywhere, and every agent-caused mutation is attributable to the human who consented to it. Kept refutable by sabotage 250. |
| 8 | **A NEW `assign_record_owner` write action, rather than opting in one of the 8.** | §5.1 treats the 8 ADR-039 kinds as the write set; §9#1 names `add_tag` as an example low-risk write. | `Samen.Automation.Actions.AssignRecordOwner` added to the SAME registry, `effect: :write`, opted in. All 8 ADR-039 kinds stay `:not_a_tool`. | The 8 target the fire-time SUBJECT supplied by a workflow trigger (`ctx.resource_key`/`ctx.record_id`); an agent has no trigger subject — it discovers a record via `search_records`/`fetch_record` and names it in the CALL. Retrofitting the agent arg shape onto `assign_owner`'s `validate/2` would widen a validator the Workflow changeset also uses. **A3 set the precedent** by adding read actions rather than retrofitting; this follows it, into the one registry, never a forked allowlist. The kind chosen is the one §1's driving example asks for ("…and who should own it?"). |
| 9 | **The tool-result renderer elides `vt_`-bearing scalars (per value).** | A3 shipped the renderer NOT scanning for the sentinel, leaning entirely on the chokepoint's whole-payload refusal. | `Samen.AI.Agent.ToolResult` renders a sentinel-bearing scalar (or key) as the bounded `[unrenderable:<key>]` marker, the same exit every other unrenderable value takes. | Recorded as a **correction of an A3 divergence, not a new deviation**: §4.3 step 2 makes `[unrenderable:<field>]` the renderer's general answer to a value it cannot safely emit, step 3 asserts as a property that the transcript "contains no vault plaintext and **no `vt_*` token**", and #6 says the echo is "rendered to a single **`vt_`-free** binary". A3 satisfied none of the three. The A3 verifier also named the consequence: attacker-controlled data in an eligible column hard-failed every agent run touching that record — a tenant DoS. The chokepoint allowlist is unchanged and still refuses any `vt_`-bearing segment (§4.3#5 belt-and-braces, sabotage 247 unaffected); only the normal path stopped routing tenant data through the emergency exit. Sabotage 255. |
| 10 | **Budget + interrupt spellings the ADR leaves open on the write path.** | §6 sets `max_tool_calls` but does not say whether a PROPOSAL bills; §5.3 does not say what a tenant cancel does to a parked run. | A proposal bills **no** tool call (nothing executed) and does **not** advance the turn cursor; the approved EXECUTION bills exactly 1 and advances 1. `Samen.AI.Agent.cancel/2` on a parked run WITHDRAWS the pending approval (`Samen.Approvals.cancel/3` — the requester's own withdrawal, `decided_by` stays NULL) and terminates the run `:cancelled`. | The billing rule is A3's shipped `executed?` semantics applied unchanged ("the counter counts governed executions, not attempts" — the A3 verifier's C7 finding), so a rejected proposal costs a tenant nothing. Not advancing the cursor keeps the `{run_id, turn_index}` row `:proposed`, which is what makes it the idempotency key the approved execution finalizes — a proposal can never double-execute and a park can never be mistaken for a completed turn. The cancel behaviour exists because a parked run has no loop to honour the durable flag at a turn boundary, and leaving a pending approval alive after the tenant withdrew would be a standing invitation to execute a withdrawn write. |

---

## 11 · Consequences

**Positive.** ADR-043's EG2 class stops being a declaration with no implementation, and
`:history`'s per-turn re-scrub — shipped in T65 explicitly for multi-turn loops — finally has a
caller, so sabotage 44 stops being a proof about a hypothetical. The loop lands entirely inside
the AST anti-bypass probe's and the sabotage harness's coverage, which is the property the Jido
evaluation identified as the decisive one. Zero new dependencies; Reactor, AshOban,
AshStateMachine, Oban, and PubSub are reused where they already fit and deliberately *not* reused
where they do not (Reactor cannot express dynamic step selection; it still runs the tool). The
tool allowlist narrows four ways from an already-governed registry, so "what can the model do?"
has a structural answer, not a policy answer. Agent transcripts land inside the DEK envelope with
a default retention shred, so ADR-046's gate is unaffected. And the v1 slice closes a real
adoption gap (`samen_ai_routes` mounted by nobody).

**Negative / accepted.**
- **Masked-only agent runs (§9#2)** are a real quality sacrifice: an agent reasoning about a
  shipment cannot see the contact's name or email, ever. Named plainly rather than hedged.
- **Propose-then-approve (§9#1)** means an agent cannot complete a task unattended. That is the
  intended posture today; it is also the thing most likely to be revisited first.
- **~2,450 authored LOC plus tests and nine sabotages** is a genuine build, not a weekend. The
  ADR states both the 250-LOC core and the full number so no one is surprised at A3.
- **First interrupt semantics in the codebase.** Cancel is at the **turn boundary**, not
  mid-provider-call: an in-flight tool completes. The UI must say "stopping after the current
  step," not "stopped." Overclaiming here would be exactly the kind of lie the fail-honest
  contract exists to prevent.
- **At-least-once, never exactly-once.** Stated in the moduledoc as Sequences states it. The
  turn row makes double-execution not-happen in practice; it is not a mathematical guarantee.
- **No token streaming in v1** (§9#5) — the honest reason is that streaming needs its own
  chokepoint contract, not that it was forgotten.
- **Free text about a third party** in a goal prompt is reached by the run's own retention shred,
  not by that third party's erasure — the same boundary ADR-046 §7#5 carries open. Pointed at
  explicitly so the two are ruled on together.

**Neutral.** The chokepoint's pipeline, the provider behaviour's two callbacks, the D9 grounding
parity contract, the 8 governed actions' existing behavior, the approvals engine, the erasure
completeness discovery classes, and the abbrev registry's hands-off discipline are all consumed
unchanged. `%MaskedPayload{}` gains one field and `%Completion{}` gains one field — both minted
only by the chokepoint / adapters, both in-contract per ADR-043 §11's deferred-fields note.

---

## 12 · Red paths / verification (the agent-loop adversarial floor)

- **RP-AG-1 (tool-def egress):** a canary/`vt_`-bearing tool definition is refused
  `{:error, :pii_egress_refused}`; sabotage 1 proves refutable.
- **RP-AG-2 (tool-result re-entry):** a tool result carrying a vault-routed field re-enters as
  `••••`, never plaintext, never `vt_*`; sabotages 2 + 3 prove refutable from both directions
  (renderer shape, resolution mode).
- **RP-AG-3 (multi-turn re-scrub on the agent path):** the §3.2a case, now with a real caller —
  and vacuous **by construction** for agent runs because §4.4 excludes grant spans entirely;
  asserted as a property (`no {:grant_span, …} is ever persisted or passed by the agent`), not
  assumed.
- **RP-AG-4 (allowlist escape):** an agent cannot call a registry action it did not declare, did
  not opt in, or its actor cannot authorize; four separate red tests, one per intersection arm,
  each with a positive control.
- **RP-AG-5 (write-never-executes):** no path from an agent turn to a mutating governed action
  without an approve event by a distinct human; approve-then-execute positive control.
- **RP-AG-6 (budget honesty):** exhaustion returns `{:error, :budget_exhausted}` and the last
  assistant turn is not promoted; the rendered surface says so.
- **RP-AG-7 (idempotent tools):** a replayed turn reuses its turn row and does not re-fire.
- **RP-AG-8 (interrupt):** a cancelled or operator-killed run executes no further turn; the
  in-flight turn is allowed to finish and is recorded honestly.
- **RP-AG-9 (EG6 on the agent path):** a forced tool failure, provider failure, and refusal
  produce error terms, log lines, and telemetry events containing no prompt text, no tool arg
  values, no result text, no canary, no `vt_*`.
- **RP-AG-10 (org isolation):** a tool executed in org A returns nothing for org B's records,
  with the same-org positive control (OrgScope FilterCheck — foreign rows do not exist).
- **RP-AG-11 (erasure non-regression):** `mix samen.verify.erasure_completeness`'s discovered
  residue set and named-residual list are byte-identical before and after A2.

---

## 13 · References

- `_orch/jido-eval-report.md` §2.3 / §4 — the EG2 gap finding and the "build it first-party"
  remedy this ADR executes; §2.1's five obstacles are the design constraints §4–§5 answer.
- **ADR-043** §3.1 (EG1–EG6 + INV-7), §3.2 (the pipeline), **§3.2a** (per-turn history
  re-scrub — the mechanism this ADR finally calls), §3.2b (EG6), §5.1–§5.3 (the kernel + provider
  behaviour + ≈0-LOC adoption), §6.1 (masked-by-default + `grant_plaintext_egress`), **§6.2**
  (AI writes do not exist — binding, unamended), §6.3 (the AI service principal reused in A4),
  §7.2 (grants never unlock persisted egress), §10 (the permanent red-team tier), §11 (deferred
  `Completion` fields).
- **ADR-039** — `Automation.Action` + the 8 kinds, `Compile` → `Reactor.Builder`, `RunWorker`
  (kill-switch re-check, owner resolution, defensive `extract_failure/1`), `RunRecord`
  (`bounded_outcomes/1`, `dispatch_key`), `Health`/`Breaker`, `EventCapture` (same-transaction
  enqueue), `Context` (the `:origin` field extends it additively).
- **ADR-040 §4** — `Samen.Approvals` + `Samen.Approvals.Gate` (`kind_for/2`, `on_approve/2`
  re-invocation as the requester with `authorize?: true`), requester ≠ approver at policy + DB
  CHECK.
- **ADR-046** — the erasure-completeness gate whose discovery classes §7.4 must leave unchanged;
  **§7#5** — the open "about-a-subject" operator decision this ADR's transcript boundary points at.
- **ADR-014 / 024 / 026** — fail-honest; **ADR-037 §5.6/§5.7/§5.8/§5.9** — ash_ai REJECT, Reactor
  / AshStateMachine / AshOban ADOPT; **ADR-042** — value-layer masking, the client never resolves;
  **ADR-027** — the tsvector baseline `search_records` composes with.
- Mirrored constructions: `Samen.Sequences` (never-nil watchdog, row-reuse idempotency,
  fail-honest outcome resolution, single retry authority), `Samen.AI.Chokepoint`
  (`safe_segment?/1`, `safe_metadata?/1`, `render_value/1`, `rescrub_history/2`),
  `Samen.Automation.RunRecord.bounded_outcomes/1`, `Samen.MaskingCase`, `Samen.RedPath`,
  `Samen.AI.Provider.Fake` (`sent_payloads/0`), `Samen.Web.AI.Components.ai_result/1`,
  `Samen.Web.Chat.PubSub` (id-only envelope + per-viewer re-read).
- Existing sabotages this ADR extends: `44-d2-ai-egress-history-remask-bypass`,
  `45-t65-ai-egress-scrub-shape-blind-tuple-hole`.
