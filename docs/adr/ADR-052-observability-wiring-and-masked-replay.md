# ADR-052 — Turn the observability plane on, then add a session replay that never stores plaintext

- **Status:** **ACCEPTED (2026-10-09).** The operator read the evaluation and took the
  recommended option on all four decisions (§6: D1 (1), D2 (1), D3 (1), D4 (1)), with the
  ruling "be inspired by phoenix_replay, but rebuild it for our needs and our approach."
- **Date:** 2026-10-09
- **Build status:** **P1 BUILT** on `feat/adr-052-p1-telemetry` (2026-10-09): §2.1 items 1–3 and red
  paths R1–R4 (sabotages 405–409, plus 410–411), as-built notes in §2.1.1. The P1 gate's six
  follow-ups are closed in §2.1.2 (sabotages 414–420). **P2 BUILT** on `feat/adr-052-replay`
  (2026-10-09, local, on top of P1): §2.2 capture, red paths R5–R7, R11, R12 (sabotages
  421–435), as-built notes and deviations in §2.2.1. **P3 BUILT** on `feat/adr-052-replay`
  (2026-10-09, local): §2.3 player + who may watch, red paths R8–R10 plus tenant authz, inert
  rendering and decode safety (sabotages 441–460), as-built notes and deviations in §2.3.1.
  **P4 BUILT** on `feat/adr-052-replay` (2026-10-09, local): §2.4 tiers (`:replay`,
  `:post_shred_replay`, wired into the Driftwood crypto-shred game-day), the nine P3 gate notes,
  replay ON in Driftwood dev, runbook and guide (sabotages 465–489; 441/442/446/460
  re-anchored), as-built notes in §2.4.1. The P4 gate's flag-ownership fix (a flag resolves
  from the operator org's rows only) is §2.4.1 item 7 (sabotages 490–494). **All phases BUILT.**
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

### 2.2.1 P2 as built (2026-10-09) — and where it deviates

Built as §2.2 says. Every design choice the section left open, and every deviation, with its
reason:

1. **Where the recorder attaches (≈0 LOC).** `Samen.Web.Replay.Recorder` is attached by
   `Samen.Web.TenantAuthz` itself, on its two TENANT legs (armed and disarmed), not by a second
   `on_mount` entry in each route macro. Every framework tenant `live_session` already carries
   `{TenantAuthz, :require_tenant}`, and so do the hosts' own tenant sessions
   (`:driftwood_broker`, `:pawchart_clinic`); a second entry would have missed those. The
   operator leg never attaches, and the recorder refuses any mount that is not an explicit
   tenant-plane `%Samen.Web.Mount{}` (two layers; sabotage 425 proves the inner one).
   `on_mount {Samen.Web.Replay.Recorder, :record}` exists for a host that wants it explicitly.
   Connected, top-level LiveViews only (no `live_render` children).
2. **Deciding needs the org, which arrives late.** On a disarmed host the org is a
   `handle_params` value, so the hooks start `:pending` and decide at the first callback that
   sees a UUID `:org_id` / `:samen_tenant_org_id` (else off after 3 callbacks). The decision is
   `Samen.FeatureFlags.evaluate("samen.replay", %{org_id: org}, emit: false)` AND the sample
   draw. Off ⇒ every recorder hook is DETACHED (sabotage 434), so a non-opted-in LiveView pays
   nothing after that. The flag is not seeded anywhere: an unknown flag is OFF.
3. **Capture plane.** `Samen.Observability.child_specs(app, replay: true | [opts])` adds ONE
   `Samen.Replay.Supervisor` (task supervisor, `Samen.Replay.Monitor` owning the ETS buffer,
   the event handler); without `replay:` the child list is unchanged (tested like the F5.1
   metrics no-op). No host turns it on in this phase. Options and defaults: `sample_rate` 1.0,
   `max_frames` 500, `max_bytes` 512 KiB (external term size of sanitized payloads),
   `max_sessions` 1 000 per node (a buffer memory cap the ADR did not name), `retention_days`
   14 (1..90; outside ⇒ `ArgumentError` at `child_specs/2` build time). A cap truncates with
   ONE `:truncated` frame naming it; a truncated session stops sanitizing renders.
4. **Frames.** Kinds `mount` (view module, view MD5, `live_action`, sanitized assigns),
   `params` (the matched ROUTE TEMPLATE from `Phoenix.Router.route_info/4` — never the concrete
   path, whose segments can be slugs — and params as shape), `event` / `component_event`
   (bounded label + params shape, from LiveView's `:start` telemetry, so events halted by
   another hook are seen), `render` (only the `__changed__` assigns), `info` (a label-shaped
   atom tag, else nothing), `exit` (`normal | shutdown | killed | crash` — never the exit term)
   and `truncated`. The event label is the view's own `handle_event` literal (P1
   `LiveEvents`), else a key the view DECLARED in its keep-list (a developer literal), else
   `"other"`.
