---
project: NervesHub
url: https://github.com/nerves-hub/nerves_hub_web
category: Infrastructure and Operations
relevance: low
verdict: Real, actively-maintained Elixir/Phoenix OTA firmware/fleet manager for embedded IoT devices — solid engineering but a different domain (physical device firmware, not SaaS tenants); a couple of small operational patterns are worth lifting into samen's Fleet cockpit, nothing else transfers.
---

# NervesHub — evaluation vs samen

## What the project is

NervesHub is an open-source, self-hostable platform (Apache-2.0, 268 stars, 96 forks, actively maintained — pushed same day as this scan) for managing fleets of embedded Nerves (Elixir-on-BEAM-for-hardware) devices at scale: signed over-the-air (OTA) firmware delivery, device health reporting, and interactive remote consoles, claimed to scale to "half a million devices or more." Built on Elixir/Phoenix (not Ash), Postgres, and — as of v2.x — S3-compatible object storage; ships pre-built Docker images for self-hosting.

Core resources: **Products** (device families), **Devices**, **Firmwares**, **Deployments** (a deployment binds a firmware to a set of devices via tag matching and version conditions — a device only receives an update once a deployment targets it). Device-side application logic uses the `NervesHubLink.Client` behaviour: on receiving an update offer, the device itself returns `:apply`, `:ignore`, or `{:reschedule, ms}`, so the fleet-side push is advisory and the device decides readiness. Authentication is dual-mode: hardware certificates (mTLS) or a lower-friction shared secret. Other features: an interactive web-based remote IEx console into live devices, an "Archives" mechanism for bundling ancillary artifacts alongside a firmware release, and (per NervesHub 2.0 release notes) a Bandit-based rate-limiting overhaul.

The domain is fundamentally different from samen's: NervesHub moves signed binary firmware images to physical/embedded hardware over unreliable networks; samen is a web SaaS foundry governing PII-vaulted, multi-tenant application data. There is no Ash usage, no PII/masking concept, no multi-tenancy model — it is single-operator-fleet, not multi-tenant-SaaS. Docs fetch was partially blocked (404s on some pages), so some deployment-safety details (rollout percentage/canary controls, automatic rollback) could not be confirmed either way from primary sources.

## What samen could adopt

1. **Device-side accept/defer/reject callback for pushed directives** — What: NervesHub's `NervesHubLink.Client` pattern where the *target* of a fleet action returns `:apply | :ignore | {:reschedule, ms}` rather than the fleet controller unconditionally forcing the action. Why it fits: samen's Fleet cockpit (ADR-044) already sends "fleet directives" to registered apps and handles unreachable targets honestly (no fake "applied"), but a reachable-and-healthy target still has no way to say "not now" (e.g. mid-migration, mid-backup). Adding an analogous callback contract (`Samen.Fleet.Directive.Client` behaviour returning apply/ignore/reschedule) would let a tenant app defer a directive without the fleet controller mistaking silence for failure. Effort: S.

2. **Dual-mode device bootstrap auth (shared-secret-first, cert-upgrade-later)** — What: devices provision with a low-friction shared secret and can later be upgraded to hardware-certificate (mTLS) auth. Why it fits: samen's fleet self-registration already supports "secured credentials," but the shared-secret-then-cert progression is a concrete, low-effort onboarding UX to borrow for lowering friction on first-time fleet member registration while keeping a stronger long-term credential path. Effort: S.

## What to ignore and why

- **Everything firmware/OTA-specific**: signed binary image delivery, delta-patch application, A/B partition/bootloader handling, Buildroot/Nerves runtime integration, and the half-million-device connection-scaling work (dedicated PubSub/connection architecture) — samen manages software product instances via its own deploy-artifact chokepoint (ADR-014/024/026/038 fail-honest adapters), not binary firmware; none of this has an analogue in a web SaaS foundry.
- **Remote interactive IEx console into live nodes** — tempting as an operator-debugging feature, but directly at odds with samen's mask-by-default invariant (INV-1): a raw BEAM console is an unmediated escape hatch around every chokepoint (vault, masking, audit). Not worth the risk/effort even as a spike; samen's existing masked impersonation + observability surfaces are the sanctioned debugging path.
- **Deployment tag/version targeting mechanics** — conceptually already covered, and covered *with* PII/org-scoping discipline, by samen's own Fleet cockpit (per-operator×app→account assignment model) and Automation engine (Reactor-based, compensating steps); NervesHub's tag-matching is simpler and solves a narrower problem (which devices get which binary), not worth re-deriving from.
- **Archives (bundling ancillary firmware artifacts) and Bandit rate-limit migration** — minor, device-specific conveniences with no clear samen surface to attach to.
- **No Ash, no multi-tenancy, no PII/masking model** — the codebase offers nothing to samen's core moat (vault chokepoint, two-plane masking, crypto-shred, token-blind aggregates); it was never solving that problem.
