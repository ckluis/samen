# BEAM Introspection — Wedged-Process Runbook

**Task:** T2.8 — doc §runs 4c/4d  
**Scope:** guarded remote console, Process.info + stacktrace, reduction/message-queue telemetry, Oban + Ecto pool checkout handlers, on-call decision tree.

---

## Overview

A single-node BEAM on a single Postgres makes per-request failure modes more likely, not less (doc §limits). This runbook covers the wedged-process case: a request is stuck rather than slow. The symptom is a LiveView or Ash action that has stopped making progress — not an error, not a timeout, just silence.

The on-call progression is:

1. **Identify the symptom class** (slow action vs. wedged pid vs. mount-storm) — done with metrics and traces.
2. **Use the remote console** only for the live-process (wedged pid) case.
3. **Decide and act** per the decision tree at the bottom of this document.

---

## Step 1 — Identify the symptom class (metrics + traces)

Before opening a console, distinguish between the three cases:

### Slow action (Ash query under contention)

**Signal:** `samen.action.duration` P95 rising; `samen.pool.saturation.events` counter incrementing.

**How to see it:**

```
# Prometheus / Grafana: check samen_action_duration_bucket and samen_pool_saturation_events_total
# Or on-node (Elixir console — read-only, safe):
:telemetry.list_handlers([:samen, :pool, :saturation])
```

The `Samen.Metrics.ContentionHandlers` handler fires when an Ecto query's `queue_time` exceeds the configured threshold (default 50 ms). A rising counter here means DB pool checkout waiting — not a wedged process.

**Action:** check Postgres `pg_stat_activity` for long-running queries; consider `EXPLAIN ANALYZE`. The process will eventually unblock or timeout.

### Wedged PID (stuck process, not just slow)

**Signal:** a specific LiveView socket or Oban job is stuck for minutes. The span in Honeycomb/Tempo has no end event. The parent span never closes.

**How to see it:**

```elixir
# Find processes by message queue length (read-only, safe):
Process.list()
|> Enum.map(fn pid ->
  info = Process.info(pid, [:message_queue_len, :current_function, :registered_name])
  {pid, info}
end)
|> Enum.filter(fn {_pid, info} ->
  Keyword.get(info, :message_queue_len, 0) > 100
end)
|> Enum.sort_by(fn {_pid, info} -> -Keyword.get(info, :message_queue_len, 0) end)
|> Enum.take(10)
```

### Mount-storm (many LiveView mounts competing for connections)

**Signal:** `samen.pool.saturation.events` spikes sharply; DB connections are all checked out; the LiveView mount telemetry shows high concurrency with no individual long queries.

**How to see it:**

```
# Check Oban queue depth (Oban.check_queue returns queue state):
Oban.check_queue(queue: :default)
# Also check the Ecto pool size vs. DB max_connections:
Demo.Repo.config()[:pool_size]
```

---

## Step 2 — Guarded remote console access

**Use this only for the wedged-pid case.** A remote console has full write access to the running node — treat it as elevated production access.

### Access a running node

```bash
# Production node name is typically <app>@<hostname>
# Connect an IEx shell as a hidden node (does not appear in :nodes/0)
iex --name debug@127.0.0.1 --cookie <same_cookie_as_node> --hidden \
    --remsh <app>@<hostname>
```

**Operator TODO:** record the release cookie location in the deployment runbook. Never embed the cookie in shell history — use `read -s COOKIE` to read it interactively.

### Safety guards before touching anything

```elixir
# Confirm you are on the right node and the right release version
node()
Application.spec(:samen_core, :vsn)
Application.spec(:my_app, :vsn)

# Confirm the process count is reasonable (> 10k is a leak signal)
length(Process.list())
```

---

## Step 3 — Process.info on a wedged PID

Given a PID from the symptom scan above:

```elixir
pid = #PID<0.1234.0>   # replace with the actual PID

# Full info dump (safe read):
Process.info(pid)

# Targeted fields (less output, faster to read):
Process.info(pid, [
  :current_function,       # where the process is right now
  :current_stacktrace,     # full call stack (BEAM-level frames)
  :message_queue_len,      # backlog depth — > 1000 is a red flag
  :reductions,             # CPU work done — low reductions + long wall time = wedged on I/O
  :status,                 # :waiting | :running | :runnable | :suspended | :garbage_collecting
  :links,                  # who will be notified if this process crashes
  :monitors,               # what this process is monitoring
  :heap_size,              # bytes — > 100 MB is a GC / memory pressure signal
  :total_heap_size
])
```

### Reading `current_stacktrace`

The stacktrace is a list of `{module, function, arity, location}` tuples, innermost first.

Common wedge patterns:

| Pattern | Diagnosis |
|---|---|
| `GenServer.call` → blocking forever | The callee is dead or its mailbox is full — check the callee |
| `Ecto.Repo.checkout` | Pool exhausted — check `pool_size` and DB `max_connections` |
| `:gen_statem.call` / `:gun.await` | External HTTP call stuck — check the upstream |
| `:receive` with no timeout | Process waiting on a message that never arrives — check the sender |

### Reductions over time

A process that is wedged on I/O will show low-and-stable reductions across two snapshots:

```elixir
r1 = Process.info(pid, :reductions) |> elem(1)
Process.sleep(2000)
r2 = Process.info(pid, :reductions) |> elem(1)
delta = r2 - r1
# If delta < 1000 over 2s: not computing — waiting on I/O, a lock, or a dead process
```

---

## Step 4 — Reduction and message-queue-length telemetry

The `Samen.Metrics.ContentionHandlers` module attaches handlers at application start for:

- **Ecto pool checkout** — fires `[:samen, :pool, :saturation]` when `queue_time` exceeds threshold.
- **Oban job stop/exception** — re-emits as `[:samen, :oban, :job, :stop]` with bounded tags.

These handlers are the automatic signal path. You should not need the console for contention visibility — the metrics tell you first.

### Attach manually (if not already attached)

```elixir
Samen.Metrics.ContentionHandlers.attach(
  repo_event_prefix: [:my_app, :repo],
  pool_saturation_threshold_ms: 50   # ms above which a pool wait is a signal
)
```

### Read live pool depth (Ecto)

```elixir
# DBConnection.ConnectionPool internals (read-only; internal API, may change):
:sys.get_state(Demo.Repo.get_dynamic_repo())
# Or a safer proxy — check how many are idle vs. checked out:
Demo.Repo.__pool__()
|> :sys.get_state()
|> Map.get(:idle)
|> length()
```

### Read live Oban queue depth

```elixir
# Queue stats for all queues:
Oban.check_queue(queue: :default)
Oban.check_queue(queue: :erasure)

# Or drain-and-count (TEST ENV ONLY — drains the queue!):
# Oban.drain_queue(queue: :default)
```

---

## Step 5 — Oban and Ecto pool checkout telemetry handlers

The contention handlers are implemented in `Samen.Metrics.ContentionHandlers` (T2.8).

### Ecto pool saturation handler

Listens to `[<repo_prefix>, :query]` events emitted by `Ecto.Repo` on every query completion. The measurement `queue_time` is the time (native units) the query spent waiting in the connection pool before being served. When `queue_time > threshold_ms`, the handler emits `[:samen, :pool, :saturation]`.

This fires under **pool saturation** — not under slow queries (those show up in `total_time`, not `queue_time`). The two signals are orthogonal.

### Oban job contention handler

Listens to `[:oban, :job, :stop]` and `[:oban, :job, :exception]`. Re-emits as `[:samen, :oban, :job, :stop]` with:

- `action` — worker module name converted to a bounded atom (e.g. `:erasure_worker`)
- `result` — `:ok` or `:error`
- `duration` — job execution time (native units)
- `queue_time` — time spent waiting in the Oban queue before execution started

A high `queue_time` on Oban jobs signals scheduler contention — the queue concurrency cap is too low for the load, or another queue is starving the default queue.

---

## Step 6 — Exemplar: linking a metric spike to a trace

The `samen.action.duration` histogram can carry an exemplar `trace_id` on each observation. Where the reporter supports it (e.g. `TelemetryMetricsPrometheus` ≥ 1.1 with `exemplars: true`), include the trace_id in the measurement map:

```elixir
# In your Ash action telemetry handler:
:telemetry.execute(
  [:samen, :action, :stop],
  %{
    duration: duration_native,
    # Attach the current trace_id so a P95 spike in Prometheus links to a real trace
    trace_id: Samen.Metrics.exemplar_trace_id()
  },
  %{action: :create_contact, result: :ok, tenant_tier: :starter}
)
```

`Samen.Metrics.exemplar_trace_id/0` extracts the current OTel trace_id from the active span context. When no span is active (e.g. a background job not propagated from a request), it returns `nil` (safe — nil measurements are ignored by reporters).

**Operator TODO:** configure `TelemetryMetricsPrometheus.start_link(metrics, exemplars: true)` in the application start. Without this, exemplars are ignored even when present in the measurement map.

---

## Decision tree — on-call

```
A request is stuck / LiveView unresponsive
│
├─ Check samen_action_duration P95 and samen_pool_saturation_events_total
│  │
│  ├─ P95 high + pool saturation counter rising
│  │  └─ SLOW ACTION / POOL CONTENTION
│  │     → Check pg_stat_activity for long-running queries
│  │     → EXPLAIN ANALYZE the slow query
│  │     → Consider increasing pool_size or read-replica offload
│  │     → Do NOT open the remote console — this is a DB issue
│  │
│  ├─ P95 high + pool saturation counter NOT rising
│  │  └─ SLOW ACTION (no pool contention)
│  │     → Check OTel trace for the slow span
│  │     → Look for slow Ash action steps (policy check, N+1 queries)
│  │     → Do NOT open the remote console — trace is sufficient
│  │
│  └─ P95 stable but specific PID/socket is stuck for > 2 minutes
│     └─ WEDGED PID — proceed to remote console
│        │
│        ├─ Connect guarded remote console (Step 2 above)
│        ├─ Process.info(pid, [:current_stacktrace, :message_queue_len, :reductions])
│        ├─ Take 2 reduction snapshots 2 seconds apart
│        │  │
│        │  ├─ Reductions not growing → I/O wait or dead dependency
│        │  │  → Kill the stuck process (Process.exit(pid, :kill))
│        │  │  → Document the stacktrace for the post-mortem
│        │  │
│        │  └─ Reductions growing but slow → GC pressure or large message
│        │     → Check :heap_size and :total_heap_size
│        │     → If > 100 MB: GC pressure — let it run or kill and investigate
│        │
│        └─ If the process is a LiveView socket (registered under Phoenix.LiveView):
│           → Closing the browser tab unlinks the socket (safe)
│           → Or: Process.exit(pid, :normal) — graceful close
│
└─ Many sockets stuck simultaneously (> 10 LiveView pids wedged)
   └─ MOUNT-STORM
      → Check Oban.check_queue(queue: :default) — is the queue backed up?
      → Check DB connection pool: all checked out?
      → Shed load: temporarily reduce Oban queue concurrency
      → If DB connections are exhausted: restart the repo or add a read replica
      → Escalate to DB administrator if pg_stat_activity shows lock contention
```

---

## Simulation seam

There is no physical replica in the local development / CI environment. The contention handlers, pool saturation signals, and Oban queue-time metrics are implemented and tested using synthetic `:telemetry.execute/3` calls (see `test/metrics_contention_handler_test.exs`). The handler logic is real; the saturation trigger in tests is simulated.

**Operator TODO (before production):**

1. Call `Samen.Metrics.ContentionHandlers.attach(repo_event_prefix: [:<your_app>, :repo])` in `Application.start/2`, after the Repo is started.
2. Configure `TelemetryMetricsPrometheus.start_link(Samen.Metrics.definitions(), exemplars: true)`.
3. Wire `mix samen.verify.metric_labels` into CI after the compile step.
4. Set up a remote console access runbook with the release cookie location and node naming convention.
5. Validate on a staging environment that pool saturation events appear in Prometheus when the pool is artificially saturated (e.g. run 50 concurrent queries with `pool_size: 5`).