5. **Keep-list API.** `use Samen.Replay, keep_assigns: [...], keep_params: %{"event" =>
   ["param"]}, keep_url_params: [...]`; declarations accumulate (a mixin and the view) into one
   `__samen_replay__/0`. A kept assign string must still be ≤ 120 codepoints, printable and not
   email/SSN/phone-shaped; a kept param value must be an integer, a boolean, a UUID or a member
   of a declared closed set (item 13). The framework declaration is in the `Samen.Web.ListLive`
   mixin (31 list views): `sort`/`field` (closed: the view's `:sortable` names),
   `paginate`/`dir` (`next`/`prev`), `bulk`/`action`, `select`/`restore` `id` — never the
   `filter` text. No
   framework LiveView assigns `:page_title`, so none declares it (the ADR's example).
6. **Sanitizer decision table** (`Samen.Replay.Sanitizer`, tier-1 mutation target, 61/61
   mutants killed): vault-routed attribute of an Ash record → `Ref` (the value — tenant CLEAR,
   `Plaintext`, `Masked` — is never read); other attributes kept only when
   `Samen.Cdc.Projection.classify_columns/2` gives a structural value kind (`bounded_id`,
   `enum`, `timestamp`, `number`, `boolean`; a cleared `metadata` column is a `Ref`, item 13) —
   `plaintext_pii`, `token` or any unknown kind ⇒
   `Redacted{:free_text, length}`; a `sensitive?` attribute is never kept; loaded relationships
   recurse; calculations and aggregates are not captured. Bare: UUID → `Id`; other strings,
   non-UTF-8 binaries, printable charlists → `Redacted`; numbers, booleans, `nil`,
   dates/times, decimals, label-shaped atoms kept; scope, actor maps (`:plane` + an id) and the
   framework actor/principal assigns, sockets, PIDs, refs, funs dropped; streams and uploads
   as counts; maps/lists/tuples recurse under a depth cap of 8, 50 items per level and 5 000
   nodes per capture. Map keys survive only as atoms or label-shaped, non-PII strings; else
   positional `"$kN"`. Each top-level assign is sanitized under its own rescue.
7. **Bare `%Samen.Masked{}` → `Redacted{kind: :masked, label}`, the `vt_*` token dropped**
   (§2.2 rule 1 said "kept as-is"; deviation). Checked first: the DB tiers (`aud_event`,
   `oban_jobs`) and the post-shred `db_content` oracle do treat a `vt_*` token in a non-vault
   table as allowed — shredding the DEK makes it undecryptable. But a bare token has no
   resource or primary key, so P3 could only resolve it through `Samen.Vault.reveal/3`
   directly, outside the grant check `PiiResolution` keys on subject + resource + reveal
   action; storing it would add a 14-day, cross-table-linkable handle with no governed way to
   use it. A `Masked` INSIDE a record is a `Ref` (the record supplies the provenance).
8. **List-row provenance (the finding §2.2 asked for).** `Samen.Web.ListLive` keeps the
   `%Samen.Web.Page{}` whose `items` are the plane-resolved Ash RECORDS themselves (PII
   resolution rewrites fields in place on the struct), so provenance survives: `Page` is on the
   sanitizer's walk-list and each row becomes a `Record` with `Ref`s (proven on the real
   ContactsLive). Where the kit has already flattened rows into non-record terms provenance is
   lost and the sanitizer redacts: `Samen.Web.GeoSet` markers (a plaintext `label` on a plain
   struct) drop as an unknown struct; ContactsLive's `company_names` map keeps its UUID keys and
   redacts the names; `ListState` (its `filter` is typed text) drops; forms
   (`Phoenix.HTML.Form`) drop. Walk-list is extensible by config
   (`config :samen_core, Samen.Replay, walk_structs: [...]`).
9. **Storage (the `Samen.AI.Domain` precedent).** `Samen.Replay.Session` (`rps`) and
   `Samen.Replay.Frame` (`rpf`) are framework-owned `Samen.Resource`s in `Samen.Replay.Domain`,
   abbrevs reserved with `mix samen.abbrev.reserve --host samen_core`; repo via
   `:samen_replay_repo` (compile-time). DDL + catalog rows live once in
   `Samen.Replay.Migration` (the `DeliverabilityMigration` two-line-delegate shape); mounted in
   the samen_core test repo, samen_web, driftwood, pawchart and the `Samen.Gen.App` web/api
   templates (demo serves no tenant LiveViews). Frames cascade with their session. Payload is
   JSONB. Writes are kernel-only (`forbid_if always()` for any authorized create/destroy);
   reads are `OrgScope`d. Persisted only with ≥ 1 user interaction.
10. **Frame schema, enforced twice.** `Samen.Replay.FrameSchema` declares envelope, per-kind
    payload, every tree marker (`$ref`, `$redacted`, `$dropped`, `$kept`, `$id`, `$atom`, `$dt`,
    `$dec`, `$record`, `$count`, `$more`, `$tuple`, `$shape`) and the shape entry, with bounded
    types (`opaque_id`, `enum`, `number`, `boolean`, `timestamp`, `tree`, `shape`, and the one
    text type `keep_listed` with `max_length` ≤ 200). `mix samen.verify.replay_schema` runs in
    the same CI step as `sink_schema` (demo, driftwood, pawchart, both generated `ci.sh`).
    Beyond the ADR: the store validates every ENCODED frame against the same declaration and
    refuses one with a bare string anywhere in its tree (counted in `rejected_count`, never
    stored); the encoder passes a bare string through unchanged precisely so the validator, not
    a silent rewrite, catches a sanitizer bug.
11. **Session actor** = `Samen.WideEvent.for_subject/2` of the `:samen_tenant_principal`
    assign (the P1 pseudonym); no live subject key ⇒ no actor recorded.
12. **Never crashes, measured cost.** Recorder hooks rescue into "off"; the event handler
    rescues (a raising `:telemetry` handler is detached — sabotage 430); buffer calls return
    `:error` without a table. Measured on the real ContactsLive (median of 2 000): an
    `after_render` whose changed assigns hold a 50-row page of Person records costs **~178 µs**
    with capture on (≈ 3.5 µs per record) and **< 1 µs** when off; a recorded form event
    **~15 µs**; an unrecorded LiveView's event **< 1 µs** (one ETS lookup).

13. **Gate fixes (2026-10-09, adversarial P2 gate).** The gate drove a real ContactsLive
    session and scanned the raw rows; five defects, each fixed with a red-before test and a
    sabotage:
    - *Client strings in frames (BLOCKING).* A URL query key, an event param key, a sort value
      outside `:sortable` and a non-id `select` id — all label-shaped (`"Sortvaluesecret"`,
      `"Jane.Selectsecret"`) — were stored verbatim: "label-shaped, not PII-shaped" is passed by
      a name. Now a kept param value is an integer, a boolean, a UUID, or a member of the
      declared closed set (`keep_params: %{"paginate" => [{"dir", ["next", "prev"]}]}`; a bare
      name keeps no string but a UUID). A param key or an assigns map key survives only as a
      server-known identifier — an existing atom, a UUID, or a list index of ≤ 3 digits — so
      neither a client nor a row (a name used as a map key) can write its own string. Sabotages
      **436** (values), **437** (keys); proof on the real view in `replay_recorder_test.exs`.
    - *Bypassable last line (BLOCKING).* The frame-schema check ran only inside
      `Samen.Replay.Store`; a direct `Ash.create(authorize?: false)` (which skips
      `forbid_if always()`) stored a frame holding a plaintext name and a session whose `view`
      was that name. `Samen.Replay.RowGuard` now validates every `:record` create, single or
      bulk, on both resources: the frame against `FrameSchema`, `view` a code identifier,
      `view_md5` hex MD5, `actor_ref` the 64-hex pseudonym. Tier-1 mutation target (6/6).
      Sabotage **438**; `samen_core/test/replay/row_guard_test.exs`.
    - *An org switch kept recording (R11).* The decision is per org, but a recorded LiveView that
      re-resolved to another org (`?org=`, the org switcher) went on recording into the first
      org's session, whatever the second org's flag said. Recording now stops at once (buffer
      row dropped, hooks detached); the opted-in org's frames still persist. Sabotage **439**.
    - *Cleared columns outlived erasure.* A `non_pii!`-cleared freeform column (driftwood's
      `drv_cdl_state`, which the erasure arm overwrites on shred) was copied into frames as
      `$kept` text. A cleared `:metadata` column is now a `Ref` (by reference, so erasure
      reaches it like a vault field). Sabotage **440**.
    - *A DB query on the render path.* `classify_columns/2` read the `non_pii!` registry from
      Postgres inside the LiveView process (first render per resource). The sanitizer now
      passes no registry entries unless injected: without a clearance every freeform column is
      shape only — stricter than the CDC mirror, never looser, and no render waits on the DB.
    Sanitizer mutation: 73/73 killed after the change. Sabotages 421–423 re-anchored (same
    semantics).

*Not done in P2 (by design or deferred):* no host enables the capture plane; the `:replay`
`no_plaintext_pii` tier and the post-shred check are P4; there is no player (P3). A
`live_render` child LiveView is not recorded. A release that strips debug info records
`"other"` for undeclared events (the P1 `LiveEvents` limitation, inherited).

| Red path | Sabotage | Owning test file(s) |
|---|---|---|
| R5 vault value never stored | 421 | `samen_core/test/replay/sanitizer_test.exs`, `samen_core/test/replay/capture_test.exs` (raw JSONB scan); end to end over ContactsLive: `samen_web/test/samen/web/replay_recorder_test.exs` |
| R6 freeform is shape only | 422 | `samen_core/test/replay/sanitizer_test.exs` |
| R7 param values shape only unless keep-listed | 423 | `sanitizer_test.exs`, `capture_test.exs` |
| R11 off unless the org flag is on | 424 (flag), 425 (operator plane), 434 (hooks detach when off) | `capture_test.exs`, `replay_recorder_test.exs` |
| R12 retention prunes past TTL | 426 | `capture_test.exs` |
| frame schema / validator | 427 (build check), 428 (store skips validation), 429 (bare string in tree) | `frame_schema_test.exs`, `capture_test.exs` |
| capture guards | 430 (handler rescue), 431 (frame cap), 432 (interaction rule), 433 (raw actor), 435 (changed-only renders) | `capture_test.exs`, `replay_recorder_test.exs` |
| gate fixes (item 13) | 436 (closed keep values), 437 (server-known keys), 438 (row guard), 439 (org switch), 440 (cleared by reference) | `sanitizer_test.exs`, `capture_test.exs`, `row_guard_test.exs`, `replay_recorder_test.exs` |

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

### 2.3.1 P3 as built (2026-10-09) — and where it deviates

Built as §2.3 says. The choices the section left open, and the deviations:

1. **Kernel / web split.** `samen_core` holds everything that touches data:
   `Samen.Replay.Decoder` (stored frame → capture vocabulary), `Samen.Replay.Resolver` (the
   view-time resolver), `Samen.Replay.Placeholder`, `Samen.Replay.Player` (list, load, fold,
   timeline, drift, audit). `samen_web` holds who may watch (`Samen.Web.Replay.Access`), the
   inert renderer (`Samen.Web.Replay.Renderer`) and the two LiveViews
   (`Samen.Web.Replay.IndexLive`, `Samen.Web.Replay.PlayerLive`, chrome in
   `Samen.Web.Replay.Live`). Both chokepoints are tier-1 mutation targets: resolver 14/14,
   access 11/11 killed.
2. **Decode safety.** Every stored frame is re-validated against `FrameSchema.validate/1`
   before anything in it is decoded; a row that fails becomes ONE `:invalid` frame
   ("unreadable frame" on the timeline). No stored string becomes a new atom: module names,
   attribute names, map keys and `$atom` values go through `String.to_existing_atom/1` under a
   rescue (`Decoder.existing_atom/1`, `Decoder.module/1` also requires the module to be
   loaded). An unknown module, atom or marker decodes to a `:code_changed` placeholder; an
   unknown map key is dropped; a bare stored string (the validator refuses one) decodes to a
   `:redacted` placeholder, so no stored free string reaches a template. Closed-set fields
   are matched as strings. Sabotages 455 (new atoms), 456 (schema skipped).
3. **Resolution (R8).** `Resolver.resolve/3` collects the tree's `Ref`s, reads each
   referenced resource ONCE per call with `Ash.read(scope: viewer_scope)` (pk `in` the
   referenced ids, ≤ 500), and passes each row through `Samen.Api.PiiResolution.resolve/4`
   with the VIEWER's actor. Beyond the ADR, a belt over the resource's own policies: a row
   whose `org_id` is not the viewer's (or a viewer scope with no org) is `:gone`, so a
   resource that declares no org policy still cannot leak across orgs. On the operator plane
   each record's resolution runs inside `Samen.Tracer.with_reveal_span/3`
   (`samen.reveal`, `subject_id` + `reason: "replay"` only) — PiiResolution's granted path
   calls `Samen.Vault.reveal/3` directly, outside `Samen.Reveal.reveal/5`'s span, so the
   resolver opens it. Outcomes: plaintext → the value (`:clear`); `%Masked{}` →
   `Placeholder :masked` (`••••`; the `vt_*` token never reaches a template) unless the KMS
   attests the subject (the record's pk, the `Samen.Vault.Change` subject) `:shredded` →
   `Placeholder :shredded` (`[erased]`); a KMS that cannot attest never claims shredded; row
   absent/unreadable/other org → `:gone`; resource no longer an Ash resource, or the
   attribute no longer vault-routed (`Samen.Pii.Info.pii_attributes/1` ∪ the sanitizer's
   `:ref` plan) → `:code_changed`. Nothing is cached: each frame batch reads and resolves
   again (no table, log, ETS or process dictionary), so a lapsed grant or a closed session
   takes effect on the next batch. The player labels resolved values CURRENT (banner +
   reference table "current value"). Sabotages 441/442 (recording plane), 443/444 (cache),
   445 (shred), 446 (cross-org row), 460 (no reveal span).
4. **Who may watch (R9).** `Access.authorize/3`, called for every list, every open and every
   frame batch:
   - operator (`scope_kind: :operator` mount, i.e. `samen_operator_routes/2`, behind T146):
     `Samen.Web.Operator.Impersonation.gate_socket/3` — the per-tenant drill-in gate, with the
     R-B scope conjunct; the viewer scope IS the impersonation actor (`plane: :operator`, the
     real session marker, member-equivalent, no grant). No session → `:no_session` (the
     refusal card offers the reason-required open-session form, as `ActivityLive` does);
   - tenant (a tenant-plane mount, i.e. `samen_settings_routes/3`, behind `TenantAuthz`): the
     org must be in the principal's pinned authorized set (armed hosts; `:cross_org`
     otherwise), the principal's real `Identity.Membership` role in THAT org must be
     `Samen.Scope.Role.at_least?(role, :admin)` (owner or admin; `:not_admin` otherwise).
     An operator-plane settings mount is refused (`:operator_plane`).
   A refusal renders nothing of any replay and writes nothing. A batch that fails the
   re-check STOPS playback: frames, the rendered frame and the reference table are dropped
   from the socket; later batches render nothing. Sabotages 447 (no session check), 448 (no
   per-batch re-check), 451 (member may watch), 452 (cross-org), 459 (list unauthorized).
5. **The audit row (R10).** One `Samen.AuditChain.Writer.write/2` per open (its PII-reason
   scan runs on `detail`), on the replay org's chain: `event_type "replay.viewed"`,
   `subject_id` = replay session id, `actor_id` = the viewer's id (operator id, or the tenant
   principal's user id), `correlation_id` = the impersonation session id (operator) / `nil`
   (tenant), `detail` = `"event=replay.viewed plane=<operator|tenant>"`. *Deviation:* the ADR
   said "viewer pseudonym"; `aud_event` convention everywhere else is the actor's opaque id
   (operator id, approver user id), and the HMAC pseudonym is the wide-event/trace
   convention, so the id is used. The open happens on the CONNECTED mount only (the dead
   render reads and writes nothing), so one page open is one row; stepping frames writes
   none. If the audit write fails the player fails closed (nothing shown). Sabotages 449
   (audit dropped), 450 (dead render opens).
6. **Rendering (zero side effects).** For frame *i* the player folds the mount frame's
   assigns with every later render frame's changed assigns, resolves, and calls the recorded
   view's CURRENT `render/1` (`__changed__: nil`) under `rescue`/`catch` — since the P3 gate
   in a throwaway process with a heap cap and a deadline (item 10). The resulting string is made inert — `<script>` elements removed,
   `phx-*` and `on*` attributes stripped inside tags, `javascript:` neutralised — and wrapped
   in a document with a `default-src 'none'` CSP and the kit stylesheet (inlined at compile
   time), shown in `<iframe srcdoc sandbox="">` (no `allow-scripts`, no
   `allow-same-origin`). No socket, no handler, no LiveSocket: nothing can be re-driven.
   Context the recorder never stores is supplied from code, not data: `samen_mount` is the
   mount the HOST router routes the recorded view with (route metadata, preferring the
   recorded route template), rebuilt on the VIEWER's plane; a dropped struct becomes its
   module's DEFAULT struct (never `Samen.Scope`, a socket or an Ash resource); records are
   rebuilt as the current resource struct with the captured fields. A template that raises
   (e.g. the new-contact form, which the recorder drops) shows a placeholder for that frame
   and playback continues. Placeholders (`Samen.Replay.Placeholder`) implement
   `Phoenix.HTML.Safe`, `String.Chars`, `Inspect`, `Jason.Encoder`: `▒▒▒ (n)`, `••••`,
   `[erased]`, `[gone]`, `[changed]`, `▒ n items`. Sabotages 453 (not inert), 454 (sandbox
   allows scripts), 457 (raise escapes).
7. **Code drift and timeline.** `Player.drift/1`: `:same` when `Capture.md5/1` of the loaded
   view equals the stored MD5, `:changed` otherwise, `:missing` when the module is gone or has
   no `render/1`. The timeline lists each frame with a bounded label (kind + the validated
   event/route/tag/reason) and marks gaps: missing `seq` (frames refused at persist) and idle
   periods over 5 s. Step, scrub (range input), seek (timeline) and play (a 900 ms tick) are
   all batches. The UI uses the kit (`app_shell`, `topbar`, `token_blind_bar`, `pill`,
   `data_table`, `empty_state`) and collapses to one column under 900 px (ADR-030).
8. **Mounts (≈0 authored LOC).** `/operator/replays/:org_id` and
   `/operator/replays/:org_id/:id` ride `samen_operator_routes/2`'s live_session (T146
   on_mount); `/settings/replays` and `/settings/replays/:id` ride `samen_settings_routes/3`
   (`TenantAuthz`). driftwood and pawchart already call both macros, so they adopt at 0 lines
   (route + gate proofs in each: `replay_player_mount_test.exs`); the samen_web test hosts
   carry them through `SecurityRouter` / `FleetCockpitRouter`. Links: the account drill-down
   ("Replays →") and the settings sidebar ("Session replays"). The player opts out of the
   recorder (`Samen.Web.Replay.Recorder.opt_out/1`) — watching a replay is never recorded
   (sabotage 458). §2.4's separate `samen_replay_routes` macro is therefore not needed.
