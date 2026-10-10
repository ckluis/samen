# Samen Observability Guide (T2.6)

**Date:** 2026-07-05 (ADR-052 P1 additions: 2026-10-09)  
**Source:** vision doc §runs 4a–4d; plan T2.6; ADR-052 §2.1

---

## Overview

Samen's observability plane is governed, not exempt — every signal stays inside the no-plaintext invariant. Four layers:

| Layer | Module/Tool | PII posture |
|---|---|---|
| Distributed tracing | OpenTelemetry via `Samen.Tracer` | `db_statement: :disabled`; reveal span allow-listed (live on every `Samen.Reveal.reveal/5`); Oban job spans |
| Structured wide events | `Samen.WideEvent` (T2.7) | build-time schema allow-list, actor_id = HMAC pseudonym; one event per LiveView callback / request (§5) |
| Application log | Phoenix `filter_parameters` keep-list + prod level ≥ `:info` | `no_plaintext_pii` tier `:logger` (§6) |
| Bounded metrics | Prometheus + exemplars (T2.8) | hashed/bucketed tenant labels only |
| BEAM introspection | remote console runbook (T2.8) | guarded, operator-only |

---

## 1 · Distributed tracing (OTel)

### Setup (in `YourApp.Application.start/2`)

```elixir
def start(_type, _args) do
  # REQUIRED: attach Ecto telemetry with SQL text disabled.
  # db_statement: :disabled means no SQL text or bind params appear in any span.
  # Do NOT omit this option — the default in opentelemetry_ecto 1.2.x is already
  # :disabled, but the explicit declaration is required by the Samen no_plaintext_pii
  # CI tier (LogTelemetry checks both the config key and live handler config).
  OpentelemetryEcto.setup([:your_app, :repo], db_statement: :disabled)

  children = [...]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Required config

```elixir
# config/config.exs
config :your_app, :opentelemetry_ecto, db_statement: :disabled

# OTel SDK: configure your exporter for production.
# Operator TODO: replace :none with a real OTLP exporter.
config :opentelemetry,
  span_processor: :batch,         # :simple in dev/test for synchronous delivery
  traces_exporter: {:opentelemetry_exporter, %{}}  # → Honeycomb/Tempo/Jaeger
```

### The two PII scrubs

**Scrub 1 — SQL text (`db_statement: :disabled`).**  
`OpentelemetryEcto` attaches to Ecto's `:telemetry` events. With `db_statement: :disabled`, spans carry operation name, table, row count, and timing — but never the SQL text or bind parameters. Since Samen queries filter by vault tokens (never plaintext), even a `db_statement: :enabled` configuration would produce token-only SQL. The categorical disable is belt-and-suspenders: it removes the SQL surface entirely.

**Scrub 2 — Reveal span allow-list.**  
A `:reveal` span carries EXACTLY three attributes: `subject_id`, `grant_id`, `reason`. The decrypted value is NEVER a span attribute or event. `Samen.Tracer.with_reveal_span/3` enforces this structurally: any attribute key not in the allow-list is silently stripped before span creation.

**Live since ADR-052 P1.** `Samen.Reveal.reveal/5` — the grant-gated chokepoint in front of `Samen.Vault.reveal/3` — runs its WHOLE gate inside one `samen.reveal` span. A denied reveal is therefore as visible as a granted one: its span carries status `error` with the bounded refusal atom as the message (`denied`, `not_reveal_action`, `aggregate_actor_denied`, …), never a value. The attributes come from the caller's opts: `:subject_id`, `:grant_id`, and `:reason` **only as an atom code** — a free-text reason is not put on the span (it belongs in the audited grant / `aud_event` row). Not wrapped (yet): the operator-with-grant resolution inside `Samen.Api.PiiResolution` and internal system decrypts (TOTP, DSAR export, AI agent transcript) — they call `Samen.Vault.reveal/3` directly.

```elixir
require Samen.Tracer

