---
project: Supabase Realtime
url: https://github.com/supabase/realtime
category: Automation and Data
relevance: medium
verdict: Not adoptable wholesale (samen's LiveView + same-transaction EventCapture already cover its use cases more governably), but it is the best-in-class reference for three specific things samen has open — Postgres-based BEAM clustering, partition-drop retention, and per-tenant rate counters.
---

# 052 — Supabase Realtime

## What the project is

Supabase's production WebSocket server (Elixir/Phoenix, Apache-2.0, ~7.6k stars, v2.129.x, actively maintained under heavy development). Three GA features: **Postgres Changes** (acquires a logical replication slot, polls WAL, appends subscription IDs — Erlang pids — to each WAL record so the BEAM routes changes to authorized sockets), **Broadcast** (ephemeral client-to-client messages; the durable variant writes to a `realtime.messages` table, publishes via WAL, and the table is **partitioned by day with 3-day retention enforced by dropping partitions**), and **Presence** (CRDT-backed in-memory KV synced across the cluster). Explicitly at-most-once: "does not guarantee that every message will be delivered."

Architecture: a globally distributed Elixir cluster; clients connect to any node. Multi-tenant by design — a `tenants/` subsystem holds per-tenant config, JWT secrets (Joken), and per-tenant database connections; authorization for Broadcast/Presence is delegated to **tenant-database RLS policies on `realtime.messages`** (the tenant's own Postgres decides who may read/write a channel). Notable stack: `syn` (global process registry/coordination), `libcluster` + **`libcluster_postgres`** (node discovery through Postgres — no DNS/K8s dependency), `gen_rpc` (EMQ's fork, inter-node RPC bypassing distribution bottlenecks), `cachex`, custom `rate_counter`/`gen_counter` modules for per-tenant throttling, full OpenTelemetry + PromEx/peep metrics, `open_api_spex`, Fly.io deploy dir, exhaustive `ENVS.md`/`ERROR_CODES.md`/`OBSERVABILITY_METRICS.md` operator docs. Runs a forked Phoenix (supabase branch).

## What samen could adopt

1. **`libcluster` + `libcluster_postgres` for production BEAM clustering — the headline steal.**
   - *What*: node discovery via the Postgres database itself (each node advertises in a table / via LISTEN-NOTIFY); no epmd/DNS/K8s infra.
   - *Why it fits*: samen's digest lists "Oban multi-node in production: proven locally only" (two-BEAM-node `:peer` sim, L4) as an open gap, and samen's purity rule is Postgres-only infrastructure. libcluster_postgres closes multi-node clustering with zero new infrastructure — the same posture as samen's "encode knowledge as infra" and INV-4 (it's a small hex dep, no vendor HTTP in core; it belongs at the host/deploy layer anyway). This is the proven production pattern for exactly samen's Fly.io-shaped deploy target.
   - *Effort*: **S** (add dep in host app supervision tree + one table/config; the hard part — Oban peer behavior — samen already proved locally).

2. **Partition-by-day + drop-partition retention for high-churn append tables.**
   - *What*: `realtime.messages` is a daily-partitioned Postgres table; retention = dropping old partitions, not row deletes.
   - *Why it fits*: samen has a `retention` subsystem, wide_event/audit/notification streams, and ADR-046 transcript retention. Partition-drop is O(1), vacuum-free, and composes cleanly with samen's crypto-shred story (tokens-only rows expiring by partition). Candidate tables: wide events, AI transcripts, notification feed, automation RunRecords.
   - *Effort*: **M** (migration pattern + generator support + a `samen.verify.*` check that retention-classed tables are partitioned; Postgres-native, no deps).

3. **Per-tenant rate/usage counters as a first-class subsystem (`rate_counter` / `gen_counter` pattern).**
   - *What*: cheap in-BEAM counters per tenant/connection feeding both throttling decisions and telemetry, instead of only ingress-edge rate limiting.
   - *Why it fits*: samen's rate limiting today is "Hammer-backed auth+webhook ingress only." A fleet of tenant orgs needs per-org counters for AI budget enforcement (ADR-047 budgets/cost caps), automation-engine breakers (Health/Breaker already exists — counters generalize it), and fair-use metering that feeds G13 usage rating later. The pattern (ETS/counters + periodic flush to telemetry) is small and vendor-free — fits samen_core.
   - *Effort*: **M**.

4. **RLS-in-the-tenant-database as the authorization seam for realtime channels — study, adapt the idea, not the code.**
   - *What*: Realtime asks the tenant's Postgres (RLS on `realtime.messages`) whether a socket may join/read a channel, so authz lives with the data owner.
   - *Why it fits*: samen's chat is already "catalog-driven masking-aware"; if samen ever exposes tenant-facing realtime subscriptions (live dashboards, webhooks-over-WS), the equivalent samen-native move is routing channel-join through Ash policies + `OrgScope` at a single subscribe chokepoint — same architecture, samen's policy engine instead of RLS. Realtime is the proof this seam scales.
   - *Effort*: **L** (only if/when tenant-facing realtime subscriptions become a roadmap item).

5. **Operator-docs discipline: `ENVS.md`, `ERROR_CODES.md`, `OBSERVABILITY_METRICS.md` as committed contract docs.**
   - *What*: every env var, error code, and exported metric enumerated in versioned docs.
   - *Why it fits*: samen already verifies docs as code (`doc_commands_test.exs`); extending that to a generated metrics/error-code registry (from `wide_event`/`observability` + `metric_labels` verifier output) matches G11's ops-runbook direction and is cheap given the catalog already exists as data.
   - *Effort*: **S** (mostly a dump task + parity test, like `samen.catalog.dump`).

## What to ignore and why

- **The product itself / running it as a component**: samen's realtime needs (chat, notifications, operator cockpit) are served by LiveView + Phoenix.PubSub in-process; bolting on a separate WebSocket server adds an ungoverned egress surface. Critically, Broadcast payloads are raw JSON straight to clients — no masking chokepoint — which violates INV-1/INV-7 unless samen rebuilt the egress path anyway.
- **WAL-polling Postgres Changes for samen's event fabric**: samen's EventCapture deliberately enqueues in the same transaction (governed, classified, deny-by-default per ADR-015). WAL-tailing bypasses the classifier and would leak column-level data by construction; Realtime's own docs concede at-most-once delivery. Samen's approach is strictly more aligned with its guarantees.
- **`gen_rpc`, forked Phoenix, `syn`**: solutions to millions-of-connections scale samen does not have; the forked-framework maintenance cost is the opposite of samen's pinned-upstream posture. Phoenix.PubSub/PG2 and OTP-native routing are sufficient at samen's scale.
- **Per-tenant JWT secrets / tenant registry**: samen's three-identity, two-plane model with org-scoped policies already covers this differently; Realtime's tenancy is connection-tenancy for an infra product, not product-tenancy.