9. **Masking watch-list.** The three proofs over a REAL recorded ContactsLive session and the
   vault-routed `Samen.WebTest.Crm.Person` (`samen_web/test/samen/web/replay_player_test.exs`,
   `use Samen.MaskingCase`): green (tenant admin; operator with a real `Samen.Reveal.Grants`
   grant) clear; red (operator without a grant) `assert_masked_dom!` on the srcdoc and on the
   whole player page — `••••`, no plaintext, no `vt_`; sabotage twin (the same row flipped to
   the tenant plane leaks and the scan catches it). Kernel proofs in
   `samen_core/test/replay/player_test.exs`.

10. **P3 gate fixes (2026-10-09).** The adversarial gate wrote hostile rows straight into
    `replay_frame` with raw SQL (past the store and `RowGuard`) and found ONE blocking class:
    a stored row could choose a code path the recorder never writes. (a) The resolver rebuilt
    ANY loaded struct a `$record` named — a 552-byte frame naming `Range` (1..2,000,000) made
    `Samen.Web.AI.AgentLive` render a 137 MB srcdoc in 5 s and +246 MB of memory; 1..10¹² never
    ends (a hung player, then an OOM node); a LiveView `Rendered`/`Comprehension` would render
    raw. `build_struct/2` now rebuilds only an Ash resource or a sanitizer walk-list struct
    (`Samen.Replay.Sanitizer.walk_structs/1`, now public), anything else `:code_changed`.
    (b) A `$tuple` of `$atom safe` + `$kept` decoded to `{:safe, iodata}` and rendered raw (a
    `<meta http-equiv=refresh>` that navigates the sandboxed frame): the resolver turns any
    `{:safe, _}` into a `:redacted` placeholder. (c) Data can still drive a loop the template
    owns (`1..@count`), so the renderer no longer trusts input size at all: `render/2` runs the
    template in a throwaway monitored process with a 64 MiB heap cap (`max_heap_size`, shared
    binaries included, `kill: true`) and a 3 s deadline (`Renderer.budget/0`); over budget →
    `:render_failed`, the player lives. (d) `inert/1` also strips `<meta>`, `<base>` and
    `<link>` — elements that act with no script, which neither the CSP nor `sandbox=""` stops.
    The parent page was never at risk: HEEx attribute-escapes `srcdoc` (a `"'><script>
    </iframe>` full name round-trips byte-exact through the attribute), and the srcdoc
    document is `sandbox=""` + `default-src 'none'`. Resolver 16/16 mutants killed after the
    change. Sabotages 461 (any struct), 462 (`{:safe, _}` passes), 463 (render unbounded), 464
    (meta kept); 453 and 457 re-anchored onto the bounded renderer with the same semantics
    (457 also lets the render process's crash become the player's — the isolated render would
    otherwise absorb the reraise and the guard would go vacuous).

