# ADR-054 — Samen runs as ONE application instance per database, and the application enforces it

- **Status:** **ACCEPTED (2026-11-14); BUILT** on `harden/eval-single-node`. Decided by the owner in issue #121, D2, option 1:
  "Declare single-node in an ADR and add a boot guard that refuses to join a cluster; revisit when a product needs it."
- **Date:** 2026-11-14
- **Closes:** evaluation 2026-11-13 finding **ARCH-3** (`spec/evaluation-2026-11-13/review-arch.md`): node-local state spread
  through the code with no ADR saying so.
- **Governs:** `Samen.SingleNode` (`samen_core/lib/samen/single_node.ex`), `Samen.SingleNode.Peers`, `Samen.SingleNode.Lease`;
  `Samen.Web.Readiness` (the `single_node:` advisory and the strict check); the generated `fly.toml` and deploy runbook.

---

## 1. Context

Samen was never designed as a cluster, and nothing in the repository ever said so. The evaluation found the assumption
spread through the code: an ETS rate limiter, an ETS replay-nonce cache, a kill switch in `:persistent_term`. It also found
that nothing stopped an operator from running two machines, which is the Fly default (`fly deploy` creates two machines unless
told `--ha=false`). Two instances sharing one database do not scale a Samen product. Several of the guarantees the product
sells weaken silently.

### 1.1 Inventory — every node-local mechanism, and what two instances do to it

Produced by `rg` over `samen_core/lib`, `samen_web/lib` and the three hosts for `:ets.new`, `:persistent_term.put`,
`Agent.start*`, `use GenServer` state used as a source of truth, `Registry`, `Phoenix.PubSub` / `Presence`, `File.write*` /
`File.mkdir*`, and `Node.*`, `:net_kernel`, `:global`, `dns_cluster`, `libcluster`. The last three find **nothing**: no code in
the repository uses distribution, and no clustering library is a dependency.

Severity: **SECURITY** = a guarantee the product states is weakened. **WRONG** = a visible wrong answer or lost data.
**DEGRADED** = a worse experience, no integrity or security loss.

| # | Mechanism (file) | With two instances | Severity |
|---|---|---|---|
| 1 | Fleet replay-nonce cache, ETS (`fleet/nonce_cache.ex`) | A signed heartbeat/directive replayed to the OTHER instance is accepted: the 600 s replay bound (ADR-044 §4.4) holds per instance only | **SECURITY** |
| 2 | AI host kill switch + provider-trip state, `:persistent_term` (`ai/agent/breaker.ex`) | `kill/2` on one instance leaves agents running on the other; the rate trip's "throw the host kill" stops half the fleet. The audit row says it was thrown | **SECURITY** |
| 3 | Rate limiter, Hammer ETS backend (`web/rate_limit/backend.ex`) | Counters are per instance: the effective login / TOTP / public-status limit is N times the configured one | **SECURITY** (brute-force bound) |
| 4 | Feature-flag cache, ETS + node-local invalidation (`feature_flags/cache.ex`) | A kill-switch flip invalidates the instance that handled the write; the other serves the old config until the TTL (default 60 s) | **WRONG** (bounded) |
| 5 | `FileBacked` KMS: `master.key` + per-subject DEK files on local disk (`kms/file_backed.ex`) | Each instance mints its OWN `master.key`; a DEK wrapped on one cannot be unwrapped on the other; shred on one leaves the DEK file on the other | **WRONG** (data loss) / **SECURITY** (crypto-shred incomplete). Single-node fallback only; the production adapter is the KMS one |
| 6 | Break-glass local-durable audit, a hash chain in a node file (`break_glass/local_audit.ex`) | Two chains, one per disk; reconciliation into `aud_chain` must merge them. Gap detection is per file | **DEGRADED** (accountability split; risk register R8 residue) |
| 7 | Local WORM anchor, an append-only node file (`anchor/local_worm.ex`) | A seal written on one instance is invisible to the other; `read_head` there finds no anchor | **WRONG** (anchor verification cannot prove) |
| 8 | Local file storage adapter (`files/storage/local.ex`) | A blob uploaded through one instance is a 404 on the other. The S3 adapter is the production one | **WRONG** |
| 9 | Fleet local credential, `Agent` (`fleet/local_credential.ex`) | Each instance mints its own mode-B keypair; the cockpit enrols two identities for one app. The registry already refuses to run without a host-configured durable store | **WRONG** (reference implementation only) |
| 10 | Chat + notifications PubSub, Presence (`web/chat/pub_sub.ex`, `web/notifications/*`) | A message / notification broadcast reaches only subscribers on the same instance; who-is-online and typing show only same-instance users. The row is in Postgres, so a reload shows it | **DEGRADED** |
| 11 | TOTP enrolment secret, protected ETS (`web/auth/totp_pending.ex`) | A reconnect landing on the other instance starts a new attempt; the QR in the user's authenticator no longer matches | **DEGRADED** (documented there as single-node by design) |
| 12 | Session-replay in-flight buffer, ETS (`replay/buffer.ex`, `replay/monitor.ex`) | A session is captured and persisted by the instance running its LiveView; a reconnect elsewhere starts a new session | **DEGRADED** |
| 13 | Fleet attention log, ETS (`fleet/attention.ex`) | The cockpit's "being flooded" signal shows only the instance that took the rejected heartbeats | **DEGRADED** |
| 14 | Wide-event file sink (`wide_event/sinks/file.ex`) | One file per instance | **DEGRADED** (logs) |
| 15 | Caches that are pure functions of code or config: `:persistent_term` in `fleet/crypto.ex` (decoy key), `observability/live_events.ex`, `live_telemetry.ex`, `ai/agent/tools.ex`, `web/reads/adoption.ex` (log-once), `replay.ex` (runtime config); test and dev adapters (`Kms.InMemory`, `Billing.Fake*`, `Provider.Scripted`, `WideEvent.Sinks.InMemory`) | Identical on every instance, or never used in production | none |

