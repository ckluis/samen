# ADR-052 — Turn the observability plane on, then add a session replay that never stores plaintext

- **Status:** **ACCEPTED (2026-10-09).** The operator read the evaluation and took the
  recommended option on all four decisions (§6: D1 (1), D2 (1), D3 (1), D4 (1)), with the
  ruling "be inspired by phoenix_replay, but rebuild it for our needs and our approach."
- **Date:** 2026-10-09
- **Build status:** **P1 BUILT** on `feat/adr-052-p1-telemetry` (2026-10-09): §2.1 items 1–3 and red
  paths R1–R4 (sabotages 405–409, plus 410–411), as-built notes in §2.1.1. The P1 gate's six
  follow-ups are closed in §2.1.2 (sabotages 414–420). P2–P4 not built.
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

### 2.1.1 P1 as built (2026-10-09) — and where it deviates

Built as §2.1 says, with these specifics and deviations (each with its reason):

1. **Wide events.** `Samen.Observability.LiveTelemetry`, attached by `child_specs/2` (opt out:
   `request_events: false`). New `Samen.WideEvent.Schema` fields: `view` (`:opaque_id`, the
   module name), `callback`, `outcome`, `method` (closed enums), `status` (`:number`), `event`.
   The ADR named `event` "an enum drawn from a bounded set"; as built it is `allowed: :open` with
   the set resolved per view by `Samen.Observability.LiveEvents` — the view's own
   `handle_event/3` string literals, read from its compiled debug info (or an explicit
   `__samen_live_events__/0`), else `:other`. A single global closed list was not possible: the
   event set is per host/view. To keep that from widening the schema, the `:open` sentinel is now
   **reserved** to `:action` and `:event` (any other field declaring it is a J2 violation).
   *Limitation:* `mix release` strips debug info by default, so a release reports `:other` for
   every event unless it keeps `Dbgi` or the view declares `__samen_live_events__/0`.
   `tenant_id` = the `:org_id` assign when it is a UUID; `actor_id` = `for_subject/2` of the
   `:samen_tenant_principal` assign, memoized per process. The request event needs
   `Plug.Telemetry` (`[:phoenix, :endpoint]`) in the host endpoint.
2. **Spans.** The single grant-gated chokepoint is `Samen.Reveal.reveal/5`; its whole gate runs
   in one `samen.reveal` span, so a denial is visible (error status = the bounded refusal atom).
   `reason` reaches the span only as an atom code — a free-text reason is not a trace attribute.
   *Not wrapped:* the operator-with-grant resolution in `Samen.Api.PiiResolution` and the
   internal system decrypts (TOTP, DSAR, AI agent) that call `Samen.Vault.reveal/3` directly.
   Jobs: instead of editing each worker, `Samen.Observability.JobSpans` (opt out:
   `job_spans: false`) opens an `oban.job` span per job from Oban's own telemetry, parented on
   the context `Samen.Jobs.enqueue_in_tx/4` now injects. *Remaining:* the ~40 enqueue sites that
   call `Oban.insert/2` directly carry no trace context (their job spans are roots).
   OTLP: `Samen.Observability.otlp_runtime_config/2`, called from the generated `--deploy`
   `runtime.exs`; `traces_exporter: :none` is now explicit in every host and generated app.
