# ADR-052 — Turn the observability plane on, then add a session replay that never stores plaintext

- **Status:** **ACCEPTED (2026-10-09).** The operator read the evaluation and took the
  recommended option on all four decisions (§6: D1 (1), D2 (1), D3 (1), D4 (1)), with the
  ruling "be inspired by phoenix_replay, but rebuild it for our needs and our approach."
- **Date:** 2026-10-09
- **Build status:** P1 in progress on `feat/adr-052-p1-telemetry`. P2–P4 not built.
- **Deciders:** the operator, on §6 D1–D4.
- **Inspiration (not a dependency):** `phoenix_replay` v0.6.2 (elixir-vibe/phoenix_replay, MIT).
  Read 2026-10-09; we take its capture shape, not its code or its storage/privacy model.

---

## 1. Context — what exists, read on `f210257`

### 1.1 The observability plane is governed but dark

The guards are real and strong (`docs/observability-guide.md`):

- `Samen.Observability` owns `db_statement: :disabled` for OTel-Ecto and raises at boot if it
  is flipped; the `LogTelemetry` tier checks config + live handlers.
- `Samen.WideEvent` + `Samen.WideEvent.Schema`: every field is `:opaque_id | :token | :enum |
  :number`; `mix samen.verify.sink_schema` fails the build on a free-string field; `actor_id`
  is `HMAC(psk_S, subject_id)` keyed off the subject's DEK, so it goes unlinkable on shred.
- `Samen.Analytics.track/1`: four refusal gates; `Samen.Metrics`: bounded cardinality.

But almost nothing flows through it:

| Surface | Production callers on `f210257` |
|---|---|
| `Samen.WideEvent.emit/1,2` | **0** (only the ingress tier's moduledoc mentions it) |
| `Samen.Tracer.*` (incl. `with_reveal_span/3`, `with_job_span/3`, `inject_trace_context/1`) | **0** outside `tracer.ex` |
| `:telemetry` handlers on `[:phoenix, :live_view, …]` / `[:phoenix, :live_component, …]` | **0** — while `samen_web/lib` has 228 `handle_event` clauses |
| `traces_exporter` | `:none` in every config |
| Wide-event sinks | off by default |

So a tenant report of "it broke when I clicked save" has nothing to look at, and the one
operation that most deserves a span — a reveal — emits none.

### 1.2 Logging is ungoverned

- No host configures `:phoenix, :filter_parameters`; Phoenix's default filters only
  `"password"`. Both `Phoenix.Logger` (controller params) and `Phoenix.LiveView.Logger`
  (`handle_event` params, `:debug`) use it.
- `demo/config/dev.exs` runs `:debug`; prod runs `:info` — one config line from logging every
  LiveView event's params, with no tier to catch it.
- ~136 `Logger.*` calls in `samen_core`/`samen_web`, many `inspect(reason)`; a failing Ash
  changeset can carry user-typed plaintext *before* it reached the vault.
- The `LogTelemetry` tier checks OTel-Ecto only. No tier looks at Logger at all.

### 1.3 Why a stock session replay would be the largest plaintext store in the system

`phoenix_replay` records server-side: an `on_mount` hook plus LiveView telemetry captures mount
assigns, params, `handle_event` name+params, the changed assigns of each render, and (via its
client JS, on by default) form-control values. Replay re-renders the current templates with
recorded assigns. Privacy is a key-name sanitizer plus optional regex redaction at save.

On Samen that captures plaintext twice over:

1. Tenant-plane LiveViews resolve rows through `Samen.Api.PiiResolution` **before** they land in
   assigns (`samen_web/lib/samen/ui.ex`, `ui/board.ex`, `ui/map.ex`, …) — on the tenant plane
   that resolution is CLEAR. Recorded assigns are therefore plaintext.
2. Form events carry what the user typed, which is plaintext before any vault write.

Stored in files or an uncatalogued table with `retention: nil`, that is outside crypto-shred,
outside `no_plaintext_pii`, outside the destruction oracle, and viewable without a reveal grant.

### 1.4 What Samen already has that a replay viewer needs

Impersonation (`Samen.Impersonation`) is *an operator sees a tenant's real UI with PII as
`••••` unless a separate second-party reveal grant covers the subject* — reason-required,
short-TTL, deny-on-read, audited. `Samen.Masked` implements `Phoenix.HTML.Safe`, so a template
rendering a `%Masked{}` prints `••••` and never raises. `Samen.Cdc.Projection.classify_columns/2`
(ADR-015) already decides, per column, default-deny, whether a value may leave the OLTP row.

**A replay is impersonation, pointed at the past.** That is the design.

---

## 2. Decision

### 2.1 P1 — light the plane (D1)

1. **LiveView + request wide events.** A framework telemetry attachment (wired by
   `Samen.Observability.child_specs/2`, default ON) handles
   `[:phoenix, :live_view, :mount | :handle_params | :handle_event, :stop | :exception]`,
   the `:live_component` `handle_event` pair, and `[:phoenix, :endpoint, :stop]`, and emits ONE
   `Samen.WideEvent` per callback/request. New schema fields are bounded types only (e.g.
   `view` as a catalog identifier, `callback` and `outcome` as closed enums, `event` as an enum
   drawn from a bounded set — a client-sent event string NEVER becomes an atom; unknown → `:other`).
   `sink_schema` still passes, and gains a red path for a free-string field.
2. **Spans where they matter.** The reveal chokepoint runs inside `with_reveal_span/3`
   (three-attribute allow-list unchanged); `Samen.Jobs` enqueue injects trace context and the
   framework workers run inside `with_job_span/3`. Exporter stays `:none` by default; the
   `--deploy` runtime layer maps `OTEL_EXPORTER_OTLP_ENDPOINT` to an OTLP exporter and raises
   (fail-honest, ADR-024) if the endpoint is set but `opentelemetry_exporter` is not loadable.
3. **Logger governance.** Framework default `filter_parameters: {:keep, […]}` — a keep-list
   (bounded ids, paging/sort keys), default-deny for everything else — in every host config and
   the `Samen.Gen.App` templates. LiveView `log:` set explicitly. A new `no_plaintext_pii`
   tier, **`:logger`**, fails when `filter_parameters` is not a `{:keep, _}` list, or when prod
   logger level is below `:info`. Ash changeset/error inspection of vault-routed attributes is
   verified to print `••••`/redacted (builder verifies; if it does not, it is fixed at the
   attribute, not in Logger).

### 2.2 P2 — `Samen.Replay` capture (D2, D3)

Inspired by phoenix_replay's shape: an `on_mount` hook + `attach_hook` for `:handle_params` /
`:after_render`, `[:phoenix, :live_view, :handle_event, :start]` telemetry for events (so events
halted by other hooks are still seen), an ETS buffer written from the LiveView process, a
monitor that finalises on exit. Rebuilt with these rules:

1. **Record by reference, never by value.** A sanitizer walks every captured term:
   - an Ash record of a resource with vault-routed attributes: each such attribute becomes
     `%Samen.Replay.Ref{resource, pk, attribute, label}` — the plaintext is dropped at capture;
   - other attributes are kept only if `Samen.Cdc.Projection.classify_columns/2` would project
     the column (ADR-015 default-deny reused verbatim); freeform columns become
     `%Samen.Replay.Redacted{kind: :free_text, length: n}`;
   - bare strings outside records are dropped (`%Redacted{kind: :string}`) unless the assign key
     is on the view's declared keep-list (framework LiveViews declare theirs, e.g. `:page_title`);
   - numbers, booleans, dates, decimals, ids, and atoms from closed sets are kept; maps/lists
     recurse; `%Samen.Scope{}`, actors, sockets, PIDs and functions are dropped; the session
     actor is stored only as the wide-event HMAC pseudonym;
   - `%Samen.Masked{}` is kept as-is (it carries a token, never plaintext).
2. **Events record shape, not content (D3).** `handle_event` frames carry the view, the event
   (bounded, as in §2.1), and for each param: key, type, length, and `Samen.PiiValueShape`
   class. A value is kept only if its key is on the event's declared keep-list (sort, page,
   filter enums). There is **no client JS form-value channel**; pointer/viewport capture is
   out of scope for v1.
3. **Frames follow the wide-event rule.** A declared frame schema with bounded types and a
   build-time check (`mix samen.verify.replay_schema`), same discipline as `sink_schema`.
4. **Postgres only, catalogued.** Replay session + frame tables are framework-owned resources
   (abbrevs via the sanctioned allocator, never hand-edited), JSONB payloads so the
   `no_plaintext_pii` DB tiers and the destruction oracle can scan them. TTL via
   `Samen.Retention` (default 14 days, bounded max). No file backend.
5. **Off by default, opt-in per org** through the feature-flag engine (ADR-020), with a sample
   rate, a per-session frame cap and a byte cap; only sessions with user interaction persist.
   Tenant plane only in v1 (the operator plane is already fully audited).

### 2.3 P3 — the player and who may watch (D4)

1. **Resolve at view time, on the viewer's plane.** The player rebuilds assigns frame by frame;
   each `Ref` is resolved by reading the record under the **viewer's** `%Samen.Scope{}`
   (org-scoped policies apply) and passing it through `Samen.Api.PiiResolution`. Results:
   - operator without a grant → `%Masked{}` → `••••`;
   - operator with a live reveal grant on that subject → plaintext through the one vault
     chokepoint (and now a reveal span, §2.1);
   - subject crypto-shredded → `:shredded` placeholder — **erasure reaches replays for free**;
   - record deleted → `:gone` placeholder.
   The player labels resolved values as **current** values (late binding): a replay shows what
   the user did, with today's value of each referenced field. (Historical values via
   `Samen.Versioning` are out of scope, §7.)