# Good — only the three allowed keys appear in the span
Samen.Tracer.with_reveal_span("reveal.contact.full_name",
  %{subject_id: contact.id, grant_id: grant.id, reason: "support ticket #123"}
) do
  {:ok, plaintext} = Samen.Vault.reveal(masked_value, repo)
  # use plaintext here — it is NOT in the span attributes
  plaintext
end

# Accidentally passing the decrypted value:
Samen.Tracer.with_reveal_span("reveal.contact.full_name",
  %{subject_id: contact.id, grant_id: grant.id, reason: "...", decrypted_value: plaintext}
) do
  # The decrypted_value key is STRIPPED before span creation — it never appears
  # in the exported span. The C3 pii_reads verifier also catches a direct
  # flow of a revealed value into a span call site.
  :ok
end
```

### Oban trace propagation

**Automatic since ADR-052 P1.** `Samen.Jobs.enqueue_in_tx/4` stamps the current span's W3C context into `meta["trace_context"]`, and `Samen.Observability.JobSpans` (attached by `child_specs/2`, opt out with `job_spans: false`) opens an `oban.job` span on Oban's own `[:oban, :job, :start]` telemetry, parented on that context, and ends it on `:stop`/`:exception`. Every worker gets a job span with no per-worker code; the span carries only `oban.worker`, `oban.queue`, `oban.attempt`. Jobs inserted with a bare `Oban.insert/2` (not through `enqueue_in_tx/4`) still get a span, as a fresh root.

The manual form below remains available (and composes — a `with_job_span/3` inside a worker becomes a child of the `oban.job` span):

```elixir
# Enqueueing side:
MyWorker.new(%{record_id: record.id})
|> Samen.Tracer.inject_trace_context()   # stamps meta["trace_context"] with W3C headers
|> Samen.Jobs.enqueue_in_tx(multi, :my_job)

# Worker side:
defmodule MyWorker do
  use Oban.Worker, queue: :default, max_attempts: 20

  require Samen.Tracer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta}) do
    Samen.Tracer.with_job_span("MyWorker.perform", meta) do
      # All work here is a child span of the enqueueing span.
      # One request → one end-to-end trace, even across the queue boundary.
      do_work(args)
    end
  end
end
```

The `meta["trace_context"]` field is a list of `[header_name, header_value]` pairs (W3C Trace Context format, JSON-serializable for JSONB storage). `with_job_span/3` extracts the parent context, creates a child span, and restores the original context on exit — always, even if the work raises.

---

## 2 · `auto_explain` posture (server-side query plans)

### What it is

`auto_explain` is a PostgreSQL server extension that logs query execution plans automatically when queries exceed a sampling threshold. It is **not** an OTel feature — it writes to the PostgreSQL server log (`postgresql.log`), not to a trace sink.

### Why it is safe under the Samen invariant

Samen queries operate exclusively on vault tokens and bounded IDs in their `WHERE` clauses and index conditions:

- A query like `SELECT pii_full_name FROM pii_name_vault WHERE pii_id = $1` carries a UUID token as the bind parameter — no plaintext.
- The plan `auto_explain` logs (index scan on `pii_name_vault_pkey`, cost, rows) contains zero PII.

The same token-only-downstream invariant that governs the trace sink governs the server log: because plaintext never sits in a `WHERE` condition or index key, the execution plan `auto_explain` prints carries no plaintext PII.

### Configuration (sampled, log-only, server-side)

Add to `postgresql.conf` (or via `ALTER SYSTEM SET`):

```sql
-- Load the extension at session start (or globally via shared_preload_libraries):
-- shared_preload_libraries = 'auto_explain'

-- Log plans only for slow queries (> 500ms is a reasonable starting point):
auto_explain.log_min_duration = '500ms'

-- Log only: plans go to the PostgreSQL log, never to a trace sink.
-- 'text' format is human-readable; 'json' is machine-parseable.
auto_explain.log_format = 'text'

-- Include actual timings (requires an extra planning cycle but gives real numbers):
auto_explain.log_analyze = on