11. **Placeholder cells (follow-up, 2026-10-10).** Item 6's placeholders reached the frame, but
    the framework's vault-cell renderers matched only `%Samen.Masked{}`: a `%Placeholder{}` fell
    to their "no value" clause, so a masked or erased email/phone printed "—" (the glyph of a
    contact with NO email; landing claim RP12), a gallery/ticket name fell back to the display
    name/handle, and the AI grounding preview printed `inspect/1` output. Not a leak; a fidelity
    lie. Fixed framework-first: `Samen.Web.ObjectRef.FieldValue.opaque/1` (a guard: `%Masked{}`
    or `%Placeholder{}` — present, not shown to this viewer) is the one test; `FieldValue`'s
    `email/phone/full_name/generic` pass an opaque value through, the five CRM views' private
    copies (byte-identical to `FieldValue`'s) now delegate to it (`ContactsLive`, `ContactLive`,
    `CompanyLive`, `ContactsGalleryLive`, `LeadsLive`), and the renderers with their own
    semantics match the guard (`Operator.Live`, `Support.TicketLive`, `AI.CrmLive`,
    `Chat.Components`, `DefaultCard`, the CRM initials avatars). Live rendering is unchanged (the
    plane masking suites stay green). Proof per renderer on the player's own path
    (`Renderer.render/2`) in `samen_web/test/samen/web/replay_placeholder_cells_test.exs`, with an
    empty-email positive control, and end to end over the real recording in
    `replay_player_test.exs`. Sabotage 495 (guard back to `%Masked{}` only).