### 1.2 What IS safe to scale (verified, not assumed)

- **Postgres** is the single source of truth for governed data, vault tokens, the audit chain and the job queue. It scales vertically and with a standby, independently of this ADR.
- **Oban** coordinates through Postgres: `FOR UPDATE SKIP LOCKED` fetch, the unique index, and database leadership
  (`Oban.Peers.Database`). `samen_core/test/multinode/oban_multinode_test.exs` (`SAMEN_MULTINODE=1`, runbook
  `docs/runbooks/multinode-oban-proof.md`) runs two real BEAM nodes against one database and proves exactly-once, uniqueness and
  failover. That proves the QUEUE is multi-node safe. It does not prove the application is: the table above is everything else.
- `Samen.Jobs.BootRun` enqueues unique jobs from every booting instance and dedupes.
- The signed session cookie and CSRF depend on the shared `SECRET_KEY_BASE`, not on a node.

## 2. Decision

**A Samen application runs as ONE serving instance per database.** This is a property of the product, stated here and enforced
by the application itself in two halves, because there are two different ways to break it.

### 2.1 Distributed Erlang (`Samen.SingleNode.Peers`)

- **At boot** `Samen.SingleNode.assert_standalone!/1` raises `Samen.SingleNode.ClusteredError`, naming this ADR, when a visible
  node is already connected (`Node.list/0`) or a clustering library is configured (`config :libcluster, :topologies`,
  `config :dns_cluster, :query`, or the Phoenix-generated `config :my_app, :dns_cluster_query`).
- **At runtime** the instance subscribes to `:net_kernel` events of both kinds. A **hidden** node is accepted. A **visible**
  one (or an event that does not say) is refused: `Logger.error`, a value-free `Samen.Observability.Failure` report,
  `samen.single_node.peer_refused.count`, and `Node.disconnect/1`.