2. **Watching is impersonating.** An operator may open a replay only while holding an ACTIVE
   impersonation session for that org (deny-on-read per frame batch, same as
   `Impersonation.scope/3`). A tenant may replay its own org only with an admin-class role.
   Every open writes a token-only `aud_event` (`replay.viewed`: replay id, viewer pseudonym,
   impersonation session id) — no reason text beyond the impersonation session's own.
3. **Rendering.** The player renders the recorded view's current `render/1` with rebuilt
   assigns in an isolated LiveView; handlers never run, nothing is re-driven, outbound side
   effects are impossible. A code-drift marker compares the recorded view module's MD5 with the
   loaded one.
4. **The masking watch-list applies.** The player is a surface rendering vault-routed fields,
   so it ships the three proofs via `Samen.MaskingCase` (green tenant/operator-with-grant;
   red operator-without-grant renders `••••`, never plaintext, never a `vt_*` token; sabotage
   twin).

### 2.4 P4 — mounts, tiers, docs

- Framework mount (`samen_replay_routes/…`) adopted by driftwood, pawchart and demo at ≈0
  authored LOC (leverage guard).
- `no_plaintext_pii` gains a **`:replay`** tier (no plaintext in replay tables) and a post-shred
  check (a shredded subject's refs resolve to `:shredded` in every stored replay).
- `docs/observability-guide.md` gains §5 Replay; this ADR's build status is updated per phase.

---

## 3. Red paths (each ships with a sabotage patch, next free number at build time)

| # | Red path | Must fail when |
|---|---|---|
| R1 | Wide-event schema refuses a free-string field (incl. the new LiveView fields) | a `:string` field is added |
| R2 | A client-sent event string never becomes an atom / enum value | the event is passed through raw |
| R3 | Reveal emits exactly one reveal span with only the three allowed keys | the span wrap is removed |
| R4 | `:logger` tier fails a non-`{:keep, _}` `filter_parameters` and a prod level below `:info` | either check is disabled |
| R5 | A captured tenant frame contains no plaintext of a vault-routed attribute and no `vt_*`-adjacent plaintext | the sanitizer keeps the value |
| R6 | A freeform column value is recorded as shape only | the CDC classifier check is bypassed |
| R7 | A form param value is recorded as shape only unless keep-listed | the keep-list check is bypassed |
| R8 | Operator without grant sees `••••`; with grant sees clear; after shred sees `:shredded` | resolution uses the recording actor's plane, or caches plaintext |
| R9 | Opening a replay without an active impersonation session is denied and writes nothing | the session check is removed |
| R10 | Every replay open writes one token-only `aud_event` | the audit write is dropped |
| R11 | Capture is off unless the org flag is on | the flag check is bypassed |
| R12 | Retention prunes replays past TTL | the replay spec is dropped from the sweep |

## 4. Phasing (one PR per lane, all off `main`, none stacked)

| Phase | PR | Content |
|---|---|---|
| P1 | A | §2.1 + this ADR; R1–R4 |
| P2 | B | §2.2; R5–R7, R11, R12 |
| P3 | B | §2.3; R8–R10 + masking three proofs |
| P4 | B | §2.4; tiers, mounts, docs |

PR B is opened only after PR A is on `main` (rebased onto it), never stacked on A.

## 5. Consequences

- **+** The plane that was built and guarded starts carrying data; every new signal inherits the
  existing bounded-type and pseudonym guarantees.
- **+** A session replay that is shred-correct by construction: it stores references, so a
  subject's erasure needs no replay-specific deletion.
- **−** Replays are lower fidelity than stock tools: free text and typed values show as shape
  only, unlisted strings are dropped, and referenced values are today's values.
- **−** Replay depends on current code; renamed/deleted view modules make old frames
  undecodable (TTL keeps the window short).

## 6. Decisions (taken 2026-10-09: the recommended option on each)

| # | Question | Options | Taken |
|---|---|---|---|
| D1 | Fix the dark plane first? | 1. Burn-down before replay (wide events, reveal span, `filter_parameters`, `:logger` tier, explicit LV `log:`) <br> 2. Fold into replay | **1** |
| D2 | How to get replay | 1. Rebuild in-house as `Samen.Replay`: record by reference, resolve at view time <br> 2. `phoenix_replay` dependency + custom sanitizer <br> 3. Skip | **1** |
| D3 | Form input in replays | 1. Shape only (key, type, length, class); values only for declared keep-lists <br> 2. Encrypt values under the acting user's DEK | **1** |
| D4 | Who may watch | 1. Watching opens/requires an impersonation session; plaintext only with a reveal grant; tenant admins replay their own org <br> 2. Operators only | **1** |

## 7. Out of scope

Client-side pointer/viewport/scroll capture; video export; LiveView streams and uploads (recorded
as counts only); historical field values via `Samen.Versioning`; operator-plane replay; replays
crossing org boundaries.