-- Buffer usage (helpful for I/O analysis):
auto_explain.log_buffers = on

-- Nested plans (for queries with subplans):
auto_explain.log_nested_statements = off    -- on for deep analysis, normally off

-- Sampling: log ~1% of qualifying queries (reduces log volume in production):
auto_explain.sample_rate = 0.01
```

**Operator TODO:** Enabling `shared_preload_libraries = 'auto_explain'` requires a Postgres restart and must be done by the operator. The config above is a reference — it is NOT applied by this codebase. There is no live Neon/AWS instance in the local development environment; a real `auto_explain` configuration change goes to the production Postgres host.

### What `auto_explain` is NOT a substitute for

- It is not an OTel trace — plans do not appear in Honeycomb/Tempo.
- It is not real-time per-request observability — use OTel traces + wide events for that.
- It does not replace `EXPLAIN ANALYZE` for ad-hoc debugging — use that in a staging environment directly.

`auto_explain` is the plan source for slow-query analysis when `OpentelemetryEcto` is configured with `db_statement: :disabled` (which it always is on a Samen substrate). The OTel span tells you the query was slow (timing); `auto_explain` in the server log tells you why (the plan).

---

## 3 · Simulation seam (local dev / CI)

There is no physical OTel collector in the local development or CI environment. The simulation is:

- **Config:** `traces_exporter: :none` in `config/config.exs` (suppresses the "exporter not found" warning).
- **Tests:** `Samen.TracerTest` uses `:otel_exporter_pid` (built into the OTel SDK) which delivers spans as `{:span, record}` messages to the test process, enabling synchronous assertion on span attributes.
- **Trace assertion:** `Record.defrecord(:span, ...)` extracts the span record; `:otel_attributes.map/1` converts the attributes to a plain map for assertion.

**Production export (ADR-052 P1).** `traces_exporter: :none` stays the default in every host and in generated apps. The `--deploy` runtime layer (`config/runtime.exs`, generated) maps one env var:

```elixir
for {app, settings} <-
      Samen.Observability.otlp_runtime_config(System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")) do
  config app, settings
end
```

Unset/empty → nothing changes. Set → `traces_exporter: :otlp` with a batch processor and `opentelemetry_exporter` pointed at the endpoint (`http_protobuf`). **Fail-honest (ADR-024):** if the endpoint is set but `opentelemetry_exporter` is not loadable, boot RAISES naming the dependency — never a deploy that claims trace export and drops every span. Add `{:opentelemetry_exporter, "~> 1.8"}` to `mix.exs` before setting the variable; collector auth rides `OTEL_EXPORTER_OTLP_HEADERS`.

---

## 4 · `no_plaintext_pii` CI assertion (LogTelemetry tier)

The `Samen.NoPlaintextPii.Tiers.LogTelemetry` tier (T1.8d config level + T2.6 live handler check) asserts both:

1. **Config level:** `Application.get_env(otp_app, :opentelemetry_ecto) == [db_statement: :disabled]`
2. **Live handler level:** every registered `:telemetry` handler with `handler_id = {OpentelemetryEcto, _}` has `db_statement: :disabled` or omitted (default) in its handler config.

A handler registered via `OpentelemetryEcto.setup(prefix, db_statement: :enabled)` fails the tier even if the config-level key says `:disabled`. This double-check catches the case where the application calls `setup/2` with the wrong option after startup.

The tier is run by `mix samen.verify.no_plaintext_pii` (step 6 of `demo/ci.sh`) and exits non-zero on any violation.

---

## 5 · LiveView + request wide events (ADR-052 P1)

`Samen.Observability.child_specs/2` attaches `Samen.Observability.LiveTelemetry` by default (opt out with `request_events: false`). Each Phoenix callback becomes exactly ONE `Samen.WideEvent` (`:telemetry.span/3` emits `:stop` or `:exception`, never both):

| Telemetry event | Wide event |
|---|---|
| `[:phoenix, :live_view, :mount \| :handle_params \| :handle_event, :stop \| :exception]` | `action: :live_view`, `callback: :mount \| :handle_params \| :handle_event` |
| `[:phoenix, :live_component, :handle_event, :stop \| :exception]` | `action: :live_component`, `callback: :component_event` |
| `[:phoenix, :endpoint, :stop]` (needs `Plug.Telemetry` in the endpoint) | `action: :http_request`, `callback: :request`, `method`, `status` |

New schema fields, all bounded (`mix samen.verify.sink_schema` still passes): `view` (`:opaque_id` — the LiveView/component **module** name), `callback`, `outcome` (`:ok`/`:exception`), `method` (closed enums), `status` (`:number`), and `event`.

**`event` never comes from the client.** The `handle_event` string is client-controlled: interning it would let a client exhaust the atom table, and recording it would let any string reach the sink. `Samen.Observability.LiveEvents` uses it only as a lookup key into the view's OWN statically handled event literals — the first argument of its `handle_event/3` clauses, read from the module's compiled debug info (or an explicit `__samen_live_events__/0` list) and memoized per module version. A match yields the literal's atom; anything else (prefix patterns, catch-alls, unknown strings) is `:other`. Atoms are only ever minted from developer literals. `:event` and `:action` are the only fields allowed the open-enum sentinel; the schema check now fails any other field that declares it. Releases built with `strip_beams: true` (the `mix release` default) carry no debug info, so every event is `:other` unless the release keeps `Dbgi` or the view declares `__samen_live_events__/0` — less detail, never more.

**Identity.** `tenant_id` is the socket/conn `:org_id` assign, kept only if it is a UUID. `actor_id` is `Samen.WideEvent.for_subject/2` of the `:samen_tenant_principal` assign — the per-subject HMAC pseudonym, memoized per process, omitted when the subject has no live key. Params, session, URI, path, query string and every other assign are never read; an exception's reason is never recorded.

**Never crashes the caller.** `:telemetry` detaches a raising handler for the rest of the node's life. The handler rescues and catches everything; a value that fails its bounded type is dropped from the event, an event that still fails validation is dropped whole.

## 6 · Logger governance — the `:logger` tier (ADR-052 P1)

Phoenix logs controller params and every LiveView `handle_event`'s params through one filter, `config :phoenix, :filter_parameters`, whose default (`["password"]`) is a deny-list: default-ALLOW. Every host and every generated app now sets the framework keep-list (default-DENY — every other param value prints `[FILTERED]`):

```elixir
config :phoenix, :filter_parameters,
  {:keep, ~w(id org org_id page per_page limit cursor after before sort sort_by order dir)}
```

The `no_plaintext_pii` CI tier **`:logger`** (`Samen.NoPlaintextPii.Tiers.LoggerGovernance`) fails when:

1. `filter_parameters` is not `{:keep, [...]}` — checked in the host's prod config (read with `Config.Reader` for `env: :prod`) and in the running app env — or a kept key is PII-named (`Samen.PiiClassify.pii_name?/1`) or secret-named (`password`/`secret`/`token`). Only when Phoenix is a dependency.
2. The prod Logger level is below `:info` (an unset level counts as below — Logger's default logs everything).
3. The prod config cannot be read (fail closed).

LiveView's own `log:` option is left at its `:debug` default: with the keep-list in every env and the prod floor at `:info`, its event line never reaches a prod log and its params are filtered everywhere (ADR-052 as-built note).

**In-flight vault plaintext is redacted at the type.** Ash hides a `sensitive?` field on a record and redacts a `sensitive?` changeset argument, but prints a changeset *attribute* verbatim — so `inspect(changeset)` (a log line, a crash report, a `FunctionClauseError` blame) showed a typed email until `Samen.Vault.Change` swapped in the token. `Samen.Type.VaultField.cast_input/2` now holds that plaintext as `%Samen.Pii.Plaintext{}` (`Inspect` → `**redacted**`). Code that edits its own pending value opens it with `Samen.Pii.Plaintext.unwrap/1` (e.g. a composer reading `AshPhoenix.Form.value(form, :body)`); a form re-render shows the user's own input back (`Phoenix.HTML.Safe`). Ash's error structs never carried it: `Ash.Error.Invalid` prints the changeset as `#Changeset<>`, and the vault's own D3 cast refusal adds no value.

## 7 · Session replay (ADR-052 P2–P4)

`Samen.Replay` records tenant-plane LiveView sessions **by reference, never by value**, and replays
them on the **viewer's** plane. (ADR-052 §2.4 named this "§5 Replay"; §5 and §6 above went to the
P1 wide events and Logger governance.) Operating it day to day: `docs/runbooks/session-replay.md`.

