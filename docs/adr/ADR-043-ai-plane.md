# ADR-043 — The AI plane: the no-PII-egress chokepoint, keyless kernel, provider packages, embeddings, MCP, and eval posture (WS-D D1–D9)

- **Status:** Accepted (design; T64–T72 implement).
- **Date:** 2026-08-03
- **Task:** T63 — the WS-D architecture ADR (`blocked_by: [T62]`). Doc-only per the
  standing decompose-cross-cutting-changes rule; the nine Phase-5 build tasks below
  consume it as their binding contract.
- **Deciders:** the operator, via three recorded rulings — **M3** (pgvector REQUIRED,
  no optional-by-detection), **M9** (keyless CI: deterministic fake provider;
  `SAMEN_AI_LIVE=1` live lane; claim-evidence records which lane ran), **c4** (MCP =
  HTTP + SSE in samen_web, per-operator tokens, no stdio in prod) — plus the standing
  keyless/fail-honest ruling (2026-08-03): the AI plane is keyless by default and every
  adapter is fail-honest per ADR-014/024/026. Recorded by fable.
- **Consumes (binding inputs):**
  - **ADR-037 §5.6 — ash_ai REJECT** for the D1/D2 kernel (dependency shape puts
    `req_llm` vendor clients into core, against INV-4; no chokepoint concept; `load:`
    reaches private attributes). Its three binding notes are honored verbatim here:
    (a) mine `AshAi.Mcp` (protocol 2025-03-26, router shape, api-key plug seam) as the
    T69 reference; (b) adopt its pgvector shape (vector columns on the resource,
    oban-strategy async embedding, HNSW via `custom_statements`) for T67, consistent
    with ash_oban ADOPT (§5.9); (c) re-evaluate ash_ai post-1.0 once samen's chokepoint
    exists. **The kernel is therefore hand-built.**
  - spec §WS-D D1–D9 (Intelligence column, elements 101–108); INV-1..INV-6.
  - ADR-014/024/026 — the fail-honest adapter contract.
  - ADR-040 §4 — the E3 approvals engine (`Samen.Approvals`, Gate face,
    requester≠approver by policy + DB CHECK).
  - ADR-038 §4.3 / T28 — `Samen.Delivery.Chokepoint`, the single send path.
  - ADR-042 — the plane/client model (masking resolved server-side through
    `Samen.Api.PiiResolution`; the client/agent never resolves).
  - The shipped chokepoint precedents this ADR mirrors: `Samen.Type.VaultField`
    (last-line `dump_to_native` refusal), `Samen.Pii.WriteGuard` / `Samen.Vault.Change`
    (governed-write injection), `Samen.Files.upload/3` + `Samen.Files.ChokepointGuard`
    (private-context marker, structural refusal of ungoverned writes),
    `Samen.Chokepoint` (single-decrypt structural scanner), `Samen.Policy.OrgScope`
    (FilterCheck, fail-closed on org-less actors).
- **Binds (implementing tasks):** T64 (§5 kernel + samen_anthropic) · T65 (§3
  chokepoint + `ai_prompt_masking` verifier) · T66 (§8 runtime catalog grounding) ·
  T67 (§7 embeddings + pgvector) · T68 (§7.5 Prompt resource + six verbs) · T69 (§9
  MCP server) · T70 (§6.3 support operator) · T71 (§6.4 CRM + analytics) · T72 (§10
  eval + red-team tier).

---

## 1 · Context

The catalog, the verifiers, and the two-plane masking spine were built "for LLMs" —
and nothing consumes an LLM at runtime. WS-D closes the Intelligence column with the
claim the whole platform was designed to earn: **an AI operator that structurally
cannot leak PII** — token-blind by construction, not by policy.

Everything the AI plane needs already exists as shipped, adversarially-gated
substrate: values resolve per-plane through `Samen.Api.PiiResolution` (tenant-clear /
operator-absent / impersonation-masked-but-present / nil-plane-masked, fail-safe);
`%Samen.Masked{}` carries a token and never plaintext, rendering `••••` through every
serialization protocol; `Samen.Type.VaultField.dump_to_native/2` refuses raw plaintext
at the column boundary; `Samen.Files.ChokepointGuard` proves the
private-context-marker pattern for structurally refusing ungoverned paths;
`Samen.Delivery.Chokepoint` proves the single-egress-module pattern with an
anti-bypass grep probe; `Samen.Approvals` provides two-party consent with
requester≠approver enforced twice (policy + DB CHECK); `mix samen.catalog.dump`
already emits a complete, PII-flagged, byte-stable grounding artifact.

What does NOT exist is any AI egress — and egress is a **new trust boundary**. The UI
renders to the data owner; an AI call transmits to a third-party model provider. A
prompt, a tool argument, an embedding, an MCP payload each leave the governed process.
Worse, one of them **persists**: a vector embedded from plaintext outlives any reveal
grant and survives in a queryable, invertible form. INV-1 already anticipates this —
its text names "AI call" explicitly: *no … AI call may render or transmit plaintext
PII without a reveal grant*. This ADR turns that clause into a construction, an
invariant (INV-7), a verifier tier, and a permanent red-team gate.

Naming note: `Samen.Chokepoint` (the decrypt scanner), `Samen.Delivery.Chokepoint`,
and `Samen.Files.ChokepointGuard` establish the convention `Samen.<Domain>.Chokepoint`
for a runtime single-path module. **`Samen.AI.Chokepoint`** fits it and collides with
nothing (grep-verified).

## 2 · Decision

Build the AI plane hand-rolled on the shipped masking substrate (per ADR-037 §5.6),
with eight load-bearing decisions:

1. **One egress chokepoint, fail-closed, enforced by construction** (§3): every
   provider-bound byte — completion prompts, tool args, embedding inputs, MCP
   payloads, grounding context, plus their log/telemetry/error shadow (EG6) —
   passes through (or is governed by) `Samen.AI.Chokepoint`, which resolves values
   per-plane, re-scrubs conversation history per-turn (§3.2a), refuses `vt_*` tokens
   and unresolved vault fields, and seals the result in a
   `%Samen.AI.MaskedPayload{}` that is the ONLY value the provider boundary's
   function clauses accept at runtime (§3.2 — a runtime-clause + structural-probe
   guarantee, not a compile-time one). **INV-7 (no-PII-egress)** is defined in §3.1
   and binds every WS-D task.
2. **Keyless by default, fail-honest always** (§4): the plane builds, gates, and
   red-teams with zero API keys. An unconfigured adapter returns
   `{:error, :not_configured}` — never a canned `{:ok, _}`. A real key is a documented
   host opt-in (`SAMEN_AI_LIVE=1` for the live eval lane) that introduces the external
   dependency and its cost.
3. **`Samen.AI` kernel in core; providers as separate packages** (§5): a two-callback
   `Samen.AI.Provider` behaviour, `samen_anthropic` as the reference package
   (INV-4 — core stays vendor-free), provider resolution mirroring
   `Samen.Delivery.Chokepoint.decide/3`, and ≈0-LOC vertical adoption.
4. **AI is a policy consumer, never a plane** (§6): every AI call executes as the
   calling actor's real scope through OrgScope + PiiResolution; egress is
   masked-by-default on EVERY plane (stricter than the tenant UI — §6.1); the ONE
   permitted plaintext egress (grant-covered completions, which reach the
   third-party provider) is a host opt-in defaulting OFF (§6.1); the support
   operator drafts on the operator plane and sends only through an E3 approval decided
   by a human who is never the requester.
5. **Embeddings are catalog-allowlisted non-PII text only; pgvector is REQUIRED**
   (§7, per M3): vault-routed values never enter vector space — not even under a
   reveal grant; vectors are org-scoped rows behind OrgScope.
6. **The eight intelligence verbs run through the chokepoint** (§7.5): Search (T67) +
   Prompt-as-versioned-resource + Summarize/Extract/Classify/Generate/Recommend/
   Analyze (T68), all org-scoped, masked-path, provider-blind.
7. **MCP is a governed, grant-gated window, not a write path** (§9, per c4 +
   ADR-037 §5.6(a)): HTTP+SSE in samen_web, per-operator tokens, masked browsing,
   action *proposals* that open T34 approvals and never execute directly.
8. **The mask-leak red-team is a permanent CI tier — observing logs/telemetry as
   well as payloads — and the keyless grounding-eval pass bar is ≥90%** (§10):
   deterministic under the fake provider, honestly framed as a context-assembly bar
   (model fidelity is the `SAMEN_AI_LIVE=1` lane); T72 cites this number and never
   picks its own.

## 3 · INV-7 and the masking chokepoint (D2 — binds T65; constrains T64–T72)

### 3.1 · The invariant

> **INV-7 — no-PII-egress.** No vault-routed value — plaintext or `vt_*` token —
> reaches any AI egress (a provider payload, an embedding input, a vector row, an MCP
> response, an eval fixture, or any log/telemetry/error emission arising from an AI
> call), with exactly **one deliberately-permitted exception**: plaintext covered by
> a **live reveal grant** for that subject + label in the calling actor's scope MAY
> enter an **ephemeral completion payload** — and that payload is transmitted to the
> configured **third-party model provider**, so the exception is additionally gated
> by an explicit host opt-in (`grant_plaintext_egress`, **default off** — §6.1).
> Grant-covered plaintext is never permitted in any persisted egress (embeddings,
> vectors, MCP resources, committed fixtures) nor in any log/telemetry/error
> emission (EG6), and prior-turn plaintext re-masks when the grant lapses (§3.2a).
>
> Testable form (the D1 contract, verbatim): **no string reaches a provider client
> except through `Samen.AI.Chokepoint`**; and the chokepoint refuses `vt_*` tokens
> and unresolved vault fields **fail-closed**.

The five egress classes INV-7 governs, enumerated so no path is "forgotten":

| class | egress | route |
|---|---|---|
| EG1 | completion prompts (system + grounding + context + user segments) | chokepoint `:complete` |
| EG2 | tool/function definitions, tool args, and tool-result re-entry into a prompt | chokepoint `:complete` (results re-scrubbed on re-entry) |
| EG3 | embedding inputs (and therefore vector rows) | chokepoint `:embed` |
| EG4 | MCP tool responses / resources served to external agents | chokepoint `:mcp` |
| EG5 | eval corpora / red-team fixtures committed to the repo | authored under the same scrub; verifier-scanned |
| EG6 | logs, telemetry, error messages, and exceptions arising from any AI call — the observability shadow of EG1–EG5 | masked/token-only by construction (§3.2b); red-team asserts on captured logs/telemetry, not only the provider recording |

### 3.2 · The construction (mirroring the vault, layer for layer)

The chokepoint pipeline is a fixed order; every step fails closed:

1. **Resolve.** Every record/value binding is resolved through
   `Samen.Api.PiiResolution.resolve/4` on the **caller's actor** in a new explicit
   **egress mode** (an opts flag T65 adds — not a forged impersonation marker):
   vault-routed fields come back **masked-but-present** (`%Samen.Masked{}` → `••••`,
   the shape the impersonation branch already proves) regardless of plane, unless a
   live reveal grant covers the subject + label — the same grant model, authority, and
   audit as the operator-UI reveal. Grant-resolved plaintext is tagged and admitted
   only into `kind: :complete` payloads (INV-7's ephemeral-only clause), and only
   when the host has enabled `grant_plaintext_egress` (§6.1 — default off); the tag
   feeds the per-turn re-check of §3.2a.
2. **Assemble.** Prompt text may come only from: (a) the versioned Prompt resource
   (§7.5), whose template bodies are PII-scanned at write exactly as
   `Samen.Approvals` scans `reason`; (b) catalog-derived grounding from the T66
   runtime catalog (metadata only — never sample values, §8); (c) resolved bindings
   from step 1; (d) user-authored free text (a chat question, a draft instruction).
   Free text is the honest boundary: the invariant governs **vault-routed values**,
   not user keystrokes — a user typing their own data into a prompt is the same
   consent class as typing it into a support reply. Free text is still scrubbed
   (step 3).
3. **Scrub-refuse.** The fully rendered payload is scanned. Any `vt_` sentinel, any
   un-rendered `%Samen.Masked{}` / `%Ash.ForbiddenField{}`, or any binding that
   bypassed step 1 ⇒ `{:error, :pii_egress_refused}`. **Refuse, never
   silently strip** — stripping hides the bug the refusal exposes (the WriteGuard
   posture: a rejected write is a normal error, the DB — here, the wire — provably
   untouched).
4. **Seal.** The chokepoint mints `%Samen.AI.MaskedPayload{}` (kind, sealed segments,
   grounding meta). The struct's constructor is `@doc false` inside the chokepoint's
   namespace; **it is the only value the provider boundary accepts**.

Enforcement-by-construction is the same three-layer sandwich the vault ships:

- **Runtime clause refusal at the boundary** (the `VaultField.dump_to_native`
  mirror): the kernel's dispatch and every `Samen.AI.Provider` implementation's
  function clauses accept ONLY a chokepoint-minted `%Samen.AI.MaskedPayload{}`;
  anything else is refused at runtime (a `FunctionClauseError` / explicit error),
  exactly the clause-refusal posture `dump_to_native` ships. Stated precisely: this
  is a **runtime** guarantee — Elixir does not statically type behaviour-callback
  arguments, so no compile-time claim is made; the structural spine is the probe
  (third layer), not the type system.
- **Single minting site** (the `Files.ChokepointGuard` marker / `Delivery` single-path
  mirror): only `Samen.AI.Chokepoint` constructs `MaskedPayload` or invokes a provider
  callback — proven structurally, not promised (next layer).
- **Structural probe + verifier** (the `Samen.Chokepoint` decrypt-scanner mirror): an
  AST/grep scan over `samen_core/lib` + `samen_web/lib` asserting no module outside
  the chokepoint/kernel constructs `%Samen.AI.MaskedPayload{}` or calls a
  `Samen.AI.Provider` callback. Reintroduce a raw provider call in a verb module and
  the probe flips — exactly `delivery/chokepoint_anti_bypass_probe_test.exs`.

### 3.2a · Multi-turn accumulation: history is egress, every turn

Conversation history — **including prior assistant output** — re-enters a later
turn's payload only through the chokepoint, re-resolved against the **current**
turn's actor, plane, and grant state (the EG2 tool-result rule generalized to all
history). The resolver masks vault-routed *bindings*; it cannot recognize plaintext
the model *echoed* — so the chokepoint tracks it at the source: grant-resolved
plaintext is tagged at admission (§3.2 step 1), the tagged spans are recorded per
conversation, and on every subsequent turn the grant is **re-checked** for each
span's subject + label. If the current actor lacks a live grant — expiry,
revocation, actor change, or the `grant_plaintext_egress` flag now off — the span
(and any assistant-turn text derived under it) **re-masks to `••••` before
assembly**. Untagged history text is scrubbed for `vt_*` sentinels like any segment
(§3.2 step 3). Accumulated history therefore cannot carry plaintext past its grant
window or into an ungranted turn. T72's red-team includes the multi-turn case:
grant → canary revealed in turn N → grant expires → the turn N+1 payload must not
contain the canary.

### 3.2b · EG6: logs, telemetry, errors, exceptions — masked by construction

The observability shadow of an AI call is an egress path (log sinks are routinely
third-party aggregators), so it carries the same law:

- `{:error, :pii_egress_refused}` is a **payload-free** error: it never embeds the
  offending prompt, segment, or value — diagnostic context is limited to identifiers
  (payload kind, resource/field labels, segment index), never content.
- Provider adapter error terms must not echo the outbound payload; the kernel
  **normalizes adapter errors** before they propagate, so a `samen_anthropic`
  `{:error, term()}` (or a raised exception) cannot carry the assembled prompt or
  grant-resolved plaintext in its message, struct, or metadata.
- `Logger` and `:telemetry` emissions from the kernel, chokepoint, verbs, MCP, and
  adapters carry **masked/token-only representations** — payload ids, kinds, sizes,
  durations, field labels — never raw prompt text and never grant-resolved
  plaintext. `%Samen.AI.MaskedPayload{}` implements `Inspect` to redact its sealed
  segments (the `%Samen.Masked{}` `#Masked<••••>` precedent), so even a naive
  `inspect/1` in a log line cannot spill content.
- T72's red-team **observes EG6 directly**: adversarial cases run under log capture
  (ExUnit `CaptureLog`) + attached telemetry handlers, and the canary assertion
  covers captured log lines, telemetry event payloads, and rendered error/exception
  messages — not only the Fake's provider-side recording (§3.4). A leak the Fake
  cannot see, the log capture does.

### 3.3 · Why an unmasked prompt cannot reach a provider (the token-blind argument)

