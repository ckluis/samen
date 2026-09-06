---
project: Bonfire
url: https://github.com/bonfire-networks/bonfire-app
category: Communication and Social
relevance: medium
verdict: Wrong domain (federated social) and wrong data layer (plain Ecto + Needle, no Ash), but its Boundaries ACL model and config-driven Epics pipeline are genuinely instructive references for samen's fine-grained-permissions and extensibility gaps.
---

# 064 — Bonfire

## What the project is

Bonfire is an AGPL-3.0, NGI/EC-funded Elixir framework for building **federated digital spaces** (ActivityPub). ~933 stars, ~2,000 commits, actively maintained; the "Social" flavour is 1.0, most other flavours (Community, Open Science, Coordination) are alpha/beta. It is not one app but a toolkit:

- **Extension architecture**: every feature and UI element lives in a separate git repo (`bonfire_*`), composed into deployable "flavours" (Ember, Social, Community, ...). Instances can enable/disable extensions.
- **Stack**: Phoenix + LiveView + Surface UI, PostgreSQL/Ecto (NOT Ash), Oban, GraphQL API, Meilisearch for full-text search.
- **Needle** (`bonfire-networks/needle`): a universal polymorphic-reference layer — a single `Pointer` table (`id` UUIDv7/ULID, `table_id`, `deleted_at`); every referenceable object gets a Pointer row so likes/follows/comments can target heterogeneous types with one FK. Adds `Pointable`/`Virtual`/`Mixin`/`Multimixin` schema macros, `strong_pointer()`/`weak_pointer()` migration helpers, and human-readable synthesized table IDs via Crockford Base32.
- **Boundaries**: a per-object, three-valued ACL system — *circles* (user-defined groups) × *verbs* (read, reply, like/boost, quote, mention, edit) × grants of Yes/No/Nil, resolved most-restrictive-first (No > Yes > Neutral), with preset boundaries (public, local, follows, mentions) and role bundles (Read → Caretaker). Boundaries are enforced locally even when remote federated servers ignore them.
- **Epics** (`bonfire_epics`): a config-driven pipeline engine — an Epic is a sequence of Acts (each a `run/2` module) declared in app config, with sequential and parallel steps, a shared assigns map, and act-level error accumulation. Because pipelines are config data, any extension can insert/wrap acts in another extension's workflow without touching its code.
- **Ops**: Docker Hub images + `Dockerfile.release`, Co-op Cloud (abra/Traefik) as the recommended path, bare-metal systemd, Nix flake and Guix options, `just` task runner, release channels (stable/RC/beta/alpha). Admin observability at `/admin/system/`: LiveDashboard, Oban queue monitor, LiveAdmin DB browser, Orion live profiling.

## What samen could adopt

1. **Boundaries' three-valued grant model (No > Yes > Neutral) as the design reference for finer-grained sharing/RBAC.**
   - *What*: circles (named user sets) × verbs × explicit-deny-wins grants, plus named reusable presets and role bundles that compile down to grants.
   - *Why it fits*: samen's open gap G28 is operator-RBAC granularity, and tenant-side sharing today is org-scope + role, with saved_views and support/CRM objects likely to need per-record or per-group sharing eventually. Bonfire is the most battle-tested Elixir implementation of "user-composable ACLs with explicit deny" — the resolution semantics (deny overrides, nil = fall through) map cleanly onto Ash policy checks the way samen already composes `OrgScope` + `PiiResolution`. Steal the model, not the code.
   - *Effort*: **M** for a scoped version (circle resource + grant check inside existing Ash policies for one surface like saved_views); **L** if generalized substrate-wide.

2. **Config-declared, extension-insertable pipelines (Epics pattern) as a review lens on the automation engine's extensibility.**
   - *What*: workflow steps declared as data in config so downstream packages can insert/wrap steps in an upstream workflow without editing it.
   - *Why it fits*: samen's ADR-039 automation engine (Action registry → Compile → Reactor) already covers execution, but Bonfire demonstrates the *authoring* seam: verticals (driftwood, pawchart) inserting acts into a substrate-owned flow (e.g. "on record create: also tag + notify") purely via config. That is the substrate-first (INV-5) shape for letting hosts extend built-in flows — worth an explicit seam in `Automation.Compile` if it doesn't exist.
   - *Effort*: **S** to audit/document the seam; **M** to add config-driven step injection to the automation compiler.

3. **Operator-plane live diagnostics endpoints (LiveDashboard + Oban monitor + Orion profiling).**
   - *What*: Bonfire mounts Phoenix LiveDashboard, an Oban queue view, and Orion (live tracing/profiling) under an admin scope.
   - *Why it fits*: samen has a first-party operator plane and an ops-hardening workstream (WS-L, G11 metrics/alerts); mounting LiveDashboard + an Oban queue surface behind operator auth is cheap, dependency-light, and complements the existing `/readyz` + metrics-egress work. (Orion optional; evaluate its dep surface first.)
   - *Effort*: **S**.

4. **Release-channel discipline for the flavour/host story.**
   - *What*: Bonfire ships stable/RC/beta/alpha Docker channels per flavour.
   - *Why it fits*: if samen ever offers `mix samen.gen.app` outputs to external builders (G22 packaging theme), a channel/tag discipline on the substrate is the minimal versioning story ADR-033 (in-monorepo, no Hex) still permits.
   - *Effort*: **S** (docs + tagging convention only).

## What to ignore and why

- **Needle universal-pointer data layer**: architecturally elegant but wrong for samen — it trades DB-enforced referential integrity for polymorphism, breaks Ecto preloads, requires per-type dereference queries, and would fight samen's Ash resources, `same_org_fk` verifier, catalog parity, and abbrev-prefixed tables. Samen's `object_ref` + catalog already solve the "reference anything" need in a verifier-friendly way. The Crockford Base32 synthesized-ID trick is cute but samen's abbrev registry covers naming.
- **ActivityPub federation and the entire social domain** (feeds, boosts, follows, flavours-as-products): unrelated to multi-tenant B2B SaaS.
- **Separate-repo-per-extension modularity**: directly contradicts samen's ADR-033 in-monorepo distribution and the verification story (root ci.sh, sabotage harness need one tree).
- **LiveAdmin database browser in the admin plane**: a raw DB browser is precisely what samen's masking-by-default forbids; the operator plane's masked surfaces are the correct substitute.
- **Meilisearch/Sonic external search services**: vendor/infra deps that would either violate INV-4 or demand a new adapter package; samen's non-PII tsvector path plus the planned per-abbrev GIN indexes are the aligned route.
- **Surface UI framework and GraphQL API**: samen is committed to plain LiveView function components and JSON:API; no benefit to switching.
- **Co-op Cloud/Guix deployment paths**: samen targets Fly; no overlap.
