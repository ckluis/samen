---
project: Astarte
url: https://github.com/astarte-platform/astarte
category: Infrastructure and Operations
relevance: low
verdict: Active, real Elixir/Phoenix IoT platform (device fleets, not SaaS tenants) with no PII vaulting, no Ash, and per-tenant Cassandra rather than Postgres — domain mismatch dominates; only its regex-scoped JWT claims and trigger/event-delivery engine are worth a narrow look.
---

# Astarte — evaluation vs samen

## What the project is

Astarte is an open-source IoT data platform (Apache-2.0, ~272 stars, actively maintained by SECO Mind — pushed within the last day, not archived) written in Elixir. It ingests, models, and processes device-fleet telemetry: devices connect over MQTT (via a VerneMQ plugin), declare their data shape through versioned JSON "Interfaces" (individual/aggregate datastreams and properties), and Astarte stores that data in Cassandra or ScyllaDB while firing "Triggers" to push events to external applications in real time.

Architecture is a classic Elixir umbrella of independently-deployable OTP apps under `apps/` — `astarte_realm_management`, `astarte_data_updater_plant`, `astarte_housekeeping`, `astarte_pairing`, `astarte_trigger_engine`, `astarte_vmq_plugin`, `astarte_appengine_api` (the Phoenix-based REST/WebSocket API) — plus shared libraries under `libs/` (`astarte_core`, `astarte_data_access`, `astarte_rpc`, `astarte_events`, `astarte_config`, `astarte_secrets`, `astarte_generators`). Services talk to each other over AMQP/RabbitMQ using an internal RPC library rather than direct function calls, and multi-tenancy is realm-based: each "Realm" (an org/customer) gets its own isolated Cassandra keyspace, with no cross-realm data sharing at the storage layer. Deployment is container/Kubernetes-first via a dedicated Operator and `astartectl` CLI; there's no bare-metal story documented.

Stack notables from `astarte_appengine_api/mix.exs`: Phoenix ~1.7 + Bandit, `guardian` for JWT, `exandra` (an Ecto adapter targeting Cassandra/ScyllaDB — Ecto, not Ash), `phoenix_swagger`, `cors_plug`, `telemetry_metrics_prometheus_core`, `skogsra` for config. Auth is JWT-only: Astarte issues no tokens itself and defers entirely to external IdPs/SSO (Keycloak, OAuth servers); authorization is five claim types (`a_aea`, `a_rma`, `a_ha`, `a_pa`, `a_ch`) each holding an array of `METHOD::path-regex` patterns checked as a logical OR against the incoming request — a capability-token-by-regex model rather than a role/permission table.

The project has no concept of PII masking, vaulting, crypto-shred, hash-chained audit, or Ash at all — it optimizes for high-volume time-series device data ingestion and fan-out, not tenant SaaS product surfaces.

## What samen could adopt

1. **Regex-scoped JWT claims as an alternative/ancillary API-token model** — What: bearer tokens carrying arrays of `METHOD::path-regex` patterns per API surface, checked at the edge before any DB/policy work runs. Why it fits samen: samen's MCP server already issues per-operator tokens (ADR-043); a regex-claim layer would let an operator mint a narrowly-scoped API token (e.g. read-only on `/api/v1/devices/.*`) without touching Ash policies or spinning up a new actor/role — useful for external integrations, fleet directives, and service-to-service tokens where full `OrgScope`/policy machinery is overkill. This is a *pre-filter*, not a replacement for policy — samen's fail-closed org-scoping stays authoritative behind it. Effort: S (a Plug/pipeline module + token-minting mix task).

2. **Trigger engine as a reference design for reliable webhook/event delivery** — What: a dedicated OTP app (`astarte_trigger_engine`) that decouples "event happened" from "external app was notified" via an AMQP queue, with independent retry/backoff, so a slow or dead external endpoint never blocks ingestion. Why it fits samen: samen's `Samen.Delivery.Chokepoint` (single send path) and Automation engine's `EventCapture` already do same-transaction Oban enqueue for outbound events; Astarte's engine confirms the shape (queue-then-fan-out, not synchronous webhook calls in the request path) and adds an explicit dedicated-worker-pool-per-trigger pattern worth comparing against samen's Oban queue topology for webhook-heavy tenants. Effort: S (pattern-level read, not a port — samen already has the equivalent primitive).

3. **`exandra` (Ecto-over-Cassandra/ScyllaDB adapter) as a future wide-column option** — What: an Ecto adapter letting a normal `Ecto.Schema`/`Repo` target Cassandra instead of Postgres, used here for high-cardinality time-series device data. Why it fits samen: purely speculative — samen is Postgres-only today (no ADR or code references Cassandra/Exandra/Guardian anywhere in the repo, confirmed by grep) and its vault/chokepoint/hash-chained-audit design leans on Postgres CHECK constraints and triggers that don't have Cassandra equivalents. Only relevant if a future samen vertical needs genuinely high-volume time-series/event-log storage outside Postgres's comfort zone (e.g. an IoT or telemetry-heavy product built on the foundry) — worth knowing the library exists, nothing to act on now. Effort: N/A (watch-list, not a workstream).

## What to ignore and why

- **Realm-per-tenant via separate Cassandra keyspace** — samen's tenant isolation is `OrgScope` + `PiiResolution` composition over a single shared Postgres schema, deliberately so masking/vault/audit chokepoints can be enforced centrally; per-tenant physical database separation is a different (heavier-ops, harder-to-govern-centrally) tradeoff samen has already rejected implicitly through its whole architecture.
- **Guardian for JWT** — samen's identity spine (ADR-035) already ships registration, OIDC via `assent`, TOTP via `nimble_totp`, and session management with zero hand-edits; swapping in Guardian would be a regression, not an upgrade.
- **"No token issuance, defer to external SSO" auth model** — samen deliberately owns end-user auth at launch (ADR-029/031 BYO-auth on-ramp) with its own vaulted-credential registration flow; Astarte's IdP-only model fits its B2B/enterprise IoT customer base, not samen's self-serve SaaS posture.
- **Device pairing / X.509 client-cert identity, MQTT ingress, Interface data-modeling DSL, Kubernetes Operator, `astartectl`** — all IoT-device-fleet-specific; no analog in samen's web-app/tenant-org world.
- **Everything else in the umbrella (`astarte_realm_management`, `astarte_housekeeping`, `astarte_pairing`, `astarte_vmq_plugin`, `astarte_fdo`/`astarte_fdo_core` FIDO Device Onboard support)** — device provisioning and fleet administration concerns samen has no product surface for; samen's own "fleet cockpit" (ADR-044) is about operator-portfolio-of-SaaS-apps, a different meaning of "fleet" entirely, not device fleets.
- **ScyllaDB BSL licensing note in the docker-compose** — a production-cost gotcha for Astarte adopters, irrelevant to samen since it isn't adopting Cassandra/ScyllaDB.