- **Hidden nodes are how an operator reaches a production node.** Mix releases start `bin/app remote` and `bin/app rpc` with
  `--hidden` (verified in `Mix.Tasks.Release.Init`'s `remote`/`rpc` scripts), and `docs/runbooks/beam-introspection.md` already
  prescribes `iex --hidden --remsh`. Hidden nodes never appear in `Node.list/0` and cannot make this node share state.
  `:observer` must be run from a hidden node for the same reason; a visible observer is refused like any other visible peer.
  `samen_core/test/single_node_test.exs` proves both outcomes against real `:peer` nodes.
- **Disconnect, not stop.** Stopping the node would let anyone holding the release cookie take the service down with one
  `connect_node`, and gains nothing: no Samen code uses distribution, so "no node-local state is read by another node" holds the
  instant the peer is gone. A peer that reconnects is refused and reported again, every time, so a persistent clusterer is a
  rising series, not a quiet success. What a hidden node can do is whatever its cookie allows (`:erpc`); the cookie is the
  boundary, as it always was.
- The subscription is made before the existing-nodes scan, so a node connecting between the two cannot be missed.

### 2.2 Two instances, one database (`Samen.SingleNode.Lease`)

Two instances behind a load balancer are not an Erlang cluster, so 2.1 never fires. The only thing they share is Postgres, so
Postgres is the detector.

- **Mechanism.** Each serving instance owns one dedicated Postgres connection (a size-1 `Postgrex` pool, outside the Ecto pool and
  the SQL sandbox). `after_connect` takes a session-level **shared** advisory lock, `pg_advisory_lock_shared(0x53414D45,
  0x4E4F4445)`, and sets a session variable. A check counts the other holders in `pg_locks` (with their `backend_start` from
  `pg_stat_activity`) every `interval_ms` (5 s). Zero others is `single`, more is `overlap`.
- **Why a shared session lock and not an exclusive try-lock or a heartbeat row.** (1) It cannot go stale: Postgres releases a session
  lock the instant the session ends, so a crashed or partitioned instance leaves nothing behind and there is no heartbeat TTL to tune
  against deploy time. (2) It is symmetric: an exclusive try-lock tells only the loser, while counting shared holders tells both
  instances, so whichever instance the load balancer or the probe reaches reports. (3) It needs no table, no migration and no row to
  expire.
- **Connection drops and pool recycling.** The lock is taken only in `after_connect`, which runs on every new session before the pool
  serves its first query on it. A dropped connection that the pool re-establishes therefore re-takes the lock by construction, with no
  retry loop in the guard (proved by `terminate_backend` in `samen_core/test/single_node_lease_test.exs`). The Ecto pool's recycling is
  irrelevant: it is a different connection.
- **Rolling deploy.** The overlap is expected. For `grace_ms` (default 300 000, five minutes) nothing is reported and `/readyz` is clean.
  Past it: one `Logger.error` and one `Failure` report per overlap episode, `samen.single_node.overlap.count`, and `/readyz` carries
  `single_node: CRITICAL N other instance(s) share this database for Ns …` in its **200** body. The default never fails a deploy.
- **`strict: true`** (`config :samen_core, Samen.SingleNode, strict: true`): past the grace period the **late** instance, the one
  whose lease session started later (ties broken by backend pid), answers **503** (`single_node: FAIL`) instead of becoming ready, so
  a deploy that does not stop the old instance in time stops being ready by itself. The older instance keeps serving. Consequence to
  know: an instance whose lease session was lost and re-established becomes the "late" one.
- **Fail-honest.** The check returns `single`, `overlap` or `{:unknown, reason}`. An unreadable state is never `single`:
  `:starting` (nothing read yet), `:connection_down`, `:query_failed`, `:lease_lost` (the session variable is present and the lock is
  gone, for example `pg_advisory_unlock_all()`), `:connection_pooler` (below). `/readyz` shows `single_node: UNKNOWN …` and
  `samen.single_node.unknown` is 1. Strict mode does not refuse on unknown (a dead database already fails the `repo` check).
- **PgBouncer, honestly.** A session lock lives on a server connection. Behind a pooler in **transaction** mode a client's statements
  land on different server connections, so a lock taken by one statement is invisible to the next and this mechanism cannot work. The
  guard does not guess: the check reads the session variable only `after_connect` sets, and a statement served by a session that never
  ran `after_connect` can only be a pooled one, so the answer is `{:unknown, :connection_pooler}`, loudly, instead of a false "single".
  The fix is operational: set `config :samen_core, Samen.SingleNode, lease_url: <direct, unpooled URL>` so this one connection bypasses
  the pooler. In **session** mode the lock works unchanged. A pooler that happens to pin this client to one server connection is
  indistinguishable from a direct connection, and then the lock really is held by this client's session, so the answer is right.
  What the guard cannot see: two instances using different databases (they are two deployments, not one), and a database restored from a
  backup next to the original (different cluster, no shared locks).
- **Reading the state costs no query.** The lease publishes its state in a protected ETS table; `/readyz` reads that. A slow or dead
  database cannot block the probe.

### 2.3 "Serving": the only instance that arms the guard

`Samen.SingleNode.serving?/2` is Phoenix's own definition: the endpoint will bind a listener, that is `server: true` on any endpoint
config of the app (the dev config and the generated `runtime.exs` set it) or `config :phoenix, :serve_endpoints, true` (what
`mix phx.server` sets). Everything else does not start the guard and never takes the lock:

| Process | Serving? | Why |
|---|---|---|
| `mix test` | no | test config `server: false`, and hosts start no repo/web tree under test |
| `mix ecto.migrate`, `mix ecto.*` | no | start the repo only |
| `mix samen.*` tasks, `mix run` | per the endpoint's `server:` key | dev config sets `server: true`, so a task that starts the whole app would bind the port too; the seed tasks go through `Samen.SeedBoot`, which forces `server: false` first (proved in `single_node_test.exs`) |
| `iex -S mix` | as `mix run` | |
| `mix phx.server` / `iex -S mix phx.server` | yes | this is the dev server; a second dev server on the same database is a real overlap |
| release `eval` / `bin/app eval App.Release.migrate` (Fly `release_command`) | no | `eval` loads the app and starts only what the function starts (`Ecto.Migrator.with_repo` starts the repo); the supervision tree, and so the guard, never starts |
| release `start` | yes | `runtime.exs` sets `server: true` |
| `bin/app remote`, `rpc` | n/a | hidden nodes; they start no application of ours |

`Samen.Observability.child_specs/2`, which every host and the generated app already splice into their supervision tree, returns the
guard's children (`[]` when not serving), so a host needs **zero** new lines.

### 2.4 Configuration

`config :samen_core, Samen.SingleNode, strict: false, grace_ms: 300_000, interval_ms: 5_000, lease_url: nil`. There is no switch
that turns the distributed-Erlang half off; the product is single-node.

## 3. Consequences

**Positive.** The assumption is stated, enforced and observable: a second instance is reported with a metric and an advisory instead of
silently weakening the nonce, kill-switch and rate-limit guarantees. Operators who read `fly.toml` or the runbook are told to run one
machine. Deploys are never failed by default.

**Negative / accepted.** No horizontal scale and no zero-downtime blue-green: one instance means a restart is a brief outage (Fly's
rolling strategy on one machine replaces it). Availability under instance failure is the platform restarting the instance. The default
is advisory, so an operator who ignores `/readyz` and the metric keeps running two instances, and gets the table in §1.1. Detection is
5 s granular and is only as good as the connection (unknown is reported, never hidden).

**Existing artifacts.** The generated `fly.toml` pins one instance and says so; the deploy runbook adds a "one instance" section; the
`compliance-story` "multi-node availability" rows are qualified (they prove the Oban substrate, not application scale-out).

## 4. Revisit triggers and the path to cluster safety, per mechanism

Revisit when a product needs availability or throughput one instance cannot give, or a compliance regime requires N+1 serving
instances. Make the mechanisms cluster-safe one at a time, each behind its own sabotage-tested change, and only then relax the guard
(first to a configured instance count, never to "any").

| Mechanism | Path to cluster safety |
|---|---|
| Nonce cache (#1) | A Postgres table with a unique `(kid, nonce)` index and a sweep job; replay becomes a unique-violation. No new infrastructure |
| AI kill switch (#2) | Persist the switch (a row, audited in the same transaction) and read it through a short TTL cache; `rearm` deletes the row. Provider-trip counters from the run log, as the rate trip already does |
| Rate limiter (#3) | a shared Hammer backend (Redis, or a Postgres counter table); `Samen.Web.RateLimit` is the single seam |
| Flag cache (#4), PubSub and Presence (#10) | `Phoenix.PubSub` over `Phoenix.PubSub.PG2` needs distribution, which this ADR refuses; use a Postgres `LISTEN/NOTIFY` PubSub adapter instead, which also carries the flag invalidation |
| KMS (#5) | The AWS KMS + DynamoDB adapter (PROD-1) is the production path; `FileBacked` stays a single-node fallback by definition (it is today the only non-AWS adapter) |
| Break-glass audit (#6), anchor (#7), file storage (#8), fleet credential (#9) | Production adapters already exist or are planned (S3 Object Lock anchor, S3 storage, a durable credential store); the local ones remain single-node by definition |
| TOTP pending (#11), replay buffer (#12), attention (#13) | Sticky routing is enough for the first two (a reconnect re-attaches); the third needs a table |
| Distribution (2.1) | Needed only for PubSub over PG2 or `:global`; prefer the Postgres adapter above and keep the refusal |

## 5. Alternatives considered

- **Make the system cluster-safe now** (dns_cluster, a Postgres nonce table, a Hammer Redis/PG backend, PubSub across nodes, a durable
  kill). Rejected by the owner in #121 D2 for now: M-sized work per mechanism for a capability no product has asked for. §4 keeps the
  path.
- **An exclusive advisory try-lock; the loser refuses to start.** Rejected: it fails every rolling deploy (the new instance boots while
  the old one runs), and tells only the loser.
- **A heartbeat row with a TTL.** Rejected: the TTL has to be tuned against crash detection and deploy overlap, a crashed instance
  blocks the next for a TTL, and it needs a migration in every host.
- **Stop the node on a visible peer.** Rejected in §2.1.
- **Refuse to boot on lock contention by default.** Rejected: it turns every rolling deploy into an outage. `strict` exists for the
  operator who wants it.