*Not done in P3:* no `:replay` `no_plaintext_pii` tier and no post-shred replay check (P4);
no host turns the capture plane on; the player cannot show a `live_render` child or a stream's
rows (counts only, §7); a view whose template needs a value the recorder dropped (a form) shows
a placeholder frame; the player's controls need the LiveView client (the frame itself needs
nothing).

| Red path | Sabotage | Owning test file(s) |
|---|---|---|
| R8 viewer's plane, grant, shred, no cache | 441, 442, 443, 444, 445, 446, 460 | `samen_core/test/replay/player_test.exs`, `samen_web/test/samen/web/replay_player_test.exs` |
| R9 impersonation session, per-batch re-check | 447, 448 | `replay_player_test.exs` |
| R10 one token-only aud_event per open | 449, 450 | `replay_player_test.exs`, `player_test.exs` |
| tenant: admin-class, same org | 451, 452 | `replay_player_test.exs` |
| inert rendering | 453, 454, 457, 458 | `replay_player_test.exs` |
| list authorized like an open | 459 | `replay_player_test.exs` |
| decode safety | 455, 456 | `player_test.exs` |
| P3 gate: a stored row picks no code path (struct, raw markup, unbounded render, meta) | 461, 462, 463, 464 | `player_test.exs`, `replay_player_test.exs` |
| placeholder cells render as the placeholder, never "—" (item 11) | 495 | `replay_placeholder_cells_test.exs`, `replay_player_test.exs` |