The assembling code path **never possesses** unauthorized plaintext: PiiResolution in
egress mode returns `%Masked{}` (token + label, zero plaintext — "there is no
plaintext to leak by any serialization path"), and plaintext exists only when a live
grant resolved it through the one sanctioned decrypt site (`Samen.Vault.reveal/3`,
still the single `Crypto.decrypt` call site). This is INV-1/INV-2 carried to the new
boundary: masking is a property of the **value layer**, not of the consumer's
discipline (ADR-042 §6 made the same argument for the LiveView client). The
chokepoint adds the belt to those braces: even a hostile assembler that somehow
obtained a `vt_*` token finds the scrub refusing it, and even code that skips the
chokepoint entirely finds no provider callback willing to take its string.

### 3.4 · The proof obligations (T65 + T72)

**T65 — `mix samen.verify.ai_prompt_masking`** (house verifier shape: `run/1` →
`Samen.Verifier.halt_if_violations/2`, `violations/1` callable without halting;
wired into demo's ci.sh, the `ci_sh.eex` template step list, and the root gate):

- structural violations: (a) any provider-callback reference or `MaskedPayload`
  construction outside the chokepoint/kernel (§3.2 layer 3); (b) any
  embeddable-declared field that appears in `Samen.Pii.Info.vault_routed_columns/1`
  or is catalog-flagged `pii: true` (§7.2); (c) any Prompt-resource template body
  containing a `vt_` sentinel.
- runtime red tests (`use Samen.MaskingCase`, the three-proof discipline): green —
  a grant-in-scope completion resolves plaintext; red — an operator-plane prompt for
  a vaulted record renders `••••`, never sentinel plaintext, never a `vt_*` token;
  a direct injection of a `vt_*`-bearing string is **refused** at the chokepoint;
  sabotage twin — a patch bypassing the egress resolver (or widening the scrub) flips
  the NAMED tests **and** the verifier, then reverts byte-exact
  (`scripts/sabotages/` patch, house harness).

**T72 — the mask-leak red-team (permanent CI tier)**: canary PII (unique sentinel
name/email values) is seeded through the **real vault write path**; ≥20 adversarial
cases spanning **every** egress class EG1–EG6 (direct exfiltration prompts, indirect
references, tool-output echoes, the §3.2a multi-turn expired-grant case, embedding
attempts, MCP browse/search probing, and error/log provocation — forcing refusals
and adapter failures to probe EG6) run against the fake provider — which **records
every payload byte it receives** (§4.2) — under log capture + attached telemetry
handlers (§3.2b), giving keyless CI observability over BOTH the provider-bound path
and its EG6 shadow. Pass = zero canary plaintext and zero `vt_*` in any recorded
provider-bound payload, vector row, captured log line, telemetry event, or rendered
error/exception message. This tier is a standing `ci.sh` step with its own sabotage
patch. §10 fixes its numbers.

**Decision (binds T65, constrains all of T64–T72):** implement §3.1–§3.4 verbatim.
The chokepoint module is `Samen.AI.Chokepoint` (samen_core); the sealed type is
`%Samen.AI.MaskedPayload{}` (Inspect-redacting per §3.2b); the egress resolution
mode is an explicit `PiiResolution.resolve/4` option; refusal error is
`{:error, :pii_egress_refused}` (payload-free per §3.2b); history re-scrub per
§3.2a. Deferred to T65: the exact scrub scanner internals (sentinel regex vs.
AST-assisted), the resolve-opts spelling, and the span-tracking representation for
§3.2a — the refusal, EG6, and re-mask semantics above are not negotiable.

## 4 · Keyless / fail-honest posture (M9 + operator ruling — binds T64, T67, T72)

The ENTIRE plane is buildable and testable with **zero live LLM calls in CI**. The
masking chokepoint acts BEFORE the provider, so the load-bearing security surface is
fully provable keyless. Per capability:

| capability | keyless CI mechanism | with a real key (host opt-in) |
|---|---|---|
| kernel + chokepoint + verifier | fully testable keyless — every refusal, resolution, and seal happens pre-provider | unchanged |
| completion (EG1/EG2) | `Samen.AI.Provider.Fake` (samen_core): deterministic (same seed ⇒ same output), scriptable per-fixture, **records every payload** for red-team assertions — the `Samen.Delivery.LocalSink` honest-capture analog. In `:test`, an unwired provider resolves to Fake; outside `:test`, unwired ⇒ `{:error, :not_configured}` | `samen_anthropic` configured via host config; cost + external dependency documented |
| embeddings (EG3) | `Samen.AI.Embedder.Deterministic` (samen_core): a hashing embedder (stable token-projection to the fixed dimension) — no semantic quality, but deterministic, so org-scoping, ranking-shape, and no-PII-in-vector tests are real | provider adapter `embed/2`; unconfigured ⇒ `{:error, :not_configured}` |
| provider package tests | `samen_anthropic` tests run against recorded fixtures (the samen_stripe/samen_postmark cassette precedent) | live smoke behind `SAMEN_AI_LIVE=1` only |
| MCP (EG4) | entirely local HTTP — keyless by nature | unchanged |
| eval + red-team (EG5, EG6) | fake provider ⇒ deterministic scores; the red-team asserts on the chokepoint (provider-independent, M9's exact rationale) AND on captured logs/telemetry/errors (§3.2b) | `SAMEN_AI_LIVE=1` live-model eval lane; results recorded in `docs/claim-evidence.md`, which lane ran stated explicitly |

Fail-honest is the ADR-014/024/026 contract, unchanged: an unconfigured or
unimplemented adapter NEVER returns `{:ok, _}` for work it did not do. A canned
success from a keyless adapter is the exact lie the sabotage harness exists to catch.

**Decision (binds T64, T67, T72):** ship `Samen.AI.Provider.Fake` and
`Samen.AI.Embedder.Deterministic` in samen_core as the CI lane; provider resolution
follows §5.2; `SAMEN_AI_LIVE=1` is the only path to a live model and is never a CI
default; claim-evidence entries state which lane produced each claim.

## 5 · The `Samen.AI` kernel + provider packages (D1 — binds T64)

### 5.1 · The behaviour (the adapter contract)

```elixir
defmodule Samen.AI.Provider do
  @callback complete(Samen.AI.MaskedPayload.t(), config :: map()) ::
              {:ok, Samen.AI.Completion.t()} | {:error, :not_configured | term()}
  @callback embed(Samen.AI.MaskedPayload.t(), config :: map()) ::
              {:ok, [[float()]]} | {:error, :not_configured | term()}
end
```

Two callbacks, both accepting only the sealed payload (§3.2). `samen_anthropic` is a
first-party-but-separate mix app (the samen_stripe/samen_postmark layout precedent)
implementing the behaviour with recorded-fixture tests; samen_core gains **zero**
vendor deps and its grep-proof stays green with the package absent (INV-4).

### 5.2 · Provider resolution (the Delivery `decide/3` mirror)

`config :samen_core, Samen.AI, provider: {module, config}` — host-wired, exactly the
`Samen.Approvals` / `Notifications.Engine` seam convention. Unwired in `:test` ⇒
`Samen.AI.Provider.Fake`; unwired elsewhere ⇒ every call returns
`{:error, :not_configured}` (blocked, never faked — the Delivery chokepoint's
posture). A per-org provider override is explicitly OUT of scope for this run
(revisit trigger: a real multi-provider requirement; the Delivery
`ProviderSelection` pattern is the template when it fires).

### 5.3 · The kernel surface + ≈0-LOC adoption

`Samen.AI.complete(scope, prompt_ref, bindings, opts)` and
`Samen.AI.embed(scope, source, opts)` are thin: **their bodies route through
`Samen.AI.Chokepoint` by construction** — there is no kernel function that reaches a
provider without minting a sealed payload first, and §3.2's structural probe proves
no one else does either. Verbs (§7.5), the support operator (§6.3), MCP (§9), and the
CRM/analytics surfaces (§6.4) all call the kernel, never a provider. A vertical
adopts AI the way it adopts everything else: the capability lives in
samen_core/samen_web, surfaces mount through the existing router macros/mount seams,
and the host's only authored lines are the provider config (INV-5; the leverage
guard applies).

**Decision (binds T64):** implement §5.1–§5.3 verbatim: behaviour + kernel +
chokepoint skeleton + `Provider.Fake` in samen_core; `samen_anthropic` as a separate
package with fixture tests; the chokepoint-single-path probe; core vendor-free grep.
Deferred to T64: the HTTP client choice inside samen_anthropic (req vs. :httpc —
package-local, invisible to core) and the `Completion` struct's exact fields.

## 6 · Plane model — which actor, which plane, why PII cannot enter (D5/D6/D7 — binds T70, T71)

### 6.1 · AI egress is masked-by-default on EVERY plane

INV-1's text names "AI call" alongside render surfaces — and the trust boundaries
differ: the tenant UI renders plaintext **to the data's owner**; an AI call transmits
**to a third-party provider**. So this ADR rules: egress does NOT inherit the tenant
plane's own-org-clear read posture. On every plane, vault-routed values enter a
provider payload masked-but-present (`••••` — shape visible, value withheld) unless a
**live reveal grant** covers that subject + label AND the host has explicitly
enabled grant egress.

Be precise about what the exception does, because it is NOT merely "a reveal": a UI
reveal shows plaintext to a granted human inside samen — the value never leaves the
governed boundary. A granted AI completion **transmits that plaintext to the
configured third-party model provider** (e.g. Anthropic). This is the **one
deliberately-permitted PII egress in the entire plane**, and it crosses the exact
trust boundary this section invokes to justify masked-by-default — so it is never a
silent default. It is gated twice:

1. the **live reveal grant** (time-boxed, audited — and the audit entry records that
   the destination was the *provider*, distinguishing it from a UI reveal);
2. an explicit host opt-in: `config :samen_core, Samen.AI,
   grant_plaintext_egress: true` — **default `false`**. With the flag off (the
   default), even a grant-holding actor gets masked egress; the grant still governs
   UI reveals unchanged. Enabling the flag is a conscious deployment decision that
   the host accepts third-party PII exposure under its provider agreement (DPA /
   data-retention terms — §12).

Grant + flag together admit plaintext into **ephemeral completion payloads only**,
with the §3.2a per-turn re-check: grants are time-boxed; completion payloads are
transient; embeddings/vectors/MCP resources/logs persist or leave the boundary
un-granted, so neither the grant nor the flag ever applies to them (INV-7).

### 6.2 · AI never becomes a plane or masking bypass

Every AI call executes as the **calling actor's real scope** — tenant or operator,
with its real `org_id`, through `Samen.Policy.OrgScope` (fail-closed FilterCheck:
cross-org rows do not exist; an org-less actor gets nothing) and PiiResolution, like
any other read. The chokepoint never elevates, substitutes, or synthesizes an actor
(INV-2). AI **writes** do not exist: AI outputs are drafts and proposals persisted
through governed Ash actions as the real actor; anything with side effects goes
through the E3 approvals engine. The MCP action-proposal tool (§9) is the same rule
externalized.

### 6.3 · The AI support operator (D5 — binds T70)

The draft worker executes as a **dedicated AI service principal** on the operator
plane — a real, auditable identity whose reads resolve masked-but-present (§6.1) and
which holds no reveal grants. Drafts are grounded on the T66 runtime catalog + the
unfurled object cards (both masked-path), persisted as **draft** records, and are
structurally unable to send: the only path to `Samen.Delivery.Chokepoint.send/2` is
the E3 approve flow — `requested_by` = the AI principal, `decided_by` = a human
operator. Requester≠approver holds **by construction**: the AI principal is never a
decider (engine refuses `decided_by == requested_by` at both the policy and
`<abbrev>_distinct_party` DB-CHECK layers, and T70 additionally denies the AI
principal the approve action by policy). Edit-then-approve sends the edited body;
rejection discards; the approved send passes suppression at the Delivery chokepoint
like every other send. The red test T70 owns: **no path from draft creation to
`Delivery.Chokepoint.send/2` without an approve event** (probe + time-travel), with
the approve-then-send positive control.

### 6.4 · CRM AI + token-blind analytics (D6/D7 — binds T71)

CRM surfaces (timeline summary, sequence drafts, inbound classify, next-step
recommendations) are T68 verbs invoked with the CRM actor's scope — masked-path via
§6.1, drafts land as drafts (red assertion: a sequence draft never reaches the
Delivery chokepoint). Analytics (D7) is the strongest form of the argument: NL
questions execute as the **aggregate-plane actor**, whose queryable schema
**structurally contains no PII columns** — there is no column to leak, so token-blind
holds by schema, not by filter. T71's probe asserts exactly that (the actor's
queryable schema has no vault-routed/`pii_*` columns), and
`mix samen.verify.aggregate_privacy` stays green.

**Decision (binds T70, T71):** implement §6.1–§6.4 verbatim. Deferred to T70: the
draft resource's schema and the AI principal's identity representation (service
membership vs. nil-membership principal) — its non-decider property is not
negotiable.

## 7 · Embeddings + pgvector (D3 Search — binds T67)

### 7.1 · pgvector is REQUIRED (M3 OVERRIDE) and the dep is sanctioned as protocol-class

Semantic search is **always-on**: no optional-by-detection, no degraded mode, no
silent fallback. The migration runs `CREATE EXTENSION IF NOT EXISTS vector`; the
`ci.sh` and gen-app flagship-probe DB setups ensure the extension; a missing
extension **fails setup with an actionable error naming pgvector** — an environment
error, never a fake fallback. Dependency ruling: ash_ai is REJECTed (ADR-037 §5.6),
but its **pgvector shape is adopted** — vector columns on the resource, async
embed-on-write via the ash_oban strategy (§5.9 ADOPT), HNSW via
`custom_statements`. The `pgvector` hex package (Ecto/Postgrex vector types) enters
`samen_core` classified as a **database-protocol library** (postgrex-class — it
speaks to our own Postgres, holds no API key, calls no external service), NOT a
vendor SDK; INV-4 and the vendor-free grep are untouched. ADR-037 carries no §5.x row
for the pgvector hex lib itself — see References for the required cross-note.

### 7.2 · What may be embedded: allowlist-by-construction, grants never apply

Embedding input is assembled by the chokepoint (`kind: :embed`) **only** from fields
a resource explicitly declares embeddable (T67 names the seam), cross-checked by the
`ai_prompt_masking` verifier: a declared field that is vault-routed
(`Samen.Pii.Info.vault_routed_columns/1`) or catalog-flagged `pii: true` is a
violation at verify time, and the chokepoint refuses it fail-closed at runtime
(`{:error, :pii_egress_refused}`). **Reveal grants do not unlock embedding** — a
vector persists beyond any grant window and is invertible; INV-7's ephemeral-only
clause is categorical here. Rationale recorded: embedding a vaulted field would leak
PII into vector space permanently, defeating crypto-shred (ADR-001) — the vector
would survive the subject key's destruction.

Recorded limit (operator/builder responsibility, not a chokepoint guarantee): the
cross-check keys on field **classification**, not content. A NON-vault free-text
field (notes, description) declared embeddable can carry user-typed PII permanently
into vector space — §3.2's free-text-is-user-consented argument does NOT extend to
embeddings, because vectors have no ephemeral escape. Declaring a free-text field
embeddable therefore carries the same weight as classifying a field non-PII
(the ADR-034 reviewer-gate posture applies).

### 7.3 · Org-scoped vectors

Vector rows carry `org_id` and sit behind the same `Samen.Policy.OrgScope` policy as
every read: org B's vectors are never returned — never even *ranked* — for org A
(FilterCheck: foreign rows do not exist). tsvector search remains the shipped
baseline alongside (ADR-027 posture unchanged). Keyless: the deterministic embedder
(§4) makes ranking-shape, cross-org-red, and no-PII-in-vector tests real in CI.

**Decision (binds T67):** implement §7.1–§7.3 verbatim: pgvector dep + extension
migration + CI/probe setup asserts, embeddable-field allowlist + verifier
cross-check + runtime refusal (with the sabotage twin proving the red test can
fail), org-scoped vector rows, oban async embed-on-write, HNSW via
custom_statements. Deferred to T67: dimension, index parameters, and the embeddable
declaration's exact DSL spelling.

### 7.5 · The Prompt resource + the six verbs (D3 — binds T68)

The eight-verb surface = Search (T67, above) + **Prompt** (managed prompt templates
as a versioned resource) + Summarize, Extract, Classify, Generate, Recommend, Analyze
(T68). The Prompt resource is org-scoped, catalog-registered, and **versioned:
update creates a new immutable version** (verbs reference name + version, so a
prompt change never silently rewrites history); template bodies are PII-scanned at
write (the approvals-`reason` scan) and may not contain `vt_` sentinels. Each verb
is a vault-aware, org-scoped operation whose ONLY provider access is
`Samen.AI.complete/4` — the §3.2 structural probe covers verb modules explicitly.
Per-verb table test (six rows) executes org-scoped through the chokepoint against
the fake provider with masked-path input. T99's `cast_input` conformance (ADR-036
D3) underpins the verbs: vault-resolved values are validated/normalized at write, so
verb inputs are well-formed by the time they reach assembly.