**Two switches, both required.** The host passes `replay:` to `Samen.Observability.child_specs/2`
(`true` or a keyword list: `sample_rate` 1.0, `max_frames` 500, `max_bytes` 512 KiB,
`max_sessions` 1 000 per node, `max_persist_tasks` 16, `retention_days` 14 (1..90), `flag_opts`),
and the org's `samen.replay` feature flag is ON. The flag is the operator's: `flag_opts` carries
`flag_module:` and `owner_org_id:` (the operator org), the loader reads only that org's row and
evaluates it for the recording org, and a tenant's own `samen.replay` row decides nothing (a
`flag_module` without an owner refuses to boot). Without `replay:` no capture child starts; an
unknown flag is OFF. Only Driftwood **dev** sets `replay:` in this repo.

**What is stored.** `replay_session` (`rps`) and `replay_frame` (`rpf`), framework-owned,
catalogued, JSONB payloads, mounted by `Samen.Replay.Migration`. The sanitizer turns every
vault-routed attribute of an Ash record into a `$ref` (resource + primary key + attribute),
freeform columns and bare strings into shape only, event params into key/type/length/class.
Every frame is validated against `Samen.Replay.FrameSchema` at the store AND by
`Samen.Replay.RowGuard` on every create, and the validator accepts exactly what the sanitizer
emits (lowercase UUIDs, integer/UUID primary keys, module and attribute names, server-known keys).
The session actor is only the HMAC pseudonym.

