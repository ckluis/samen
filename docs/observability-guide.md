# Samen Observability Guide (T2.6)

**Date:** 2026-07-05  
**Source:** vision doc §runs 4a–4d; plan T2.6

---

## Overview

Samen's observability plane is governed, not exempt — every signal stays inside the no-plaintext invariant. Four layers:

| Layer | Module/Tool | PII posture |
|---|---|---|
| Distributed tracing | OpenTelemetry via `Samen.Tracer` | `db_statement: :disabled`; reveal span allow-listed |
| Structured wide events | `Samen.WideEvent` (T2.7) | build-time schema allow-list, actor_id = HMAC pseudonym |
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

Spans cross the Oban worker boundary via the job's `meta` field:

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

**Operator TODO:** In production, configure:

```elixir
# config/prod.exs
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: {:opentelemetry_exporter, %{
    otlp_endpoint: "https://api.honeycomb.io",
    otlp_headers: [{"x-honeycomb-team", System.get_env("HONEYCOMB_API_KEY")}]
  }}
```

Add `{:opentelemetry_exporter, "~> 1.10"}` to `mix.exs` deps.

---

## 4 · `no_plaintext_pii` CI assertion (LogTelemetry tier)

The `Samen.NoPlaintextPii.Tiers.LogTelemetry` tier (T1.8d config level + T2.6 live handler check) asserts both:

1. **Config level:** `Application.get_env(otp_app, :opentelemetry_ecto) == [db_statement: :disabled]`
2. **Live handler level:** every registered `:telemetry` handler with `handler_id = {OpentelemetryEcto, _}` has `db_statement: :disabled` or omitted (default) in its handler config.

A handler registered via `OpentelemetryEcto.setup(prefix, db_statement: :enabled)` fails the tier even if the config-level key says `:disabled`. This double-check catches the case where the application calls `setup/2` with the wrong option after startup.

The tier is run by `mix samen.verify.no_plaintext_pii` (step 6 of `demo/ci.sh`) and exits non-zero on any violation.