**Decision (binds T68):** as stated. Deferred to T68: the verb modules' exact
signatures and the Prompt resource's field list beyond {name, version, body, org_id}.

## 8 · Grounding via the runtime catalog (D9 — binds T66)

Grounding is **generated, not hand-maintained**: a runtime module/endpoint serves the
live equivalent of `schema.dict.json` (tables → resources → fields with logical
names, types, and the declaration-derived `pii` flag), with a parity test asserting
normalized equality with `mix samen.catalog.dump` output — the catalog cannot drift
from what the AI believes. Serving is plane-aware: PII classifications ship as
**metadata** (the `pii: true` flag tells the model a field exists and is protected);
**sample values are never included**. The kernel consumes it for prompt grounding
context (§3.2 step 2b) and the MCP catalog tool serves it (§9).

**Decision (binds T66):** as stated; the parity test is the contract.

## 9 · The MCP server (D4 — binds T69)

Per ruling c4 and ADR-037 §5.6(a): an **HTTP + SSE (streamable) MCP server mounted in
samen_web** — `AshAi.Mcp` is mined as the protocol reference (version 2025-03-26,
router shape, api-key plug seam), not adopted as a dep. Auth: **per-operator API
tokens**, SHA-256 digest lookup (the demo `KeyAuthPlug` precedent), token →
actor + plane; no/invalid token ⇒ 401 (with the valid-token positive control); **no
stdio in prod**. Four tool families, all read-or-propose, never write:

- **catalog** — serves the T66 runtime catalog (plane-aware, metadata only);
- **search** — tsvector + semantic, org-scoped through OrgScope, results masked;
- **drafts** — creates draft records only (the §6.3 class);
- **action proposals** — opens a **T34 approval** via the Gate face
  (`kind: "<resource>:<action>"`, `subject_ref` = the record's object-ref) and
  **never executes directly**: the proposal alone changes nothing; a human — never
  the token's principal, by requester≠approver — approves in the samen UI, and the
  Gate re-invokes the action as the requester within the requester's own policy
  envelope (approval adds second-party consent, never privilege escalation).

Every tool response is EG4 egress: it passes the chokepoint's `:mcp` scrub —
masked values, no `vt_*` tokens, no sample values, org-scoped. An external agent
holding a valid token sees exactly what that operator would see in the UI, minus
reveal (grants do not apply to `:mcp` — persisted-egress class, INV-7).

**Decision (binds T69):** as stated. Deferred to T69: the token resource's storage
shape and the SSE session bookkeeping — the 401/masking/proposal-not-execution
contracts are not negotiable.

## 10 · Eval posture: runtime eval + the permanent red-team tier (D8 — binds T72)

Two standing gates, both keyless (M9), both wired into `ci.sh` as named tiers with
sabotage patches:

1. **Grounding-context eval (keyless):** a fixed, committed corpus of question →
   expected-grounding cases (≥20 cases minimum so the bar is meaningful), executed
   deterministically against the fake provider. **Honesty clause — what this
   measures:** under the scriptable Fake there is no model cognition, so this eval
   proves that the correct grounding context was **assembled and injected** for each
   question (catalog selection, binding resolution, prompt composition) — it is a
   **context-assembly bar, NOT a model-answer-fidelity bar** (the exact parallel of
   §12's deterministic-embedder admission; do not read "≥90%" as "≥90% grounded
   answers from the model"). **Pass bar: ≥90%** of cases assemble the expected
   grounding. This number is authoritative — T72's done-criteria cite it and the
   T72 worker never chooses its own; the exact score lands in evidence. (Rationale
   for 90 over 100: the corpus includes deliberately-hard indirect-reference cases;
   a 100% bar would pressure the corpus toward triviality — the anti-tautology
   failure mode.) The two bars, distinctly: the **keyless CI bar** (context
   assembly, ≥90%, gate-binding) and the **live-lane bar** (model grounding
   fidelity, measured only under `SAMEN_AI_LIVE=1` against a real model, score
   recorded in claim-evidence — informative, never a CI gate, per M9).
2. **Mask-leak red-team (the INV-7 proof):** §3.4's design — vault-seeded canaries,
   ≥20 adversarial cases across EG1–EG6 (including the §3.2a multi-turn
   expired-grant case and §3.2b error/log provocation), zero canary plaintext /
   zero `vt_*` in any recorded provider-bound payload, vector row, captured log
   line, telemetry event, or rendered error/exception message. Permanent tier: it
   runs at every phase boundary from T72 onward (INV-3 — new capabilities extend
   the gate, never bypass it), with a sabotage patch that flips named red-team
   tests and reverts byte-exact.

The live-model lane (`SAMEN_AI_LIVE=1`) re-runs both against a configured provider —
documented, never a CI default; claim-evidence records which lane ran (M9).

**Decision (binds T72):** as stated; the ≥90% context-assembly bar and the
≥20-case floors are fixed here, and the red-team's observation surface includes
captured logs/telemetry (EG6), not only the Fake recording. Deferred to T72: corpus
content and adversarial-case authorship (noting honestly: the corpus is authored by
the same task that runs it — the sabotage patch and the fixed floors are the
counterweight).

## 11 · Deferred sub-decisions (explicit, with owners)

| deferred | to |
|---|---|
| samen_anthropic HTTP client; `Completion` struct fields; error-normalization internals (the §3.2b payload-free contract is fixed here) | T64 |
| scrub-scanner internals; `resolve/4` egress-opt spelling; §3.2a span-tracking representation | T65 |
| embedding dimension; HNSW params; embeddable-DSL spelling | T67 |
| verb signatures; Prompt resource fields beyond the core four | T68 |
| MCP token storage shape; SSE session bookkeeping | T69 |
| draft resource schema; AI-principal identity representation | T70 |
| eval corpus + adversarial case content (floors + bar fixed in §10) | T72 |

## 12 · Consequences

**Positive** — the Intelligence column (101–108) closes on the existing masking
spine rather than beside it; INV-7 makes "an AI operator that structurally cannot
leak PII" a tested claim, not marketing; keyless CI keeps the whole plane inside
INV-3 (no phase gate ever waits on a vendor key or spends tokens); the provider seam
means model churn is a package concern, not a core migration; MCP ships the
"arguably the whole point" surface with the same governance as the UI.

**Negative / accepted** — masked-by-default egress (§6.1) means AI answers about
PII-bearing fields are shape-only unless a grant is in play — a deliberate quality
sacrifice on the third-party boundary. **Accepted consequence, named plainly:** a
host that enables `grant_plaintext_egress` authorizes vault plaintext to **leave
the governed boundary to the third-party model provider** under a live grant — this
is categorically more exposure than a UI reveal (where PII never leaves samen), it
is why the flag defaults off, and a host enabling it does so under its own provider
agreement (DPA / data-retention / zero-retention terms) with every occurrence
audited (§6.1). The deterministic embedder gives CI no semantic-quality signal, and
the keyless grounding eval likewise proves context assembly, not model fidelity
(§10 — both live-lane-only measurements); hand-building the kernel forgoes ash_ai's
tool plumbing (accepted in ADR-037 §5.6; re-evaluation trigger recorded there);
pgvector-REQUIRED adds a hard environment prerequisite to every CI/probe DB (M3
accepted this cost explicitly).

**Neutral** — tsvector search, the Delivery chokepoint, the approvals engine, and
the reveal-grant model are consumed unchanged; verticals mount at ≈0 LOC; the
abbrev registry is untouched by this ADR (new resources reserve through the
sanctioned allocator as usual).

## 13 · Red paths / verification (the WS-D adversarial floor)

- **RP-AI-1 (single egress path):** the §3.2 structural probe — a raw provider call
  or out-of-chokepoint `MaskedPayload` construction anywhere in core/web flips it.
- **RP-AI-2 (fail-closed refusal):** `vt_*` injection / unresolved-field payloads are
  refused with `{:error, :pii_egress_refused}`; sabotage twin proves the assertion
  refutable (T65).
- **RP-AI-3 (fail-honest keyless):** unwired provider outside `:test` ⇒
  `{:error, :not_configured}`; a canned-ok stub flips the named test (ADR-014 class).
- **RP-AI-4 (no PII in vector space):** embed a vault-routed field → refused;
  verifier violation on an embeddable-declared vault column; canary never appears in
  any vector row (T67 + T72).
- **RP-AI-5 (org isolation):** cross-org semantic search returns nothing for the
  foreign org, with the same-org positive control (T67).
- **RP-AI-6 (draft-never-sends):** no path from AI draft to
  `Delivery.Chokepoint.send/2` without an approve event; approve-then-send control;
  MCP proposal alone changes nothing (T70, T69).
- **RP-AI-7 (red-team, permanent):** §10.2 — zero canary egress across EG1–EG6,
  asserted on recorded payloads, vector rows, AND captured logs/telemetry/errors;
  standing ci.sh tier + sabotage patch (T72).
- **RP-AI-8 (grounding parity):** runtime catalog == `samen.catalog.dump`, normalized
  diff empty (T66).
- **RP-AI-9 (EG6 masked observability):** a forced refusal and a forced adapter
  failure produce error terms, log lines, and telemetry events containing no prompt
  content, no canary, no `vt_*`; `inspect(%MaskedPayload{})` redacts (T64/T65,
  probed permanently by T72's EG6 cases).
- **RP-AI-10 (grant gate + multi-turn):** with `grant_plaintext_egress` unset, a
  grant-holding actor's completion stays masked (red) — flag + grant control
  resolves plaintext (green); and the §3.2a case — canary revealed under grant in
  turn N never appears in the ungranted turn N+1 payload (T65/T72).

## 14 · References

- spec §WS-D (D1–D9, elements 101–108); INV-1..INV-6; INV-7 defined here (§3.1).
- Rulings: M3 (pgvector REQUIRED), M9 (keyless CI / `SAMEN_AI_LIVE=1`), c4 (MCP
  HTTP+SSE, per-operator tokens) — `_orch/plan/spec-questions.md`.
- ADR-037 §5.6 (ash_ai REJECT + the three binding notes consumed in the header),
  §5.9 (ash_oban ADOPT — the embed-on-write strategy). **Required cross-note to
  ADR-037 (recorded here, per doc-only scope — not edited into ADR-037 by this
  task):** the `pgvector` hex package is sanctioned for samen_core as a
  database-protocol library (postgrex-class; the c2 protocol-lib precedent) — it is
  not a vendor SDK and adds no §5.x verdict row; a future ADR-037 touch may add a
  one-line pointer to this ADR §7.1.
- ADR-014 / ADR-024 / ADR-026 — fail-honest adapter contract; ADR-027 (tsvector
  baseline); ADR-001 (crypto-shred — the §7.2 rationale); ADR-036 D3 (cast_input
  conformance, via T99); ADR-038 §4.3 (Delivery chokepoint); ADR-040 §4 (approvals
  engine + Gate); ADR-042 (value-layer masking argument, plane/client model).
- Mirrored constructions: `Samen.Type.VaultField`, `Samen.Pii.WriteGuard`,
  `Samen.Vault.Change`, `Samen.Api.PiiResolution`, `Samen.Files.ChokepointGuard`,
  `Samen.Chokepoint`, `Samen.Delivery.Chokepoint`, `Samen.Policy.OrgScope`,
  `Samen.MaskingCase`.
- Downstream: T64–T72 handoffs (`_orch/tasks/T6x/handoff.md`, `_orch/tasks/T7x/…`);
  `_orch/plan/traceability.yaml` D1–D9 verify clauses; roadmap Phase 5.