### 2.4 P4 — mounts, tiers, docs

- Framework mount (`samen_replay_routes/…`) adopted by driftwood, pawchart and demo at ≈0
  authored LOC (leverage guard).
- `no_plaintext_pii` gains a **`:replay`** tier (no plaintext in replay tables) and a post-shred
  check (a shredded subject's refs resolve to `:shredded` in every stored replay).
- `docs/observability-guide.md` gains §5 Replay; this ADR's build status is updated per phase.

### 2.4.1 P4 as built (2026-10-09) — and where it deviates

1. **Mounts.** Already done in P3 (§2.3.1 item 8): the player rides `samen_operator_routes/2`
   and `samen_settings_routes/3`; no `samen_replay_routes` macro. demo serves no tenant
   LiveViews and mounts no replay tables, so it adopts nothing.
2. **`:replay` tier** (`Samen.NoPlaintextPii.Tiers.Replay`, CI mode, in `default_tiers/0`).
   Over every stored row (keyset pages, not a sample; rows are bounded by retention): every
   frame passes `FrameSchema.validate/1` (no bare free string, nothing undeclared, every
   identifier exactly what the sanitizer emits); every session row is what the kernel writes
   (module-name `view`, hex MD5, 64-hex `actor_ref`, bounded exit); and no referenced
   subject's plaintext is in any row. That last check takes every subject a frame references
   (`$ref`/`$record` pk, `$id`), decrypts its vault rows through `Samen.Vault.reveal/3`, and
   searches every string of every replay row (keys too) for each plaintext value (string
   leaves of 4+ characters; a date must match exactly; id-shaped strings are never hits), plus
   any caller-SEEDED probe (new `Context` field `plaintext_probes`). A finding names the row,
   never the value. It fails closed on a missing repo, a half-mounted store, a read error, a
   KMS outage (an erased or never-keyed subject is fine: nothing left to leak) and more than
   5 000 referenced subjects. A host without the tables gets no finding.
   *Stored-row validation:* the schema accepts a key only when it names an existing atom, and
   in a fresh process (the oracle CLI) a key that only a not-yet-loaded module defines does
   not exist yet. A frame that fails is re-checked once after every module of every loaded
   application is loaded (what a release does at boot). The game-day CLI hit exactly this
   before the fix.
3. **Post-shred check** (`Samen.NoPlaintextPii.Tiers.PostShred.Replay`, `:post_shred_replay`,
   in `post_shred_tiers/0`). For the erased subject it proves three things. Every stored frame
   that mentions it passes the schema. Every reference to it, decoded and resolved by the
   player's own `Resolver` on the frame org's TENANT plane (the plane that reads CLEAR, so a
   shred that did not take shows as plaintext, not as a mask), comes back `:shredded`.
   `:gone`/`:code_changed`/`:empty` count only while the KMS attests the subject shredded.
   And no seeded probe appears in any row. It always reports, `:pass` or `:violation`.
   Post-shred the subject's plaintext cannot be recomputed, which is why the value search
   takes the caller's probes. *Game-day:* `Driftwood.CryptoShredGameday.seed_driver_across_tiers/1`
   now records the driver in a replay through the real sanitizer and store. The T5.4 script
   checks that the frames reference the driver and hold no plaintext, that the oracle CLI
   attests `[post_shred_replay] PASS`, and that the player shows `[erased]` for every driver
   reference after the shred. Its red paths: an un-shredded driver's replay fails the tier,
   and a plaintext CDL copy written past the store fails it until it is removed. Regenerated
   every Driftwood CI run (44 checks).
4. **The P3 gate notes, closed** (each with a red-before test and a sabotage):
   1. *Retention without capture.* `Observability.child_specs/2` adds a transient child that
      installs the replay retention specs wherever `:samen_replay_repo` is set, `replay:` or
      not; the window comes from `replay:`'s `retention_days` when given. Sabotage 465.
   2. *Bounded, counted persists.* `Samen.Replay.TaskSupervisor` has `max_children:
      max_persist_tasks` (default 16). `async_nolink` raises at the bound, so the monitor
      rescues it, frees the session's buffer row and counts it `:dropped`; it never waits.
      Every outcome is counted in `Monitor.stats/0`, and each emits one `[:samen, :replay,
      :session]` event (bounded `result`), exported as the new `samen.replay.session.count`
      metric. A missing buffer row (an org switch stopped the recording) counts as
      `:discarded`. Sabotages 466 (unbounded), 467 (monitor crashes at the bound), 468
      (failure uncounted).
   3. *Validator = sanitizer.* New bounded types `:module_name`, `:md5`, `:uuid`
      (lowercase), `:pk` (lowercase UUID or integer), `:field_name`, `:label`,
      `:param_key`; tree keys are `$more`, `$kN`, a UUID, an integer, or an EXISTING atom
      (what `map_key/2` emits). `RowGuard`'s `view` is a module name; capture's component
      name is too. *Limitation:* an `allowed: :open` value (an event label, a kept param
      value) is still checked label-shaped, not against the view's own closed set, which the
      frame does not carry. Sabotages 469, 470.
   4. *Cursor vs record (decided: the record is right).* A `Page` cursor `{sort_value, id}`
      now takes the decision its sort column gets inside the page's own records: kept only
      when the record keeps the column, else shape only; undeterminable means shape only. The
      CDC classifier is the one default-deny authority, and a `:date` column can be a date of
      birth. The cursor holds the SAME column's value, so it must not be more visible than
      the column. Sabotage 471.
   5. *`:logger` fails closed on hidden writes.* runtime.exs now fails on: `alias`/`import` of
      `Logger`/`:logger`; `require Logger, as:`; `apply`/`Kernel.apply`/`:erlang.apply` on
      Logger, `:logger` or a non-literal module; `Application.put_env`/`put_all_env`/
      `:application.set_env` touching `:logger`, `:kernel` or a non-literal app;
      `config :kernel` `logger_level`/`logger`; `config` with a non-literal app;
      `Config.config/2`; a captured level writer; a level writer called on a variable module;
      and any `Code.eval_*`/`require_file`/`compile_*`/`load_file` or `import_config`. The
      one sanctioned non-literal `config` is the generated runtime.exs's `for {app, settings}
      <- Samen.Observability.otlp_runtime_config(...)`. Sabotages 472–475.
   6. *`ParamFilter` fails loud.* After wrapping, every expected owner (`Phoenix.Logger` when
      `:phoenix` runs with its logger on, `Phoenix.LiveView.Logger` when LiveView runs) must
      have a wrapped handler, or `install/0` raises `ParamFilter.HandlersNotFound` naming it,
      at boot. Sabotage 476.
   7. *One bad row = one `:invalid` frame.* The player reads `kind`/`payload` through two text
      calculations on `Samen.Replay.Frame` (`stored_kind`, `stored_payload`) instead of the
      typed attributes. A kind outside the closed set or a non-object payload loads, and the
      decoder makes it one `:invalid` frame. The typed read failed the whole session
      (`:not_found`). Sabotage 477.
   8. *View loaded before decoding.* `Player.load_view/2` loads the recorded view, and each
      `$record`'s resource, before decoding. It loads only an allowed module: an existing
      atom with an `inspect`-shaped name, on the code path as a `.beam` whose exports (read
      with `:beam_lib` BEFORE loading) include `render/1` or `__live__/0` (`spark_dsl_config/0`
      for a resource). Sabotages 478 (not loaded), 479 (any module loaded).
   9. *No N+1.* `Samen.Api.PiiResolution.prefetch/4` reads, once per resolve call, the grant
      verdicts (new optional `Samen.Reveal.Grant.granted_many/1`; `Samen.Reveal.Grants`
      makes one suspension check and one grant read per actor), the vault rows of every value
      the plane decrypts (new `Samen.Vault.prefetch_rows/2`, ciphertext only), and the bag
      catalog. Decisions and decrypts stay per value, and nothing outlives the call, so the
      next batch reads again (deny-on-read). The resolver prefetches per batch and still
      resolves each record inside its own reveal span. Every other `PiiResolution.resolve/4`
      caller (list pages, API) gets the same batching. Measured (`samen_web`
      `replay_player_test.exs`, a full 50-row ContactsLive page, one frame batch):
      **tenant 152 → 3 queries (62 → 11 ms), operator 354 → 7 (78 → 9 ms)**. A 1-row frame
      costs the same 3 / 7. Kernel fixture (`resolver_batch_test.exs`, 50 refs): tenant
      51 → 2, operator 101 → 3. Sabotages 480 (N+1 back), 481 (batch cached across batches),
      482 (batch skips suspension).
5. **Demo.** Driftwood `config/dev.exs` passes `replay:` with `flag_opts: [flag_module:
   Driftwood.Primitives.FeatureFlag, owner_org_id: <the operator org>]`, which scopes the flag
   loader to replay and to the operator org's rows (item 7). No host configured the flag
   cache's loader, so every flag evaluated OFF. `mix driftwood.seed` seeds the operator org's
   `samen.replay` row with one allow rule for the Blue Ridge org. prod/test never set
   `replay:` (sabotage 489). Runbook: `docs/runbooks/session-replay.md`. Guide:
   `docs/observability-guide.md` §7, not §5, because P1 used §5–6.
6. *Tooling:* `scripts/dialyzer_gate.sh` now hashes samen_core's untracked-but-not-ignored lib
   files too, by path and content (the P3 builder's stale-PLT note).

7. **P4 gate: a flag resolves from the operator org's rows only.** The flag cache's Ash
   loader read `name == flag` across EVERY org's `FeatureFlag` rows and took the first. Flag
   rows are org-scoped and admin-gated (`OrgScope` + `RoleAtLeast :admin`), so a tenant admin
   edits, and may create, rows in its own org. Any tenant row carrying a platform flag's name
   could therefore decide the gate for every org. A tenant B row at `rollout_pct: 100` turned
   replay capture ON for B and for every other org. A tenant's killed row could turn it OFF
   for the opted-in org. The Driftwood seed also put the opt-in row in the Blue Ridge
   TENANT org, where that tenant's admin could roll it out to everyone at `/settings/flags`.
   This was an engine bug, not a replay bug: `delivery.open_click_tracking` had the same
   shape. *Fixed at the engine*, by ADR-020's ownership model (WS-B design §3.5: the engine's
   flags are PLATFORM flags, i.e. the operator org's OWN rows, managed at `/operator/flags`
   and evaluated per org through targeting rules and the org bucket):
   `Samen.FeatureFlags.Cache` reads only rows with `org_id == owner_org_id` (opts or
   `config :samen_core, Samen.FeatureFlags.Cache`). With no owner, or one that is not a
   UUID, the result is `{:error, :no_flag_owner}`. Two owner rows with the same name give
   `{:error, :ambiguous_flag}`. Both are fail-safe OFF. We ignore tenant rows instead of
   refusing them at write: the kernel resource does not know the operator org, and a
   tenant's own config row stays what ADR-020 says it is, that tenant's row. It is simply
   never a platform flag. `Samen.Replay.config!/1` refuses `flag_opts` that name a
   `:flag_module` without a UUID `:owner_org_id`. Driftwood dev passes the operator org, and
   the seed writes the operator row. A host-supplied `:loader` is the host's own seam and is
   used as given. Tests: the engine's ownership describe (`feature_flags_engine_test.exs`,
   tenant rows written FIRST so the old loader picks them, plus the ownerless and ambiguous
   cases) and Driftwood's cross-tenant test, where a tenant B admin's row and Blue Ridge's own
   killed row are created through the kernel's admin-gated action and change nothing, and the
   seeded opt-in is `Forbidden` to the Blue Ridge admin. Both were red on the old loader.
   Sabotages 490 (any-org read), 491 (ownerless guess), 492 (ambiguous guess), 493 (ownerless
   replay config), 494 (opt-in seeded in the tenant org).

8. **P4 gate: a sabotage P1 disarmed, and one more deny-on-read step.** The full harness
   (every patch, chunked) found sabotage 302 (ADR-048 P2, "the fold rewrites ui_view")
   vacuous. It fails the same way on `main` (82aabda). §2.1's change made a vault-routed
   attribute's pending value a redacting `%Samen.Pii.Plaintext{}`, so 302's `is_binary/1`
   match stopped firing. Re-anchored with the same semantics (unwrap, then re-wrap); the
   named test flips again. The batch deny-on-read test now also revokes a grant between
   two batches and checks the subject is masked on the next one.

*Not done in P4:* a `live_render` child and stream rows are still not recorded (§7).

| Red path | Sabotage | Owning test file(s) |
|---|---|---|
| `:replay` tier — content, schema, KMS outage | 483, 484, 485 | `samen_core/test/replay/replay_tier_test.exs` |
| post-shred replay — accepts clear, ignores probes | 486, 487 | `replay_tier_test.exs` |
| game-day oracle covers replays | 488 | `driftwood/test/crypto_shred_gameday_test.exs` |
| gate notes 1–2 (retention, bounded/counted persists) | 465, 466, 467, 468 | `samen_core/test/replay/capture_test.exs` |
| gate note 3 (validator = sanitizer) | 469, 470 | `samen_core/test/replay/frame_schema_test.exs` |
| gate note 4 (cursor) | 471 | `samen_core/test/replay/sanitizer_test.exs` |
| gate note 5 (`:logger` hidden writes) | 472–475 | `samen_core/test/observability/logger_tier_test.exs` |
| gate note 6 (ParamFilter loud) | 476 | `samen_web/test/samen/web/param_filter_logging_test.exs` |
| gate notes 7–8 (bad row, view loading) | 477, 478, 479 | `samen_core/test/replay/player_test.exs` |
| gate note 9 (N+1, deny-on-read, suspension) | 480, 481, 482 | `samen_core/test/replay/resolver_batch_test.exs` |
| dev only | 489 | `driftwood/test/replay_dev_demo_test.exs` |
| P4 gate: flag ownership (operator org only, ownerless/ambiguous OFF) | 490, 491, 492, 493, 494 | `samen_core/test/feature_flags_engine_test.exs`, `samen_core/test/replay/capture_test.exs`, `driftwood/test/replay_dev_demo_test.exs` |

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