3. **Logger.** Keep-list `~w(id org org_id page per_page limit cursor after before sort sort_by
   order dir)` in demo/driftwood/pawchart/samen_web and both `Gen.App` config templates; demo
   gains a `prod.exs` (level `:info`). Tier `:logger` = `Samen.NoPlaintextPii.Tiers.LoggerGovernance`
   (also refuses a PII- or secret-named kept key, and fails closed on an unreadable prod config).
   **LiveView `log:` is not set per view** (deviation): with the keep-list in every env and the
   enforced prod floor at `:info`, LiveView's `:debug` event line never reaches a prod log and its
   params are filtered everywhere; editing ~80 framework LiveViews would add no guarantee.
   **Ash inspection — the builder check found a real leak:** Ash hides a `sensitive?` field on a
   record and redacts a `sensitive?` changeset argument, but prints a changeset *attribute*
   verbatim, so `inspect(changeset)` showed vault-routed plaintext until the vault write. Fixed at
   the type, as §2.1 required: `Samen.Type.VaultField.cast_input/2` holds plaintext as
   `%Samen.Pii.Plaintext{}` (`Inspect` → `**redacted**`). Consequence for adopters:
   `AshPhoenix.Form.value(form, :vaulted_field)` returns the wrapper before the write — open it
   with `Samen.Pii.Plaintext.unwrap/1` (done in the support composer and the AI fold indexer).
   Ash error structs never carried the value (`Ash.Error.Invalid` prints `#Changeset<>`).
   *Gate fix (P1 gate, 2026-10-09):* a scalar vaulted input re-renders correctly through the
   wrapper's `Phoenix.HTML.Safe` impl, but a component that destructures the value did not.
   `Samen.Web.CRM.Live.full_name_field/1` matched the wrapper with its `%{}` clause and
   re-rendered first/last BLANK after every validate. The Contact edit and Contacts create
   modals and driftwood's driver modals then resubmitted the blank and erased the stored name.
   It now unwraps the pending value first. Proven by a browser-emulating round trip (render
   after validate, scrape the DOM, resubmit) in
   `samen_web/test/samen/web/vault_form_roundtrip_test.exs` and
   `driftwood/test/broker_driver_form_roundtrip_test.exs`. A new component that pattern-matches
   a vaulted form value must unwrap it the same way.
4. **samen_web end-to-end proof** covers a real dead render (mount + handle_params) and
   `handle_event` metadata built on a real `%Phoenix.LiveView.Socket{}` for a real framework
   view. A *connected* LiveView test was not possible: no app in the repo carries `lazy_html`.

| Red path | Sabotage | Owning test file |
|---|---|---|
| R1 | 405 | `samen_core/test/observability/wide_event_live_fields_test.exs` |
| R2 | 406 | `samen_core/test/observability/live_telemetry_test.exs` |
| R3 | 407 | `samen_core/test/observability/reveal_span_test.exs` |
| R4 | 408 (filter), 409 (level) | `samen_core/test/observability/logger_tier_test.exs` |
| §2.1.3 Ash inspect | 410 | `samen_core/test/observability/vault_inspect_redaction_test.exs` |
| §2.1.1 handler never detaches | 411 | `samen_core/test/observability/live_telemetry_test.exs` |
| §2.1.1 gate: vaulted form round trip | 412 (framework), 413 (driftwood) | `samen_web/test/samen/web/vault_form_roundtrip_test.exs`, `driftwood/test/broker_driver_form_roundtrip_test.exs` |

### 2.1.2 P1 follow-ups (2026-10-09) — the six non-blocking gate findings, closed

1. **`request_id` was client-choosable (MEDIUM).** `Plug.RequestId` adopts any client
   `x-request-id` of 20–200 bytes, and `LiveTelemetry` copied it into every event. Now the id
   lands verbatim only when `Plug.RequestId.generate/0` made it *in this process*: exactly 20
   url-safe base64 characters decoding to `<<nanos::64, phash2({node(), self()}, 2^24)::24,
   unique::32>>` with the hash matching `self()`, and, for a request (conn in hand), equal to no
   request-header value under any header name. That id is the response header, so correlation is
   kept. Anything else becomes `sub_` + HMAC-SHA256 under a random per-node key (16 url-safe
   chars). *Why a keyed hash, not a fresh id:* events carrying the same client id still group
   together on that node, and an unkeyed hash of a low-entropy client string (an email) could be
   reversed by dictionary. *Why not a framework plug that always generates:* it would mean an
   endpoint edit in every host; the provenance check needs none. A client cannot pass the check
   without the server's process hash (2^-24 per blind guess, no oracle). Tests:
   `samen_core/test/observability/live_telemetry_test.exs` (request_id describe),
   `samen_web/test/samen/web/request_id_provenance_test.exs` (real `Plug.RequestId`).
   Sabotage **414**.
