---
project: Sequin
url: https://github.com/sequinstream/sequin
category: Automation and Data
relevance: medium
verdict: Best-in-class Elixir Postgres-CDC reference to mine for patterns (watermark backfills, idempotency keys, Broadway sink pipelines) — but company acquired, OSS in maintenance mode, and its raw-row streaming model is antithetical to samen's masked-egress invariant, so treat as architecture reading, never a dependency.
---

# 051 — Sequin

## What the project is

Sequin is an MIT-licensed, self-hosted change-data-capture (CDC) platform for Postgres, written in **Elixir/Phoenix/OTP** — the same stack as samen. It ships as a single Docker container that attaches to any Postgres 14+ via **logical replication slots** (no extensions), and streams row changes to 16+ sinks: Kafka, SQS/SNS, GCP Pub/Sub, Azure EventHubs, RabbitMQ, NATS, Kinesis, Redis Streams, Elasticsearch/Typesense/Meilisearch, webhooks, and its own HTTP-poll "Sequin Stream". Claims ~50k ops/s (40 MB/s) at ~55ms latency — well ahead of Debezium. Features: historical + partial **backfills** coordinated with the live stream via a watermark protocol; filtering/transforms/dynamic routing written as small **Elixir functions**; strict per-key ordering; at-least-once delivery upgraded to effectively exactly-once via a **stable idempotency key on every message**; declarative YAML config + management API; LiveView + live_svelte web console; Prometheus/Grafana observability; Broadway/GenStage/Flow pipeline internals; Oban for jobs; cursor state persisted (Redis) for crash-resume.

**Status caveat (load-bearing):** the company was acquired; Sequin Cloud shut down 2025-10-23 and the open-source repo is explicitly in **maintenance mode** (security patches and critical fixes only; feature work stalled, possible revival by the acquirer unscheduled). Fine as a reference codebase; risky as a runtime dependency.

## What samen could adopt

1. **Watermark-coordinated backfill pattern** (their blog: "Using watermarks to coordinate CDC in Postgres").
   - *What:* emit low/high watermark markers into the WAL around a chunked table scan, then PK-filter scan rows against changes seen between watermarks, so a backfill and the live change stream merge without stale-row races; cursor persistence gives restart recovery.
   - *Why it fits:* samen's `cdc` module + rollup/revenue plane and the deferred ADR-007 rollup wiring will eventually need "replay historical rows into a derived store" (ClickHouse ClickPipes is an open operator TODO). This is the correct, memory-bounded way to do it on plain Postgres, and it composes with samen's default-deny CDC classifier (ADR-015) since filtering happens per-column before egress.
   - *Effort:* **M** (pattern re-implementation inside samen_core's cdc subsystem; no dependency taken).

2. **Stable idempotency keys on every emitted event.**
   - *What:* attach a deterministic idempotency key (slot LSN + PK, or backfill cursor + PK) to each change/backfill message; sinks that support dedupe get exactly-once, others get safe retries.
   - *Why it fits:* samen's webhook egress, `Samen.Delivery.Chokepoint`, notifications fan-out, and the fleet token-blind report wire all retry via Oban; a first-class idempotency-key convention (verifier-checkable, catalog-documented) upgrades "at-least-once + hope" to auditable exactly-once semantics. Cheap and very samen-shaped (a guarantee you can sabotage-test).
   - *Effort:* **S**.

3. **Broadway-based sink delivery with per-key ordering groups.**
   - *What:* GenStage/Broadway pipelines that partition messages by primary key so ordering is preserved per row while parallelizing across rows; per-sink backpressure and exponential-backoff retry.
   - *Why it fits:* samen already ADOPTs the Ash/Oban stack but does fan-out (webhooks, ESP delivery, fleet reports) as discrete Oban jobs. If/when throughput matters (fleet-wide event wire, search-at-scale tsvector maintenance — an open WS-E follow-on), Broadway is the canonical OTP answer and Sequin is the best open example of tuning it against a replication slot. Read their pipeline code before designing samen's.
   - *Effort:* **M** (adopt broadway in a samen_web/adapter package only — INV-4 keeps it out of core).

4. **Postgrex logical-replication consumption as a first-party capability.**
   - *What:* Sequin's SlotProcessor shows how to own a replication slot from Elixir (postgrex replication protocol), decode WAL, and manage slot lifecycle/health (slot lag monitoring, resume-from-LSN).
   - *Why it fits:* samen's CDC today is application-level; a WAL-level tap is the only way to guarantee derived stores (search index, ClickHouse, cache) see *every* write including ones that bypass app code — a stronger version of samen's "no bypass" story, and it would let `mix samen.verify.*` assert slot lag = derived-store freshness. Only worth it when ClickHouse/search-at-scale actually lands.
   - *Effort:* **L** (new subsystem + red-path/sabotage coverage; defer until the ClickHouse operator TODO activates).

5. **Ops surface conventions:** Prometheus endpoint + shipped Grafana dashboards + YAML declarative pipeline config with a management API. Samen's G11 gap (metrics egress shipped, status page open) can crib the "ship the dashboard JSON with the repo" habit. *Effort:* **S**.

## What to ignore and why

- **Sequin as a dependency or sidecar service.** Maintenance-mode OSS from an acquired company is exactly the fail-honest risk samen avoids; and INV-4 forbids this class of dep in core anyway. Mine patterns, vendor nothing.
- **Its security/PII model.** Sequin streams **raw row data** to external sinks by design — no masking, no vault awareness. Any CDC egress in samen must stay behind the ADR-015 default-deny classifier and token-blind wire; Sequin's model is the anti-pattern samen's hero claim exists to prevent.
- **cloak_ecto for encryption.** Sequin uses it; samen already evaluated and rejected Cloak-style encryption in ADR-003 in favor of the per-subject-key crypto-shred vault. No new information.
- **live_svelte console UI.** Samen has a first-party function-component UI kit and a no-heavy-JS posture; a Svelte-in-LiveView console is a stack fork with no payoff.
- **The 16-sink adapter zoo.** Samen needs at most webhooks + ClickHouse + search; building Kafka/NATS/EventHubs adapters would be substrate-first violated in reverse (capability nobody's vertical proves).
- **Redis for cursor state.** Samen is Postgres-pure by conviction (and eigen doubles down on it); cursors belong in a Postgres table under the same audit discipline.