**Retention does not depend on capture.** Wherever the tables are mounted (`config :samen_core,
:samen_replay_repo`), `child_specs/2` installs the replay retention specs into the regular
`:retention_specs` registry, which the nightly `Samen.Retention.SweepWorker` sweeps, with capture on or off.

**Persisting is bounded and counted.** A finished session persists in a supervised task (at most
`max_persist_tasks` at once; over the bound the session is dropped, never queued). Every outcome
is counted: `Samen.Replay.Monitor.stats/0` on the node, and one `[:samen, :replay, :session]`
event with a bounded `result` (`persisted | discarded | failed | dropped`), exported as the
`samen.replay.session.count` metric.

**Watching.** Operators: `/operator/replays/:org_id` while holding an ACTIVE impersonation
session for the org (re-checked on every frame batch). Tenant admins/owners:
`/settings/replays` for their own org. Every open writes one token-only `replay.viewed`
`aud_event`. References resolve at view time through `Samen.Api.PiiResolution` on the viewer's
plane: `••••` without a grant, clear with a live reveal grant, `[erased]` after a crypto-shred,
`[gone]` for a deleted row, `[changed]` when the code moved. Values are labelled CURRENT. The
recorded view renders in a sandboxed, script-free iframe in a bounded process. Grant and
suspension checks and vault-row reads happen once per frame batch, not once per row (a 50-row
frame: tenant 3 queries, operator 7).

**The oracle covers it.** `mix samen.verify.no_plaintext_pii` runs the `:replay` tier (every
stored frame passes the frame schema, every session row is kernel-shaped, no referenced
subject's decrypted vault plaintext appears in any row); `--subject <uuid> --tiers all` runs
`:post_shred_replay` (every stored reference to the erased subject resolves to `[erased]` on
the tenant plane). The Driftwood crypto-shred game-day records the driver in a replay and
proves both on every CI run.