2. **A kept `filter_parameters` key kept nested values (LOW).** Phoenix offers no hook into
   `filter_values/2`, so `Samen.Observability.ParamFilter` (in `child_specs/2`, default ON,
   `param_filter: false` opts out) re-attaches every `Phoenix.Logger` and
   `Phoenix.LiveView.Logger` handler under its own id, wrapped. The wrapper filters
   `params` / `conn.params` first, keeping a kept key's value only when it is a scalar. Phoenix's
   keep filter then runs over values that are already scalar or `[FILTERED]`. LiveView's mount
   session, which LiveView printed unfiltered, gets the same keep-list. If the sanitizer fails,
   the whole value is `[FILTERED]`; raw params are never passed on. Proven against real
   `Phoenix.Logger.filter_values/2` and Phoenix's own handlers, with a positive control showing
   the leak without the wrap: `samen_web/test/samen/web/param_filter_logging_test.exs`. Sabotage
   **415**.
3. **runtime.exs could lower the prod level (LOW).** The `:logger` tier now reads
   `config/runtime.exs` **statically**. Evaluating it would need the deploy's secrets (the
   generated one raises on a missing `DATABASE_URL` by design), and it would still prove only the
   env vars the check happened to pick. The tier fails closed. Every level runtime.exs can set
   must be a literal at or above `:info`: `config :logger, …` (any depth, handler sub-keys
   included), `Logger.configure`, `Logger.put_*_level`, and `:logger.set_*`/`update_*`. The one
   exception is the new clamp `Samen.Observability.prod_log_level(System.get_env("LOG_LEVEL"))`,
   whose result is always `:info` or above. A non-literal option list or an unparsable file is a
   violation. No host in the repo has a runtime.exs; the generated `--deploy` one passes. Tests:
   `logger_tier_test.exs` (runtime describe) and `logger_tier_runtime_wiring_test.exs`
   (`check/1` against a throwaway host project). Sabotages **416** (decision) and **417**
   (`check/1` wiring).
4. **~45 µs per LiveView callback (LOW, perf).** Each value was validated three times: once
   per field through `WideEvent.new/1`, again by `new/1` in `emit/2`, and again by `emit/1`.
   `WideEvent.emit(fields, :best_effort)` now validates each value exactly once and drops a
   value that fails its type, as the per-field pre-check did. The struct is built from passing
   values only, so it skips `emit/1`'s re-validation (which still applies to a struct built
   elsewhere). `:build` no longer re-validates the struct `new/1` just built, and the schema
   lookups are compiled maps. The build-time `sink_schema` check is unchanged.
   **Measured** (`handle_event` callback with view, tenant and request id, 7×50k runs, median):
   **56.6 µs → 19.1 µs**. `PiiValueShape.pii_shaped_id?/1` calls per callback: **17 → 5** (one
   per id field plus the two open-enum labels; pinned by a trace-session test in
   `live_telemetry_test.exs`). Perf only: no sabotage.
5. **Reveal span ids were length-capped, not shaped (LOW).** `subject_id` / `grant_id` reach
   the span only as a UUID string, a ULID string or an integer key. Any other string is dropped,
   including a digit string (a phone number has that shape). Test: `reveal_span_test.exs` (id
   describe). Sabotage **418**.
6. **Job rows carried the global propagator's output (LOW).** `Samen.Tracer.job_trace_headers/0`
   injects through `:otel_propagator_trace_context` only (`traceparent`/`tracestate`), never the
   SDK's default `[trace_context, baggage]` composite. A host adding `opentelemetry_phoenix`
   would otherwise write the client's `baggage` header into `oban_jobs.meta`.
   `attach_job_trace_context/1`, used by `JobSpans` and `with_job_span/3`, extracts the same two
   headers only, so a baggage pair already stored in a row is ignored. The `oban_jobs` tier
   stays green. Tests: `job_spans_test.exs` (W3C describe, with positive controls showing that
   the global propagator would carry and restore the baggage). Sabotages **419** (inject) and
   **420** (extract).

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
