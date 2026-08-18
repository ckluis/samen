# ADR-044 — The portfolio cockpit: the dual-mode fleet registry, the token-blind report wire, cross-product operator identity, fleet directives, and honesty from one product to N (WS-J J1–J5)

- **Status:** Accepted (design; T82–T84 implement. Doc-only per the standing
  decompose-cross-cutting-changes rule — this ADR authors no source, no tests, and
  touches no abbrev registry row). **Amended 2026-08-06 — see §16 (Amendment 1);
  §5.3/§5.4 must be read together with it.**
- **Date:** 2026-08-06
- **Task:** T81 — the WS-J architecture ADR (`blocked_by: [T73]`).
- **Deciders:** the operator, via three rulings:
  - **M10** (`_orch/plan/spec-questions.md`): *"BOTH — manual registration as the baseline
    PLUS opt-in self-registration/heartbeat for samen-generated apps, with a secured
    heartbeat credential story"*;
  - **Ruling 1, 2026-08-06** (§16): *"I think the tenant name is useable data, but we
    should probably be visible via a data unmasking per roles/rights/responsibilities.
    Maybe a sales person can only see their accounts for example."* — tenant identity is
    legitimate cockpit data, **masked by default and unmasked per-viewer by role scoping,
    down to account level**;
  - **Ruling 2, 2026-08-06** (§7.5, §12): honest degradation for cockpit-unreachable apps
    **confirmed exactly as specced** — observability without fleet flags, never a fake
    "applied";
  - **Ruling R-A, 2026-08-06** (§16.5 #1): the account scope comes from a **dedicated
    per-product assignment model** built in T84 (operator × app → account set, minimal
    admin surface, absent row ⇒ `:none`) — replacing this ADR's withdrawn, mis-cited
    "CRM owner field" default;
  - **Ruling R-B, 2026-08-06** (§16.4a): **account scope gates tier-3 drill-in entry too**,
    composed with — never instead of — the T146 role gate and the T150 session.

  Plus the standing keyless/fail-honest ruling (ADR-014/024/026). Recorded by fable.
- **Consumes (binding inputs):**
  - **ADR-037 §5.13 — ash_admin REJECT.** *"The first-party operator plane remains the
    only operator surface."* The cockpit is therefore a first-party `samen_web`
    operator-plane LiveView, plane-differentiated and 3-proof-testable; no generic
    admin renderer is mounted for the fleet, ever. §10 records the full consumption.
  - **ADR-010 §7.2 + T146** — `Samen.Web.Operator.Authz`, the `:operator_authority`
    host seam, and `Samen.OperatorPlane.Actor.operator_role/0`. J3 **extends this
    primitive**; it does not introduce a parallel identity model (§6).
  - **T150** — `Samen.Impersonation` + `Samen.Web.Operator.Impersonation`: the audited,
    reason-required, per-tenant session model. The fleet leaves it **per-product and
    unchanged** (§6.4), introducing no cross-product session and no reveal path.
  - **ADR-020 / `Samen.FeatureFlags`** — the fixed precedence ladder
    (kill-switch > deny > allow > targeting > rollout > default), fail-SAFE cache,
    non-PII targeting keys. J4 fan-out is a new **layer** on this engine, not a
    second engine (§7).
  - **T4.2 / `Samen.Aggregate`** — the token-blind aggregate actor, the
    `Samen.Aggregate.Resource` C7 `NoPiiColumns` compile verifier, the k-anonymity /
    l-diversity floors (`Samen.Aggregate.Privacy`), `%Samen.Aggregate.Suppressed{}`,
    and the mutual-exclusion rules (aggregate ⟂ reveal, aggregate ⟂ org-scoped read).
  - **ADR-035 §4.2** — the emitted-secret discipline (32 random bytes, SHA-256 digest
    at rest, atomic single-use consume, bounded context enum, Oban prune sweep). §4.4
    reuses it verbatim for the enrollment token.
  - **ADR-043** — the operator-plane/aggregate patterns and the "prove the negative
    with a structural probe plus a permanent CI tier" shape this ADR mirrors for the
    report wire.
  - **ADR-022** (the generator emits a running product) · **ADR-001** (KMS key
    hierarchy) · **ADR-014/024/026** (fail-honest adapters) · **ADR-031** (BYO-auth:
    authn is host-owned; the framework never owns the operator login).
  - spec §WS-J J1–J5 (`_orch/plan/traceability.yaml` J1–J5 verify clauses; roadmap
    Phase 6); INV-1..INV-6.
  - **Backlog T156** — cross-tenant platform-health dashboards (ESP-deliverability
    health index, platform automation/kill-switch overview, cross-tenant audit/activity
    feed). Per its own cross-ref, T156 **MERGES into T84**: one cockpit, no divergent
    aggregates. §5.3 + §5.5 are the contract that accommodates it.
- **Binds (implementing tasks):**
  - **T82** — §4 (registry, both modes, credential lifecycle, health probe) + §8 (J5
    honesty) + §9.3 (gen_app zero-config probe).
  - **T83** — §6 (cross-product operator identity; per-product role scoping;
    impersonation unchanged).
  - **T84** — §5 (report wire + cockpit aggregates, **including the merged T156
    surfaces**) + §7 (fleet directives / flags / announcements fan-out).

---

## 1 · Context

Samen is a foundry: one framework (`samen_core` + `samen_web`) generating and hosting
N products (`demo`, `driftwood`, `pawchart`, and every generated app). Each product is
a **separate Phoenix application with its own Postgres database** (`driftwood_dev`,
`pawchart_dev`, `demo_dev` — `*/config/{dev,test}.exs`). There is no shared schema, no
shared repo, and no cross-product foreign key. Any cross-product view is therefore a
**distributed** problem: something has to cross a process (and usually a network)
boundary.

Each product already has, at ≈0 authored LOC, everything the cockpit wants to see:
`Samen.Aggregate` token-blind rollups (cross-tenant MRR, queue depth), `Samen.Health`
scores, `Samen.FeatureFlags`, `Samen.Metrics` + `/metrics`, the deliverability /
automation / activity operator surfaces, and the T146-gated operator plane. What does
not exist is the **fleet** tier: no product knows another exists, and no surface
answers *"across everything I run, what needs me today?"*.

Three constraints shape every decision below.

1. **INV-2 (token-blind operator surfaces).** A cross-product view is the single
   easiest place in the whole system to accidentally build a PII aggregator: N
   products' data, one screen, no tenant boundary. The wire must be provably incapable
   of carrying PII — not policed, incapable.
2. **The credential problem is new.** Every other samen secret is either host-owned
   (ADR-031 authn) or subject-scoped (the vault). A fleet introduces a *long-lived,
   app-held, network-presented* credential for the first time. Its blast radius must
   be stated as a capability set and proven by a matrix test, not asserted.
3. **Honesty from 1 to N (J5).** The overwhelmingly common install is **one product**.
   A cockpit that looks like a fleet console with one truthful row and seven plausible
   fakes is worse than no cockpit — it is the exact lie `CLAUDE.md`'s fail-honest rule
   exists to forbid, rendered as a dashboard.

---

## 2 · Decision

1. **`Samen.Fleet` is a first-class kernel concern in `samen_core`**, with the cockpit
   surface in `samen_web`'s operator plane (INV-5). Verticals adopt with **one router
   macro call and one config line**; nothing fleet-shaped is authored in
   `demo`/`driftwood`/`pawchart` (§9).
2. **Two registration modes, per the M10 ruling** (§4). **Mode A (manual, the
   baseline):** an operator registers an app with a base URL and a shared secret; the
   **cockpit is the client** and pulls a report from the app's signed health probe.
   **Mode B (opt-in self-registration + heartbeat):** a samen-generated app enrolls
   once with a single-use enrollment token, mints its **own Ed25519 keypair**, and
   pushes reports; the cockpit stores only the **public** key.
3. **The heartbeat credential's capability set is exactly `{fleet:heartbeat}` —
   append-only, one app_id, zero read.** `POST /fleet/heartbeat` returns
   **`204 No Content` with an empty body, always**. A leaked heartbeat credential can
   submit a (lying) report for its own app and nothing else: it cannot read the fleet,
   another app's report, its own app's data, the operator plane, or any directive. This
   is proven by a route × credential **capability matrix** test with a positive control
   on every row (§4.6, RP-J-2). There is **no `POST /fleet/rotate`** — an app-initiated
   rotate verb is a credential self-takeover primitive; rotation is operator-issued
   re-enrollment (§4.5). Mode A's larger, non-zero-read radius is stated in full (§4.6).
4. **The `FleetReport` wire ADOPTS `Samen.WideEvent.Schema`'s type discipline unchanged
   and narrows it** — the permitted classes are exactly its four (`:opaque_id`, `:token`,
   `:enum`, `:number`), each additionally constrained by a declared `form:`/`range:` and
   every list by a `max_len:`. **No field of any text-carrying class exists**, so a PII
   value has nowhere to land ("there is no 'trusted string'"). Enforced at build by
   `mix samen.verify.fleet_wire` and re-validated at ingest (§5.1–5.2). The residual
   covert-channel capacity of the opaque-id fields against a *fully compromised producer*
   is bounded, measured, and stated rather than claimed away (§5.2b).
5. **No tenant identifier ever crosses the wire.** Fleet-tier metrics are counts and
   sums only. The T156 cross-tenant surfaces travel as **tier-2 cohort rows** keyed by
   a per-product HMAC pseudonym (`fleet_handle`), k-anon-floored **at the source**. The
   cockpit never learns an `org_id`. **Following a handle to a named tenant is tier-3
   access and takes the full tier-3 gate — T146 role AND a T150 impersonation session
   with a reason, in that tenant's ledger** (§5.3, §5.4).
6. **One operator identity, N authorizations, resolved by each product.** Per-product
   role scoping needs **no new primitive**: `Samen.Web.Operator.Authz` already calls
   `{mod, fun, args}` with the principal appended, so the **args list is the product
   scope carrier** — `{Fleet.Auth, :operator_role, [:driftwood]}`. The cockpit adds a
   reserved `:fleet` scope in the same grant map. No new role vocabulary; no
   cross-product bearer token (§6).
7. **Masked impersonation stays per-product, unchanged and untouched.** The fleet mints
   no session, holds no reveal grant, and its actors are structurally refused by
   `Samen.Impersonation.open/3`. The cockpit's deepest per-tenant affordance is a
   **link** into the owning product, where T146 + T150 apply exactly as they do today
   (§6.4).
8. **Fleet directives (flags + announcements) are always cockpit→app push**, applied over
   ADR-020 as a **one-way OFF authority**: any local off-state — kill, explicit deny, or
   **`rollout_pct: 0`** — beats every fleet input, and no fleet directive can move a flag
   from off to on (§7.3; expressed as a `local_off?` predicate rather than a ranked
   ladder, because a ranked ladder is what hid the `rollout_pct: 0` case). An app the cockpit cannot
   reach gets fleet **observability** but not fleet **flags**, and the cockpit says so
   — `directives: unreachable` — rather than rendering a fake "applied" (§7.5).
9. **`:embedded` is the default fleet mode and needs zero configuration.** A single
   generated app runs the cockpit in-process over a registry containing exactly one
   self-registered row: itself. No secret, no HTTP, no network. The 1-product render is
   the N-product render with n=1 — the same code path, which is what makes it honest by
   construction rather than by special case (§8).

---

## 3 · The fleet model

### 3.1 · Vocabulary (fixed here; used by T82–T84 verbatim)

| term | meaning |
|---|---|
| **product / app** | one deployed samen application with its own repo + database (`driftwood`, `pawchart`, a generated app). Identified fleet-side by a cockpit-assigned `app_id` (uuid) and a bounded `slug`. |
| **cockpit** | the operator-plane surface that renders the fleet. It is a *role*, not a separate deployment: any product that mounts `samen_operator_routes(..., fleet_cockpit: true)` is a cockpit. |
| **fleet** | the set of registered apps as seen by one cockpit. |
| **FleetReport** | the app→cockpit aggregate envelope (§5.1). The **only** thing that travels app→cockpit. |
| **FleetDirective** | the cockpit→app flag/announcement envelope (§7.2). The **only** thing that travels cockpit→app. |
| **fleet_handle** | a per-product HMAC pseudonym for a tenant org, used only in tier-2 cohort rows (§5.3). Never an `org_id`. |
| **transport** | how a report moves: `:embedded` (in-VM), `:pull` (cockpit reads the app's health probe), `:push` (app heartbeats to the cockpit). |

**Name collision, called out so nobody assumes a relationship.** `scripts/fleet-status.sh`
already exists and uses "fleet" in a **different** sense: it is a local developer script
that diffs each product's *required env secrets* against the current shell environment
(WS-F5 F5.6). It is not a client of anything in this ADR, shares no data, and is not
superseded by it. If the overlap proves confusing in practice, renaming that script
(e.g. `secrets-drift.sh`) is a cheap follow-up — deliberately **not** done here, since
this is a doc-only task and the script is referenced by existing runbooks.

### 3.2 · Three transports, one surface

```
:embedded   cockpit ── Samen.Fleet.Report.build/1 ──► itself        (mode: none, zero config)
:pull       cockpit ── GET  /fleet/health  ─────────► app           (mode A, shared secret)
:push       app     ── POST /fleet/heartbeat ──────► cockpit        (mode B, Ed25519)

directives  cockpit ── POST /fleet/directive ──────► app           (always cockpit→app)
```

`Samen.Fleet.Transport` is a behaviour with three implementations. The cockpit LiveView
reads **only** `Samen.Fleet.read/2` and never knows which transport produced a row. This
is the mechanism behind decision 9: swapping `:embedded` for `:push` changes the
plumbing, not the surface, so there is no separate "single product" render to be honest
*about* — it is the same render.

---

## 4 · J1 — the registry, the two modes, and the credential lifecycle

> **spec J1 verify:** *"M10 ruling (BOTH modes): manual register/list with shared-secret
> handshake (bad-secret red+control) PLUS opt-in self-registration/heartbeat tests
> (forged/revoked credential red+control; heartbeat credential grants zero read
> capability — probe); health probe endpoint per app"*

### 4.1 · Registry resources (`flt_*`, token-blind)

All five are `use Samen.Aggregate.Resource` — so the C7 `Samen.Verifiers.NoPiiColumns`
compile check runs on each, and a `pii_attribute`, a `vault` block, a `pii_`-shaped
column, or a relationship reaching a PII-bearing resource **fails the build** (INV-2
by construction, not by review).

| table | holds | notable columns |
|---|---|---|
| `flt_app` | one registered product | `app_id` (uuid, pk) · `slug` (bounded `^[a-z][a-z0-9_-]{1,38}$`) · `display_name` (operator-authored label, §5.2 note) · `mode` (`:embedded \| :manual \| :heartbeat`) · `base_url` (mode A only) · `status` (`:active \| :suspended \| :deregistered`) · `registered_at` · `stale_after_s` |
| `flt_credential` | one key version | `app_id` · `key_version` (int) · `kind` (`:shared_secret \| :ed25519`) · `public_key` (mode B, base64 — public, safe at rest) · `secret_ciphertext` (mode A only, ADR-001 KMS-wrapped, never a plaintext column) · `capability` (`:fleet_heartbeat \| :fleet_probe`) · `activated_at` · `retire_at` · `revoked_at` |
| `flt_enrollment_token` | a single-use enrollment grant | `token_digest` (SHA-256 only) · `app_slug` · `expires_at` · `consumed_at` — ADR-035 §4.2 discipline verbatim |
| `flt_report` | the latest report per app + a bounded history | `app_id` · `schema_version` · `generated_at` · `received_at` · `payload` (jsonb, schema-validated on ingest) · `transport` |
| `flt_directive` | a published fleet directive | `fleet_revision` (monotonic int) · `target` · `payload` (jsonb) · `published_by` (operator id — a bounded uuid) · `published_at` |

`flt_report` retention: latest row per app is kept indefinitely; history is pruned to
**30 days** by a standing Oban sweep (the ADR-035 §4.2 prune-sweep pattern). The
registry carries no tenant rows, so there is nothing crypto-shred-relevant in it.

**Abbrev note (registry is HANDS-OFF):** these five resources need abbrevs. T82 allocates
them **through `mix samen.abbrev.reserve` only** (ADR-023); this ADR reserves nothing and
names no abbrev string. The `flt` prefix is currently unclaimed but is a *suggestion* to
the allocator, not an allocation.

### 4.2 · Mode A — manual registration + shared-secret handshake (the baseline)

1. An operator opens `/operator/fleet/register` (role `:operator_admin` — §6.3) and
   supplies `slug`, `display_name`, `base_url`.
2. The cockpit mints a 32-random-byte shared secret, displays it **once**, and stores it
   KMS-wrapped in `flt_credential` with `capability: :fleet_probe`.
3. The operator pastes it into the app as `SAMEN_FLEET_PROBE_SECRET`. The app stores it
   KMS-wrapped too — HMAC is symmetric, so both sides necessarily hold it; §4.5 states
   that blast radius honestly rather than pretending otherwise.
4. The cockpit **pulls** on an interval (default 60 s): `GET /fleet/health`, signed
   (§4.4). The app verifies and returns a `FleetReport`.
5. Directives push the same way: `POST /fleet/directive`, cockpit-signed with the same
   secret.

The app initiates **nothing** in mode A and holds no credential that lets it *call*
anywhere — its secret is a verification key for inbound requests. That is why mode A is
the baseline: the credential surface is one host (the cockpit), not N.

**Red + control (T82):** a request signed with a wrong secret → `401`, no body, an
`aud_event` row; the identical request with the right secret → `200` + a schema-valid
report.

### 4.3 · Mode B — opt-in self-registration + heartbeat (samen-generated apps)

Mode B exists for apps the cockpit **cannot reach** (private VPC, NAT, ephemeral
hosts) and for the generated-app path where nobody wants to paste anything.

1. **Issue.** An operator generates an enrollment token in the cockpit for a slug. 32
   random bytes, URL-safe base64; **only `SHA-256(raw)` is persisted**; 24 h expiry;
   context enum `:fleet_enroll`. Displayed once. (ADR-035 §4.2, unchanged.)
2. **Enroll.** The app is configured with `SAMEN_FLEET_ENROLL_TOKEN` +
   `SAMEN_FLEET_COCKPIT_URL`. On first boot it **generates its own Ed25519 keypair**,
   keeps the private key in its own runtime secret store, and calls
   `POST /fleet/enroll` presenting `{token, public_key, build}`.
3. **Consume.** The cockpit consumes the token in **one atomic action** — the ADR-035
   §4.2 statement verbatim: `UPDATE … SET consumed_at = now() WHERE token_digest = $1
   AND consumed_at IS NULL AND expires_at > now()` RETURNING. Zero rows ⇒ invalid /
   expired / replayed ⇒ one generic failure. It then writes `flt_app` +
   `flt_credential{kind: :ed25519, capability: :fleet_heartbeat, key_version: 1}` and
   responds `{app_id, cockpit_public_key, heartbeat_interval_s, stale_after_s}`.

   **Identity comes from the token, never from the request.** `slug` and `display_name`
   are read from the consumed `flt_enrollment_token` row (operator-typed when the token
   was issued); `app_id` is **cockpit-assigned**. A `slug` or `display_name` present in
   the enroll body is **ignored**, not merged — so an enrolling app cannot name itself,
   impersonate another product's label in the cockpit UI, or place free text into
   `flt_app` (§5.2). Asserted by the §4.6 matrix row that sends a mismatched slug and
   checks the stored value came from the token.
4. **Heartbeat.** Every `heartbeat_interval_s` (default 60) the app signs and posts a
   `FleetReport` to `POST /fleet/heartbeat`. The cockpit validates the signature, the
   schema, the `app_id` binding, and the anti-replay window, then writes `flt_report`
   and returns **`204 No Content` with an empty body**.

**The private key never leaves the app; the cockpit stores only the public key.** A full
compromise of the cockpit database therefore yields nothing that can forge a heartbeat —
a strictly stronger posture than a shared secret, which is why mode B (the mode with a
long-lived, app-held, network-presented credential) is asymmetric while mode A follows
the operator's shared-secret ruling.

### 4.4 · Wire authentication (both directions)

One scheme, `Samen-Fleet-v1`, over a header:

```
Authorization: Samen-Fleet-v1 kid=<key_id>,v=<key_version>,ts=<unix>,nonce=<16B b64>,sig=<b64>

signing input = "samen-fleet-v1\n" <> METHOD <> "\n" <> PATH <> "\n"
                <> ts <> "\n" <> nonce <> "\n" <> sha256(raw_body)

mode A: sig = HMAC-SHA256(shared_secret, input)     — constant-time compare
mode B: sig = Ed25519.sign(app_private_key, input)  — verify against stored public key
```

- **Body-bound.** The body hash is inside the signature, so a captured request cannot be
  edited (e.g. to inflate an MRR figure or flip a flag).
- **Replay-bound.** `|now - ts| > 300 s` ⇒ `401`. A `nonce` seen inside the window ⇒
  `409` (nonce cache TTL 600 s). This matters concretely: replaying a captured heartbeat
  is a way to fake liveness for a product that is actually down, which would make the
  cockpit lie.
- **Fail-closed everywhere.** Missing header, unparseable header, unknown `kid`, unknown
  `key_version`, `revoked_at` set, `retire_at` passed, capability mismatch, or a body
  `app_id` that differs from the key's `app_id` ⇒ `401` (or `403` for the app_id
  mismatch), empty body, and an `aud_event` row. Never a partial success, never a
  descriptive error that distinguishes "unknown key" from "bad signature".
- **Constant-time in both the compare AND the control flow.** The HMAC compare uses
  `Plug.Crypto.secure_compare/2`. Separately — and this is the part that is easy to miss —
  an **unknown `kid` must not return faster than a known `kid` with a bad signature**, or
  the endpoint becomes an app-existence / key-id oracle. On an unknown `kid` the handler
  performs a **dummy verification against a fixed decoy key** and then fails, so both
  paths execute the same work. This mirrors the ADR-035 §4.4 sign-in dummy-verify
  precedent, which exists for exactly this reason. Asserted by a timing-distribution test
  in the same shape as the A2/A3 token-loop timing tests.

### 4.4a · The complete route surface

Every fleet route, its authenticator, and its plane. There are no others; anything not on
this table does not exist, and `mix samen.verify.fleet_wire` cross-checks the router
against this list so an undeclared route cannot be added silently.

| route | side | authenticated by | plane | returns |
|---|---|---|---|---|
| `GET /fleet/health` | app | `:fleet_probe` credential (mode A) | none | `FleetReport` |
| `POST /fleet/directive` | app | `:fleet_probe` (A) / cockpit Ed25519 (B) | none | `202` + applied revision |
| `POST /fleet/enroll` | cockpit | single-use **enrollment token** | none | `{app_id, cockpit_public_key, intervals}` |
| `POST /fleet/heartbeat` | cockpit | `:fleet_heartbeat` credential | none | **`204`, empty body** |
| `GET /operator/fleet`, `/operator/fleet/:app_id`, `/operator/fleet/directives`, `/operator/fleet/register` | cockpit | **operator session** (T146 `on_mount`) | operator | LiveView |
| `GET /fleet/apps` | cockpit | **operator session** (same T146 gate; a JSON read API for the cockpit's own UI + `scripts/`) | operator | app list |

**`GET /fleet/apps` is operator-session-authenticated, never credential-authenticated.**
The first draft used it in the capability matrix without declaring it, which left its
authenticator ambiguous — it is stated here so the §4.6 "no credential reads the fleet
list" row has a defined target.

**Rate limiting (ADR-037 §5.14, webhook-class ingress) and its two oracles.**
`POST /fleet/enroll` and `POST /fleet/heartbeat` are rate-limited. Two failure modes this
introduces, both of which would produce a *lying cockpit* if left alone:

1. **`429` as an existence oracle.** If a rate-limit response differs between a known and
   an unknown `kid`/`app_slug`, the endpoint leaks which apps exist. **Mitigation:** the
   limiter runs **before** credential lookup, keyed on source IP and on the *presented*
   `kid` whether or not it resolves, and emits a byte-identical `429` (no body, fixed
   `Retry-After`) in every case.
2. **Heartbeat starvation → a healthy app rendered stale.** An attacker who learns an
   app's `kid` could burn that app's bucket with garbage requests until real heartbeats
   are dropped, making the cockpit show a healthy product as stale — the exact J5 failure
   this ADR exists to prevent. **Mitigation:** buckets are keyed on
   `{kid, signature_valid?}`, so **signature-invalid traffic consumes a separate, much
   smaller bucket and can never consume the app's heartbeat budget**; and a burst of
   rejected heartbeats raises an `attention` entry of kind `:heartbeat_rejected`, so the
   cockpit renders *"being flooded"* rather than silently *"stale"*. Honest degradation
   again: the cockpit says what it actually knows.

### 4.5 · Credential lifecycle — issuance, revocation, scope (rotation via re-enrollment)

| phase | mode A (`:fleet_probe`) | mode B (`:fleet_heartbeat`) |
|---|---|---|
| **issuance** | cockpit mints 32 random bytes; shown once; KMS-wrapped at rest on both sides | app generates Ed25519 keypair locally; binds it to an `app_id` by consuming a single-use enrollment token; cockpit stores **public key only** |
| **scope** | exactly two verbs against **one** `base_url`: `GET /fleet/health`, `POST /fleet/directive` | **exactly one verb, with no exceptions:** `POST /fleet/heartbeat` for its own `app_id` |
| **rotation** | operator-initiated: mint `key_version+1`, both accepted until `retire_at` (default 24 h), then a standing Oban sweep revokes the old version. **No renew-in-place** | **operator-initiated re-enrollment only** — see below. There is no app-initiated rotation verb |
| **revocation** | `revoked_at` set by an `:operator_admin`, or cascaded by deregistration/suspension. **Deny-on-use, re-checked per request** | identical. A revoked key is dead on the very next request — no cached grant, mirroring `Samen.Impersonation.scope/3`'s deny-on-read |
| **compromise recovery** | revoke → rotate → re-paste | revoke → the app stops being able to report → it must re-enroll with a fresh operator-issued enrollment token |
| **post-revocation honesty** | the tile renders `revoked — not reporting`; its last report is excluded from roll-ups (§8.2) | identical |

**`POST /fleet/rotate` is deliberately NOT built** (it appeared in this ADR's first draft
and was removed). An app-initiated rotate-in-place verb is a **credential self-takeover**
primitive: a thief holding a stolen heartbeat key could rotate to a keypair *they*
control and evict the legitimate app — turning a bounded write-only leak into durable
exclusive control of that app's fleet identity, with the real app silently going stale.
It also contradicted the "exactly one verb" claim in the same table.

**Mode-B rotation is therefore re-enrollment**, over the path that already exists and is
already single-use, operator-gated, and sabotage-tested: an `:operator_admin` issues a
fresh enrollment token; the app generates a new keypair and enrolls with it; the old
credential is revoked on successful enrollment (overlap window `retire_at`, default
24 h). Cost: rotation needs an operator action rather than happening unattended. That is
the correct trade — key rotation is exactly the kind of authority that should require a
human, and it keeps the §4.6 capability set at literally one verb.

**Automated rotation is recorded as deferred (§12), with the design fixed in advance so
nobody re-invents the unsafe version:** it would require (a) proof-of-possession of the
**old** key over a cockpit-issued challenge nonce, **and** (b) the successor key landing
in a `pending` state that an `:operator_admin` must confirm in the cockpit before it
activates — so a thief's rotation attempt surfaces as a visible, refusable request rather
than a silent takeover. Trigger: a deployment with enough apps that manual rotation stops
being practical.

**No renew-in-place** and **deny-on-use-per-request** are deliberately the same two
properties the reveal-grant and impersonation-session models already carry
(`Samen.Reveal.Grants`, `Samen.Impersonation.Sessions`). This is one discipline for
time-boxed authority across the whole system, not a fourth invention.

### 4.6 · The blast radius of a leaked heartbeat credential (stated + testable)

**Statement.** A heartbeat credential authorizes exactly one thing: *append a
`FleetReport` for its own `app_id`*. It grants **no read access to anything.**

**By construction.** (a) `POST /fleet/heartbeat` returns `204 No Content` with an
**empty body** — there is no response channel to read through. (b) The credential
resolves to a `%Samen.Fleet.HeartbeatActor{app_id: …}`, which is not a `Samen.Scope`,
not a `Samen.OperatorPlane.Actor`, and not a `Samen.Aggregate.Actor` — so
`Samen.Policy.OrgScope` filters it to zero rows, `Samen.Policy.AggregateActorOnly`
refuses it, `Samen.Web.Operator.Authz.resolve_role/2` returns `nil` for it, and
`Samen.Reveal.reveal/5` refuses it. It is default-denied by every authorizer already in
the system; the fleet adds `Samen.Policy.FleetIngressOnly` so it is also denied on
fleet resources. (c) The capability enum on `flt_credential` is checked against the
route's declared capability before any handler runs.

**The one thing a thief CAN do** — and this is named, not hidden — is submit a *false*
report for that one app. That is why: reports are **advisory**, never authoritative for
money or access; **staleness is computed cockpit-side from `received_at`**, never from
the app-supplied `generated_at`; and a report cannot mint a grant, open a session, move
a flag, or change any product's behaviour. Its worst outcome is a wrong number on a
dashboard for one product, visible against that product's own history.

**Testable form — the capability matrix (T82, RP-J-2).** A table-driven test crossing
every route class with every credential kind. Every deny row carries a positive control
in the same test (anti-tautology, per `CLAUDE.md`).

| presenting | route | expect | positive control |
|---|---|---|---|
| valid heartbeat key | `POST /fleet/heartbeat` (own app_id) | `204`, **body == ""** | — |
| valid heartbeat key | `POST /fleet/heartbeat` (other app_id in body) | `403` | own app_id ⇒ `204` |
| valid heartbeat key | `GET /fleet/health` | `401` | probe secret ⇒ `200` |
| valid heartbeat key | `GET /fleet/apps` (cockpit read API) | `401` | operator session ⇒ `200` |
| valid heartbeat key | `GET /operator/fleet` (+ any `/operator/*`) | redirect to `/login`, renders nothing | operator role ⇒ `200` |
| valid heartbeat key | `POST /fleet/directive` | `401` | cockpit key ⇒ `202` |
| valid heartbeat key | `GET /fleet/directives/:app_id` | `404` (**route does not exist** — §7.5) | — |
| valid heartbeat key | `POST /fleet/rotate` | `404` (**route does not exist** — §4.5) | — |
| valid heartbeat key | `POST /fleet/enroll` | `401` (enrollment takes a token, never a credential) | valid unused token ⇒ `200` |
| **consumed** enrollment token | `POST /fleet/enroll` | `401`, generic | first use ⇒ `200` |
| **expired** enrollment token | `POST /fleet/enroll` | `401`, generic | unexpired ⇒ `200` |
| enroll body claiming a different `slug` than the token's `app_slug` | `POST /fleet/enroll` | slug is **ignored** — the token's `app_slug` is authoritative (§4.3) | assert the stored slug == the token's |
| unknown `kid` | any credential route | `401`, **timing-indistinguishable** from a known-kid bad signature | known kid + bad sig ⇒ `401` |
| over-limit, unknown `kid` | `POST /fleet/heartbeat` | `429`, **byte-identical** to over-limit known `kid` | — |
| signature-invalid flood on app X's `kid` | `POST /fleet/heartbeat` | app X's **valid** heartbeats still succeed (`204`); an `:heartbeat_rejected` attention entry is raised | no flood ⇒ no attention entry |
| revoked heartbeat key | `POST /fleet/heartbeat` | `401` | pre-revocation ⇒ `204` |
| retired key version | `POST /fleet/heartbeat` | `401` | inside overlap window ⇒ `204` |
| forged signature | `POST /fleet/heartbeat` | `401` | correct signature ⇒ `204` |
| replayed nonce | `POST /fleet/heartbeat` | `409` | fresh nonce ⇒ `204` |
| stale timestamp (>300 s) | `POST /fleet/heartbeat` | `401` | fresh `ts` ⇒ `204` |

Plus a **sabotage twin** (`scripts/sabotages/`): flip the heartbeat response from `204`
to `200` + a fleet-list body, and the named zero-read test **must fail**. That is what
makes the "grants zero read" claim refutable rather than decorative.

**Mode A's blast radius, stated in full.** The first draft of this ADR undersold it as
"read one PII-free report and push a directive"; the *push a directive* half is the
larger half and is spelled out here. A leaked `:fleet_probe` secret for app X can:

1. **Read** app X's `FleetReport` — by construction PII-free (§5.2), so this is the mild
   part;
2. **Kill any flag in app X**, fleet-directive-style — an **availability attack**: a
   forged directive with `kill: true` turns features off across every tenant of that
   product within one broadcast hop, and the ADR-020 precedence that makes fleet kill
   strong (§7.3) is exactly what makes this effective. It cannot turn anything *on*
   (§7.3's one-way rule), so the damage is denial, not privilege;
3. **Publish attacker-authored text to app X's tenants** — up to `120 + 2000 = 2120`
   characters of `title` + `body` in a tenant-visible announcement banner (§7.2),
   `audience: :all`. This is a **phishing surface** carrying the product's own branding:
   "your card failed, re-enter it here". It is the most serious consequence of a mode-A
   leak and it deserves to be named as such.

It still **cannot** read the fleet, list apps, reach another app, mint a grant, open an
impersonation session, or reach any operator surface — the radius is one product. But it
is neither zero-read nor read-only, and this ADR does not claim it is.

**Mitigations, stated so T82 builds them rather than discovering them:** (a) directive
pushes are **audited per app** with the publishing identity, and a directive arriving
with no matching cockpit-side `flt_directive` row at that revision raises an
`attention: :incident` entry — a forged push is therefore *visible*, not silent;
(b) announcements carry the publishing operator id and render an
`app.announcement_source` provenance line; (c) mode B, where the app stores only the
cockpit's **public** key and there is no shared secret to steal from the app side, is the
better posture and is the one the generator emits by default.

### 4.7 · The health probe endpoint (per app, J1)

`GET /fleet/health` on every app, mounted by `samen_fleet_routes/1`. Signature-
authenticated (mode A secret, or the cockpit's Ed25519 public key in mode B). Returns
the same `FleetReport` envelope the heartbeat pushes — **one schema, one builder
(`Samen.Fleet.Report.build/1`), three transports**, so there is no drift between what an
app pushes and what it serves. Fail-honest: an app with no fleet credential configured
returns `{:error, :not_configured}` → `503` with an empty body, never a `200` with an
empty-looking-healthy report (§11).

---

## 5 · J2 — the report wire and the cockpit aggregates (T156 merged)

> **spec J2 verify:** *"cockpit test: MRR roll-up/health/queue-depth/attention list
> across ≥2 registered apps; no_pii_columns + aggregate-privacy verifiers green on
> cockpit resources (INV-2)"*

**Cross-ref, additive (T77 fix round 1) — do not re-derive a THIRD health formula
here.** Two per-tenant health formulas already exist in `samen_web` and this ADR's
builders (T82/T84) should compose over one of them rather than inventing a new shape:
`Samen.Web.Operator.HealthScore` (WS-B/ADR-019 — the operator's own book-of-business
view of a tenant it directly bills) and `Samen.Web.AccountHealth` (T77, spec §I4 — the
narrower billing+support-only formula a tenant-plane mount can compute honestly on ANY
host, including ones with no Identity/activity signal). Whichever this cockpit's
per-app "health" column ultimately sources from (a per-app self-report over the fleet
wire, most likely), the ARITHMETIC should reconcile with one of these two, not diverge
into a third.

### 5.1 · The `FleetReport` v1 closed schema

Declared once as `Samen.Fleet.Report.Schema` — a compile-time field table that **adopts
`Samen.WideEvent.Schema`'s type discipline unchanged**, rather than defining its own.

**The four permitted classes are exactly `Samen.WideEvent.Schema.bounded_types/0`**
(`samen_core/lib/samen/wide_event/schema.ex`): **`:opaque_id`, `:token`, `:enum`,
`:number`**. Every other type atom — `:string`, `:binary`, `:text`, `:atom`, `:map`,
`:any`, `:term`, `:list` — is forbidden and fails the build. The precedent's rule is
adopted verbatim and quoted here because it is the whole argument:

> **"There is no 'trusted string' — the whole point is that a laundered name has nowhere
> to land."** — `wide_event/schema.ex`

ADR-044 **narrows** this discipline rather than widening it: each field additionally
declares a `form:` (for `:opaque_id`/`:token`) or a `range:` (for `:number`), so every
accepted value is a strict subset of what the precedent already permits at a sink.

| class | permitted `form:` / `range:` refinements in this schema |
|---|---|
| `:opaque_id` | `{:uuid_v4}` (canonical 36-char UUID) · `{:hex, 40}` (a git sha) — **fixed length, fixed alphabet** |
| `:token` | `{:hex, 32}` — the HMAC pseudonym class (`actor_id`'s class in the precedent) |
| `:enum` | a closed `allowed:` member list, declared at compile time |
| `:number` | an integer with a declared inclusive `range:`; `%Samen.Aggregate.Suppressed{}` is the one permitted non-numeric **value** (it replaces a suppressed cell, §5.3) |

**Three field types from this ADR's first draft were removed because they were free
text and would have failed the discipline they claimed to mirror:**

- **`:semver` is gone.** Its `(-[a-z0-9.]+)?` prerelease tail was unbounded
  producer-chosen text. Replaced by bounded numeric components plus an enum channel:
  `release_major/minor/patch` (`:number`) + `release_channel` (`:enum`).
- **`:slug` is gone from the wire.** A 39-character app-chosen slug is free text. The
  slug is now **cockpit-side only and operator-authored**: it is typed by the operator
  onto `flt_enrollment_token.app_slug` and is **never read from the enroll request or
  from any report** (§4.3). A producer cannot choose or change its own slug.
- **`:utc_datetime_usec` is gone.** Timestamps are `:number` — unix microseconds with a
  declared plausibility `range:` — so no date *string* is ever parsed from a producer.

```
FleetReport (schema_version: 1)          class      form / range
  app_id                                 :opaque_id {:uuid_v4}      # cockpit-ASSIGNED at enroll
  schema_version                         :number    1..1
  generated_at_us                        :number    plausibility window; advisory only
  window                                 :enum      [:instant, :hour_1, :day_1]
  build   release_major/minor/patch       :number    0..9999
          release_channel                :enum      [:stable, :rc, :beta, :dev]
          git_sha                        :opaque_id {:hex, 40}      # OPTIONAL; §5.2 allow-list
          env                            :enum      [:dev, :staging, :prod]
  health  status                         :enum      [:ok, :degraded, :down]
          score                          :number    0..100
          checks [ name :enum(closed check catalog), status :enum[:ok,:degraded,:down,:unknown] ]
  billing mrr_cents / arr_cents          :number    0..2^53
          active_subscriptions / delinquent_subs   :number 0..2^31
          mrr_by_tier [ tier :enum(plan-tier catalog), mrr_cents :number, tenant_count :number ]
  tenancy tenant_count / active_tenant_count / new_tenants_24h  :number 0..2^31   # COUNTS ONLY
  queues  oban [ queue :enum(app queue catalog),
                 available/executing/retryable/discarded :number 0..2^31,
                 oldest_available_age_s :number 0..2^31 ]
  support open_tickets / breaching_sla / oldest_open_age_s      :number 0..2^31
  deliverability  sent/delivered/bounced/complained/suppressed  :number 0..2^31
                  health_index                                  :number 0..100
  automation      rules_active / rules_tripped_24h / kill_switches_engaged :number 0..2^31
  attention [ kind :enum [:incident, :dunning, :sla_breach, :automation_trip,
                          :deliverability_degraded, :queue_backlog, :heartbeat_stale,
                          :heartbeat_rejected]
              severity :enum [:info, :warn, :critical]
              count :number 0..2^31
              since_us :number (plausibility range, carried-LOW 5 — T82) ]
  activity_counts [ event_kind :enum(closed audit-taxonomy catalog),
                     count :number 0..2^31 (carried-LOW 5 — T82) ]
  flags   engine_version / applied_fleet_revision               :number 0..2^31
  cohorts (OPTIONAL — tier 2, §5.3)
  suppressed_count                                              :number 0..2^31
```

**`report_id` was removed.** It was a producer-chosen 128-bit field with no consumer —
the cockpit assigns its own `flt_report.id` on receipt. Deleting it removes 16 bytes of
producer-chosen entropy for zero functional cost (§5.2b).

**Cardinality caps (declared in the schema, enforced at ingest).** Every list field
carries a `max_len:`: `checks` 32 · `mrr_by_tier` 16 · `queues.oban` 32 ·
`attention` 64 · `activity_counts` 64 · each `cohorts` list **256**. A report exceeding
any cap is rejected `422` and not stored. This bounds the total producer-chosen entropy
in a report, which is what §5.2b's residue argument is measured against.

### 5.2 · Why this provably carries no PII-capable field

The argument is structural, in four parts, and each part is a test rather than a claim.

1. **There is no field a PII value could occupy.** Every leaf type above is a bounded
   scalar or a member of a compile-declared closed enum. The schema contains **zero
   free-string fields**. A name, an email, an address, a note, a subject line, a URL —
   none has a slot. This is the same reason the wide-event schema is the load-bearing
   J2 defence in `docs/plan.md` (a runtime value guard catches shapes; the *schema*
   catches the category).
2. **The producer cannot reach PII either.** `Samen.Fleet.Report.build/1` runs as the
   **token-blind aggregate actor** and reads only through `Samen.Aggregate.read_all/2`
   over `use Samen.Aggregate.Resource` projections. `Samen.Verifiers.NoPiiColumns`
   already fails the build if such a resource declares a `pii_attribute`, a `vault`, a
   `pii_`-shaped column, or a relationship reaching a PII-bearing resource — and
   `Samen.Policy.OrgScope` filters the org-less aggregate actor to zero rows on any
   tenant-plane resource. The builder is therefore *incapable* of loading a subject,
   independent of the schema.
3. **No tenant identifier crosses at all** at tier 1. `tenancy` is counts;
   `mrr_by_tier` is tier + sum + count. There is no `org_id`, no user id, no email
   digest. The `%Suppressed{}` struct rides through untouched wherever the source's
   k-anon floor fired, so a suppressed cell stays suppressed across the wire and the
   cockpit renders `⊘` (the existing `Samen.Web.Operator.AggregateLive` chrome).
4. **Enforced at build and at ingest.** `mix samen.verify.fleet_wire` (new tier, T84)
   walks `Samen.Fleet.Report.Schema` and **fails the build** on any field whose declared
   type is not in the allow-list — so adding a `notes` field is a compile-gate failure,
   not a code-review catch. At ingest the cockpit **re-validates** the received payload
   against the same schema and rejects a non-conforming report with `422` rather than
   storing it (a compromised app cannot smuggle an extra key into `flt_report.payload`).

**Two named, bounded exceptions (operator-authored, never producer-supplied).** Both live
**outside** the app→cockpit report wire, which is what done-criterion 1 binds:

- **`flt_app.display_name`** — typed by the operator into the cockpit (mode A) or onto
  the enrollment token (mode B). It is **never read from an enroll request or a report**.
  In `:embedded` mode there is no operator and no token, so it defaults to the host's own
  **OTP application name** — a compile-time atom from the app's own mix project, not
  producer-runtime text. (This resolves the §8.1 provenance question: every path is either
  operator-typed or compile-time-fixed; none is runtime producer-chosen.)
- **`FleetDirective` announcement `title`/`body`** (§7.2) — operator-typed in the cockpit,
  travelling cockpit→app. Length-bounded and HTML-escaped on render.

Neither can be interpolated from tenant data, because the cockpit — being token-blind —
*has no tenant data to interpolate*.

### 5.2b · The residue: what a fully compromised producer can still do

§5.2 part 4 puts the compromised producer in scope, so the claim must be stated at that
threat level rather than at the honest-producer level. Doing so honestly:

**What is fully closed.** There is no field of a text-carrying class. A name, an email,
an address, a note, a subject line, or a URL has **nowhere to land** — not "is rejected
by a filter", but has no slot of a permitted type. Adding one fails the build. This is
the same closure the shipped wide-event sink has, and ADR-044 does not weaken it.

**What is not fully closed, stated plainly.** Two `:opaque_id`/`:token` fields
(`git_sha`, 20 bytes; each `fleet_handle`, 16 bytes) are fixed-width opaque values a
compromised producer chooses. A compromised producer could therefore use them as a
**low-bandwidth covert channel** — at most `20 + 16 × 3 × 256 = 12,308` bytes per
report under the §5.1 caps (**T82 correction**: the first-published figure of
`20 + 16 × 256` counted only ONE of the THREE cohort lists §5.3 actually declares
— `deliverability`/`automation`/`activity`, each `max_len: 256` — corrected here
and in §13; `Samen.Fleet.Report.Schema.residue_budget_bytes/0` computes this value
and is directly tested). This is not eliminable for any opaque-id field by any schema, and it is the
**identical, already-accepted exposure** the shipped precedent carries on `trace_id`,
`request_id`, and `actor_id`. Three things bound it, and the third is the real argument:

1. **Narrowed and reduced.** `report_id` (16 bytes, no consumer) is deleted; `git_sha` is
   `:opaque_id {:hex, 40}` and is **optional** — a cockpit configured with a registered
   build allow-list per app rejects any sha not on it and stores `:unknown` instead,
   which removes the field as a channel entirely for deployments that care.
2. **Never rendered as text, never searched — and after Amendment 1, mostly never sent to
   the client at all.** `git_sha` renders as a build badge; neither field is indexed,
   full-text-searched, or exported, so a covert payload lands in a jsonb column and is
   displayed to nobody. **Amendment 1 strengthens this bound rather than weakening it:**
   under §16.4a a **masked** tier-2 row carries no handle in the DOM whatsoever, so a
   handle now reaches a browser only for rows whose viewer is scope-entitled to resolve
   them — strictly fewer handles egress than when this argument was first written.
3. **The cockpit is not a privileged escape route.** A producer compromised badly enough
   to control its report already holds that product's plaintext tenant data locally and
   has a network. It does not need a 16-byte-per-cohort side channel to exfiltrate, and
   nothing about the cockpit makes exfiltration easier than the direct path it already
   has. INV-2's claim — *the operator's cross-product surface is not a PII store* — is
   preserved: a rate-limited, cap-bounded trickle of opaque bytes into an unrendered
   jsonb column does not make the cockpit one.

**This is recorded as an accepted consequence (§13), not a solved problem.** Anyone
tightening it further should delete `git_sha` and make handles cockpit-assigned on first
sight; both are cheap and both are recorded in §12.

### 5.3 · Tier-2 cohort rows — the merged T156 surfaces

T156 asks for three cross-**tenant** platform surfaces (ESP-deliverability health index,
automation/kill-switch overview, cross-tenant audit/activity feed). Per its cross-ref
these land **inside this cockpit**, as tier 2 of the same wire — not as a second,
divergent aggregate stack.

**`fleet_handle` — a pseudonym, not an identifier.**

```
fleet_handle = first 32 hex chars (16 bytes) of HMAC-SHA256( fleet_subject_key(app_id), org_id )
             # class :token, form {:hex, 32} — no "h_" prefix; the class is declared, not encoded
```

Per-product-keyed, exactly the `actor_id = HMAC(subject_key, subject_id)` construction
the wide-event tier already uses (and the same `:token` class): stable within one
product, non-reversible, unlinkable across products, and unlinkable at all once the key
is destroyed. It is **not** an `org_id` and the cockpit has no way to turn it into one.

**Cohort rows (optional section; emitted only when the app opts in):**

```
cohorts   deliverability  [ handle :token{:hex,32}, sent/bounced/complained :number,
                            health_index :number 0..100 | %Suppressed{} ]     max_len 256
          automation      [ handle :token{:hex,32}, rules_tripped :number,
                            kill_switches_engaged :number | %Suppressed{} ]   max_len 256
          activity        [ handle :token{:hex,32}, event_kind :enum,
                            count :number | %Suppressed{} ]                   max_len 256
```

**k-anon fires at the SOURCE, before the wire.** The producing app runs
`Samen.Aggregate.Privacy.apply/3` with the resource's `aggregate_cohort_spec/0`; any
cell below the k / l floor is replaced with `%Suppressed{}` *in the app*, so a
sub-threshold value never enters the payload, never touches the network, and never lands
in `flt_report`. Fail-closed is inherited: a cohort resource with no spec returns
`{:error, :no_cohort_spec}` and the whole `cohorts` section is omitted rather than sent
raw. The cockpit-side `Samen.Aggregate.QueryBudget` accounting applies to fleet cohort
reads too, keyed per cohort, so cross-query differencing across products is bounded by
the same defence.

**Answering "which tenant is bouncing?" — the deep link crosses INTO tier 3, and is
gated as tier 3.**

This is the single most dangerous seam in the ADR and the first draft got it wrong, so
it is stated exactly. The cockpit renders the handle row (tier 2: an opaque handle plus
counts, k-anon floored) and a deep link:

```
<product base_url>/operator/deliverability/resolve?fleet_handle=<32 hex>
```

That link lands on **one tenant's drill-in** — precisely the surfaces T150 gates today
(`deliverability_live.ex`, `activity_live.ex`, `automation_health_live.ex`). It is
therefore **tier-3 access and takes the full tier-3 gate**, not the tier-2 gate:

1. **T146 first.** The product's own `:operator_authority` seam must return an operator
   role for this principal *in this product*. No role ⇒ `:halt` + redirect, rendering
   nothing. (Role isolation is enforced by the product that owns the data — the only
   place it can be enforced correctly.)
2. **Handle resolution is not access.** `/resolve` maps handle → `org_id` server-side and
   **redirects** to the canonical `/operator/deliverability/:org_id`. Resolution alone
   grants nothing: it is a lookup, and it happens behind the T146 gate. An unknown handle
   redirects to the product's platform index with a flash, never to a drill-in.
3. **T150 second, unchanged.** The canonical drill-in runs
   `Samen.Web.Operator.Impersonation.gate/2` exactly as it does today. With no active
   session for `{this operator, this org}` the surface **denies and renders the
   open-session-with-reason form** — the arriving operator sees the same reason prompt
   they would see arriving from any other entry point, and opening a session writes the
   same tenant-visible ledger entry with who/why/expiry. **Arriving from the cockpit
   confers no session, shortens no TTL, and skips no reason.**

**The rule, absolutely:** *no tier-2 surface — in the cockpit or in a product — ever
renders per-tenant drill-in data without an active T150 session.* Tier 2 renders opaque
handles and floored counts; the moment a real tenant's rows are on screen, a session
exists and is in that tenant's ledger. The cockpit still never holds an `org_id`; the
product resolves it, and the accountability model is untouched.

> **AMENDED by Amendment 1 (§16, operator ruling 2026-08-06).** The paragraphs above
> describe indirection *only* — no name anywhere in the cockpit. The operator ruled that
> a tenant's **name is usable data**, visible through **role-scoped unmasking**. So a
> tier-2 row now renders a **masked-by-default display name** that resolves per viewer
> (§16.2), while everything else here stands unchanged: the **wire stays pseudonymous**
> (handle only), **no resolved name is ever stored**, and following a handle to a
> tenant's *data* is still tier-3 access behind T146+T150. Read §16 with this section.

**Red path (RP-J-11, T84/T83):** follow a cockpit deep link as an operator holding a role
in that product but with **no** impersonation session ⇒ the drill-in renders the
open-session form and **zero tenant rows** (assert on the DOM, refuting any row leak);
positive control — open a session with a reason, the same link renders masked rows and an
`imp_impersonation_session` row plus its `aud_event` exist. Second red path: the same
link as an operator with **no role in that product** ⇒ redirect to `/login`, nothing
rendered, no resolution performed (the handle must not be resolved before the T146 gate
runs — asserted by instrumenting the resolver).

### 5.4 · The gating ladder (three tiers — binds T84 and the T156 merge)

| tier | data | gate |
|---|---|---|
| **1 — fleet aggregates** | roll-ups, per-product tiles, health, queues, attention list | `roles[:fleet] != nil` (T146 role gate on the cockpit's `live_session`) |
| **2 — per-product cohort rows** | the T156 handle-keyed deliverability/automation/activity rows: k-anon-floored counts, keyed by handle, with a **masked-by-default tenant display name** | `roles[:fleet] != nil` **and** `roles[app_id] != nil` for the row; **plus** `handle ∈ scope_of(principal, app_id)` to unmask that row's **name** (Amendment 1, §16.2) — per row, per viewer |
| **3 — a named tenant's data** | `/operator/deliverability/:org_id` and friends, inside the product — **including anything reached by a tier-2 deep link** (§5.3) | the product's T146 role gate **plus** `handle ∈ scope_of(principal, app_id)` (ruling R-B, §16.4a) **plus** the T150 impersonation session. The T146+T150 pair is **unchanged by this ADR**; the scope conjunct is **added** by Amendment 1 and narrows nothing for `:all` roles |

Tiers 1 and 2 are the "legitimate SaaS-owned aggregates" line the T156 row draws
(mirroring accounts/billing/revenue): **operator-ROLE-gated, not
impersonation-session-gated**. Tier 3 is peering into one tenant's house and stays
session-gated, exactly as `Samen.Web.Operator.Impersonation`'s moduledoc already
partitions the operator plane today. The cockpit adds a rung to the top of the existing
ladder; it does not re-cut it.

**Tier 2 carries a fourth column after Amendment 1: per-row, per-viewer name resolution.**
A row's *counts* are gated by `roles[app_id]`; that same row's *tenant name* is
additionally gated by `handle ∈ scope_of(principal, app_id)` (§16.2), so one render can
legitimately show named rows and masked rows side by side. **Resolving a name does not
promote a row to tier 3** — it is a read of identity, not of the tenant's data (§16.4).

**Account scope runs down BOTH tiers (ruling R-B).** The same `scope_of/2` answer that
decides whether a tier-2 row shows its name also gates tier-3 *entry* at the owning
product's drill-in door (§16.4a). This keeps visibility and access consistent: an operator
who cannot see an account's name in the cockpit cannot walk into its drill-in either. And
because a scoped-out viewer can never enter, a masked tier-2 row carries **no deep link
and no handle in the DOM at all** — mask by omission extended to the client (§16.4a,
asserted in RP-J-14).

There is no differencing hole between tiers 1 and 2 because tier 1 carries **no tenant
axis at all** — a tier-1 total cannot be differenced against tier-2 rows to recover a
suppressed cohort, since tier 1 has no per-tenant decomposition to subtract from.

### 5.5 · Cockpit-side resources

`Samen.Fleet.Cockpit.*` projections are themselves `use Samen.Aggregate.Resource` and
read only via `Samen.Aggregate.read_all/2` with the singleton aggregate actor — so
`mix samen.verify.no_pii_columns` and `mix samen.verify.aggregate_privacy` cover the
cockpit's own resources, satisfying the J2 verify clause directly.

---

## 6 · J3 — cross-product operator identity

> **spec J3 verify:** *"one operator login spans products with per-product role scoping
> (red test: role in A grants nothing in B); masked impersonation tests still green per
> product"*

### 6.1 · The principle

**One identity. N authorizations. Each product remains the authority for its own plane.**

The cockpit does **not** mint a cross-product credential. There is no fleet bearer token,
because a token that opens N operator planes is a fleet-wide skeleton key — precisely
the artefact the T146 write-up exists to have eliminated. Authentication stays host-owned
(ADR-031); the fleet only standardizes how **authorization** is expressed per product.

### 6.2 · Per-product role scoping needs no new primitive

`Samen.Web.Operator.Authz.resolve_role/2` already does:

```elixir
{mod, fun, args} = Mount.label(mount, :operator_authority, nil)
validate_role(apply(mod, fun, args ++ [principal_id]))
```

The `args` list is baked per mount. **That list is the product-scope carrier.** A fleet
deployment wires:

```elixir
# driftwood/config/config.exs
config :driftwood, :operator_authority, {Fleet.Auth, :operator_role, [:driftwood]}
# pawchart/config/config.exs
config :pawchart,  :operator_authority, {Fleet.Auth, :operator_role, [:pawchart]}
```

and the resolver is a lookup in one grant map:

```elixir
def operator_role(app_scope, principal_id), do: get_in(grants(), [principal_id, app_scope])
```

Consequences, all of them free: the seam is unchanged; `AuthGate`'s conn-level twin is
unchanged; the fail-closed posture is unchanged (an unknown `{principal, app}` pair
returns `nil` ⇒ `:halt` ⇒ renders nothing); `dev_operator_role/2`'s prod-armed
fail-closed guarantee is unchanged. **T83 adds a resolver and a grant store, not an
identity model.**

`Samen.Fleet.Authz.roles_for(principal_id) :: %{scope => Actor.operator_role()}` is the
one new function — the fleet-wide read of the same grant store, used to decide which
tiles a cockpit renders. `scope` is a product slug **or** the reserved atom `:fleet`.

### 6.3 · Role vocabulary and the cockpit's own gate

**No new roles.** The closed set stays `Samen.OperatorPlane.Actor.roles/0`:
`:operator_admin | :operator_support | :operator_readonly | :operator_break_glass`. A
grant is `{principal_id, scope} → role`.

| capability | requires |
|---|---|
| render the cockpit at all | `roles[:fleet] != nil` |
| see tier-1 fleet aggregates | `roles[:fleet] != nil` |
| see tier-2 cohort rows for app X | `roles[:fleet] != nil` **and** `roles[X] != nil` |
| register / deregister / suspend an app | `roles[:fleet] == :operator_admin` |
| issue an enrollment token, or revoke a credential (rotation is re-enrollment, §4.5) | `roles[:fleet] == :operator_admin` |
| publish a fleet directive (flag or announcement) | `roles[:fleet] == :operator_admin` |
| fleet-wide kill (`kill: true`) | `roles[:fleet] == :operator_admin` |
| open a per-tenant drill-in in product X | product X's own T146 gate **+** a T150 session — unchanged |

The cockpit LiveView is mounted **inside** `samen_operator_routes(..., fleet_cockpit:
true)` specifically so it inherits the `on_mount {Samen.Web.Operator.Authz,
:require_operator}` hook that macro already attaches.

**"There is no un-gated path" is a property to be PROVEN, not assumed.** The first draft
asserted it. That assertion is exactly the hole T146 was created to close and had to
re-close in its own rounds 2 and 3: `samen_operator_routes/2` previously emitted a bare
`live_session` with no `on_mount` hook, and every operator surface behind it was
authenticated-but-not-authorized. A new route added to that macro is one careless line
away from repeating it, and an ADR sentence prevents nothing. So the property is
discharged by a **named, enumerating test** rather than by this paragraph:

`samen_web/test/samen/web/fleet_cockpit_authz_test.exs` (T84) —
(a) **enumerate the router at test time** (`Phoenix.Router.routes/1`), select every route
under the cockpit's live_session, and assert each one's session carries
`{Samen.Web.Operator.Authz, :require_operator}`. Enumerated, never hand-listed, so a
route added later without the hook fails the test the day it is added;
(b) end-to-end per route: a plain authenticated **tenant** user ⇒ redirect to `/login`,
**zero** cockpit markup in the response body; an operator with `roles[:fleet]` ⇒ `200`;
(c) **sabotage twin** (`scripts/sabotages/`): delete the `on_mount` from the cockpit
branch of the macro and the named test must FAIL — which is what makes (a) refutable.

**Role-isolation red test (T83, RP-J-5).** `Fleet.Auth.operator_role(:pawchart, alice)`
⇒ `nil` while `Fleet.Auth.operator_role(:driftwood, alice)` ⇒ `:operator_admin`; then
the same assertion end-to-end at the surface: alice's session reaches driftwood's
`/operator/*` and is redirected to `/login` on pawchart's, with a per-capability table
asserted row by row and a same-product positive control on every row.

### 6.3a · Seams this ADR specifies (adoption reality — read before estimating T83/T84)

Four things the first draft left implicit. Each is a real edit someone has to make.

1. **`Samen.Fleet.Authz.roles_for/1` is itself a HOST SEAM, not framework-owned data.**
   Grants are host-owned for the same reason authn is (ADR-031): the framework cannot
   know who your operators are. It is wired as an MFA exactly like `:operator_authority`
   — `config :my_app, :fleet_authority, {Fleet.Auth, :roles_for, []}` — and **fails
   closed** (no seam ⇒ `%{}` ⇒ no cockpit, no tiles). The framework ships no default
   roster and no dev fallback beyond the existing, prod-armed-fail-closed
   `dev_operator_role/2` pattern.
2. **`Samen.Web.Mount` carries a CLOSED label whitelist.** `mount.ex` enumerates the
   permitted label keys (`operator_authority` is one of them). Any new mount label this
   work needs — e.g. a fleet scope label — **must be added to that list**, or it is
   silently dropped at `Mount.from_session/1` and the gate reads `nil`. T83 must edit
   that list deliberately; a missing key fails open-looking (a `nil` label) rather than
   loudly, so it needs a test.
3. **There is currently NO `:fleet_cockpit` opt on `samen_operator_routes/2`.** This ADR
   *specifies its addition* (T84); it is not an existing switch being flipped. The macro
   gains a branch that emits the cockpit routes inside the already-gated `live_session`.
4. **Driftwood wires `:operator_authority` in FIVE places** — `router.ex` lines 285, 305,
   348, 402 (four separate mounts/label maps: the operator scope, the chat mount, the
   impersonate mount, and the live-nav session) plus `config.exs:101` (the conn-level
   app-env twin). Per-product role scoping means changing the MFA args at **all five**,
   and a missed site silently keeps the old unscoped resolver — which would grant a
   cross-product role by omission. T83 must treat "all five updated" as an explicit
   checklist item with a grep assertion, not a code-review hope. Pawchart currently wires
   none of them (backlog T157).

### 6.4 · Masked impersonation stays per-product, unchanged

**The claim.** WS-J introduces **no** cross-product impersonation session, **no**
fleet-wide reveal grant, and **no** new masking code — and therefore cannot regress any
existing masking proof.

**Why it holds by construction, not by care.**

- `imp_impersonation_session` rows live in each **product's** database, keyed
  `{operator_id, org_id}`. There is no fleet table for them and no cross-database
  session concept. The cockpit's deepest per-tenant affordance is an **HTTP link** into
  the owning product.

  > **AMENDED by Amendment 1 (§16.4a, operator ruling R-B).** This bullet originally
  > continued *"where `Samen.Web.Operator.Impersonation.gate/2` runs exactly as it does
  > today, denies exactly as it does today, and renders exactly the same open-with-reason
  > form"* — **all three clauses are now false**, and are corrected here rather than left
  > to contradict §16.4a. Ruling R-B adds a **scope conjunct** to the drill-in gate:
  > `gate/2` gains `org_id ∈ scope_of(principal, app_id)`, it denies in one new case (a
  > scoped-out operator), and a scoped-out operator is denied **before** the
  > open-with-reason form is rendered — so the form is no longer always what a denied
  > operator sees. **What remains true, and is the claim this bullet actually needs:** the
  > session model itself is unchanged — same table, same keying, same TTL, same
  > reason requirement, same ledger entry, same per-request deny-on-read. R-B **narrows**
  > who may reach the form; it changes nothing about what a session is or how it is
  > audited, and `:all`-scope operators see behaviour identical to today's.
- The fleet's actors are structurally refused by the session runtime:
  `%Samen.Fleet.HeartbeatActor{}` and the cockpit's aggregate actor are not
  `%Samen.OperatorPlane.Actor{}`, so `Actor.may_impersonate?/1` is false and
  `Samen.Impersonation.open/3` returns `{:error, :not_authorized}`. Likewise
  `Samen.Reveal.reveal/5` refuses an `:operator_aggregate` actor structurally (the
  shipped T4.2 mutual exclusion).
- The fleet never renders a 🔒 field, because no 🔒 field can reach it (§5.2). **No new
  entry joins the VAULT masking watch-list** — the plane-axis, `Samen.Api.PiiResolution`
  discipline this bullet is about is untouched, and no fleet surface resolves a
  vault-routed value on any plane.

  > **AMENDED by Amendment 1 (§16.3).** This bullet originally continued *"and
  > `Samen.MaskingCase` needs no new consumer"*, which is **no longer true and was
  > contradicted by §16.3 as first written.** Amendment 1 introduces a **second, distinct
  > mask class**: a per-viewer **SCOPE** mask over a plain `:string` of SaaS-owned data
  > (a tenant's display name), gated by `scope_of/2` rather than by plane. It is not a
  > vault mask, it does not route through `PiiResolution`, and `MaskingCase`'s
  > plane-oriented helpers do not apply to it — but it **is** a masking obligation with
  > its own three proofs (§16.3). The precise claim that survives is: *the fleet adds no
  > **vault/plane** mask, and adds exactly one **scope** mask.* Both watch-lists are named
  > in §16.3 so neither discipline can be assumed to cover the other.

**Testable form (T83, RP-J-6):** (a) the existing per-product impersonation masking
suites re-run **green in the same run** that lands the fleet
(`samen_core/test/impersonation_masking_test.exs`,
`samen_web/test/samen/web/operator_impersonation_gate_test.exs`,
`demo/test/adversarial/impersonation_bypass_matrix_test.exs`,
`driftwood/test/operator_impersonation_console_test.exs`); (b) an explicit refusal test
per fleet actor against `Samen.Impersonation.open/3` and `Samen.Reveal.reveal/5`, each
with an `%OperatorPlane.Actor{}` positive control; (c) a **structural grep probe** — no
module under `Samen.Fleet.*` or `Samen.Web.Operator.Fleet*` references
`Samen.Impersonation`, `Samen.Reveal`, or `Samen.Api.PiiResolution` — in the shape of the
ADR-037 §4.5 consumer-sweep precedent.

### 6.5 · Deployment postures (honest scope boundary)

- **Co-resident** (products in one BEAM / behind one identity store): one login, and
  §6.2's args-list scoping gives per-product roles with zero new machinery. This is the
  posture T83 builds and tests.
- **Separately deployed** (the real multi-host fleet): the cockpit deep-links, and each
  product authenticates the operator independently through its **own** ADR-031 host auth
  (typically the same OIDC IdP, which is where the "one login" experience actually comes
  from). **Fleet SSO / a shared session cookie is explicitly NOT built** — it is a
  documented seam with a revisit trigger (§12). Building a fleet-wide session before a
  real multi-host deployment demands it would be inventing a skeleton key on
  speculation.

**Amendment 1 interaction (§16.2), stated so the two sections cannot be misread together:**
in the separately-deployed posture **the cockpit still deep-links** — exactly as this
section says — and the link still works. What is unavailable is only the **tenant name
displayed beside it in the cockpit**, because the cross-origin resolution call needs the
viewer authenticated at the product, which is this section's open seam. Arriving at the
product, the operator authenticates there and the product's **own** T146 + scope + T150
gate applies normally (§16.4a). No deployment topology can cause a product-local drill-in
to deny an operator its own assignment data entitles.

---

## 7 · J4 — fleet flags and announcements

> **spec J4 verify:** *"fleet flag/banner test: cockpit publish reaches ≥2 products' flag
> engines"*

### 7.1 · Direction: always cockpit → app

Directives are pushed by the cockpit to each app's `POST /fleet/directive`, signed by the
cockpit (mode A: the shared secret; mode B: the cockpit's Ed25519 private key, whose
public half the app received in its enroll response). **The heartbeat response is never
a directive channel** — that is what keeps `POST /fleet/heartbeat` a literal `204` with
an empty body and keeps §4.6's zero-read claim clean and testable.

### 7.2 · The `FleetDirective` v1 envelope

**This envelope is deliberately NOT bound by §5.1's four-class discipline, and the types
below are not shared with `FleetReport`.** The report wire is app→cockpit and must be
incapable of carrying tenant data; the directive is cockpit→app **operator-authored
content**, where free text is the point. Keeping the two schemas separate is what lets
§5.2's "no field a PII value could occupy" claim stay absolute for the direction
done-criterion 1 binds. `verify.fleet_wire` checks the two schemas independently and must
never be relaxed to share a type table between them.

```
FleetDirective (schema_version: 1)
  fleet_revision  :integer                    # monotonic, cockpit-issued
  issued_at       :utc_datetime_usec
  target          :all | {:apps, [:uuid]}
  flags           [ name        :flag_name      # ^[a-z][a-z0-9_.]{1,63}$
                    kill        :boolean
                    enabled     :boolean
                    rollout_pct 0..100
                    variant     :enum | nil
                    rules       [ %Samen.FeatureFlags.TargetRule{} ]   # non-PII keys, enforced at write
                  ]
  announcements   [ id        :uuid
                    severity  :enum [:info, :warn, :critical]
                    audience  :enum [:operator, :tenant_admin, :all]
                    starts_at, ends_at :utc_datetime_usec
                    title     :string(120)     # operator-authored
                    body      :string(2000)    # operator-authored, markdown-escaped on render
                  ]
```

Targeting rules reuse `Samen.FeatureFlags.TargetRule` unchanged, so the existing non-PII
targeting-key enforcement (`Samen.FeatureFlags.NonPiiTargeting`) applies to fleet-published
rules for free — a fleet rule cannot target on a PII key any more than a local one can.

`title`/`body` are the §5.2 named exception: operator-authored, bounded, escaped, and
structurally incapable of carrying tenant data because the cockpit holds none.

### 7.3 · Precedence — fleet composes one way (safety only)

The first draft expressed this as a linear ladder, and the ladder had a hole:
`Samen.FeatureFlags.eval_rollout/5` treats **`rollout_pct <= 0` as OFF**
(`feature_flags.ex:174-182`, `%Decision{on: false, reason: :rollout_out}`). Setting
`rollout_pct: 0` is therefore a completely ordinary way for a local operator to disable a
flag during an incident — and in the draft's ladder a FLEET rollout sat *above* local
rollout and would have silently re-enabled it. That contradicts the stated intent, so the
rule is restated as a **predicate, not a position in a list**:

```
local_off?  =  local kill                       # enabled == false
            OR local explicit deny matches
            OR local rollout_pct <= 0           # feature_flags.ex:174-182 — an OFF state
            OR local variant/gate resolves off

if local_off?          -> OFF   (reason: :local_off)          # FLEET IS NOT CONSULTED
else if fleet kill     -> OFF   (reason: :fleet_kill)
else                   -> the ADR-020 ladder, with fleet rollout/variant/allow
                          layered UNDER local explicit deny and local targeting
```

**The rule in one line: fleet is a one-way OFF authority. Any local off-state — kill,
explicit deny, or `rollout_pct: 0` — beats every fleet input, and a fleet directive can
never move a flag from off to on.** A fleet kill still wins over everything local that is
*not* an off-state, so the fleet operator keeps the ability to stop a bad rollout across N
products in one action.

Rationale: safety levers must compose (any kill anywhere wins), while enablement must not
(a fleet publish must not silently re-enable a feature a product's own operator disabled).
This is the same fail-SAFE posture the engine already takes on cache errors, applied to a
second authority. It is expressed as `local_off?` rather than as a ranked list precisely
because a ranked list is what hid the `rollout_pct: 0` case.

**Red path (RP-J-8b, T84):** local `rollout_pct: 0` + a fleet directive with
`rollout_pct: 100` ⇒ the flag stays **OFF** with `reason: :local_off`; positive control —
remove the local `rollout_pct: 0` and the same directive turns it ON. The equivalent case
for local explicit deny and local kill is asserted in the same table.

Fleet-supplied config lands in `Samen.FeatureFlags.Cache` as a distinct layer, so the
existing write-through invalidation means a fleet kill takes effect **within one
broadcast hop** — the ADR-020 §3.3 property, inherited unchanged.

### 7.4 · Acknowledgement and drift

The app records the highest `fleet_revision` it has applied and reports it back in the
next `FleetReport` as `flags.applied_fleet_revision`. The cockpit compares that to the
published revision and renders per product: `applied` / `pending (published N, applied
M)` / `unreachable`. **The cockpit learns directive drift from the report** — i.e. from
the channel that already exists — so no read capability is added to any app-held
credential to support J4.

### 7.5 · Unreachable apps: honest degradation, not a fake apply

An app that can heartbeat out but cannot be reached in (NAT, private VPC) gets fleet
**observability** and not fleet **flags**. The cockpit renders `directives: unreachable`
on that tile, an `attention` entry of kind `:incident`/`severity: :warn`, and **never**
shows the directive as applied.

`GET /fleet/directives/:app_id` — an app-initiated directive **pull** — is deliberately
**not built**: it would require a second app-held credential with a genuine read
capability, which would cost the clean §4.6 claim. §12 records it as a deferred
sub-decision with an explicit revisit trigger (a real on-prem deployment that needs fleet
flags). Choosing honest degradation over a weakened credential contract is the same trade
the fail-honest adapter rule makes everywhere else in this codebase.

---

## 8 · J5 — honest from one product to N

> **spec J5 verify:** *"gen_app probe: fresh single app registers with zero config and
> cockpit renders it (1-product honest state)"*

### 8.1 · `:embedded` is the default and needs zero configuration

`Samen.Fleet.mode/1` defaults to `:embedded`. In embedded mode:

- the registry is seeded at boot with **exactly one row: this app**, derived from its own
  **compile-time** identity — the OTP application name (`slug`, `display_name`) and the
  release metadata baked at build (`release_*`, `git_sha`, `env`). Nothing here is
  runtime producer-chosen text, which is what keeps it consistent with §5.2's
  operator-authored-or-compile-time rule: in embedded mode there is no operator to type a
  `display_name`, so the OTP app name is used, and an operator may override it in the
  cockpit later;
- reports are produced in-VM by the same `Samen.Fleet.Report.build/1`;
- **there is no credential, no secret, no HTTP call, and no network dependency.** There
  is nothing to configure and nothing to leak.

A freshly generated app therefore has a working, truthful `/operator/fleet` the first
time it boots — which is exactly the J5 gen_app probe.

### 8.2 · The honesty rules (each one a T82 assertion)

1. **The registry never contains an app that did not register.** No seeds, no demo rows,
   no placeholder fleet. Empty-except-self is the floor.
2. **A metric the app cannot compute renders `—` with a `not_available` reason — never
   `0`.** "Zero support tickets" and "we don't know how many support tickets" are
   different facts and the cockpit distinguishes them. (This is `{:error,
   :not_configured}` rendered, and the `%Suppressed{}` `⊘` precedent extended.)
3. **A stale report is labelled stale and excluded from roll-ups.** Staleness is
   `received_at + stale_after_s < now` (cockpit clock, never the app's `generated_at` —
   §4.6). The tile shows `stale · last seen 14m ago`; the roll-up header shows
   `MRR across 3 of 4 products reporting`. A down product is never silently summed as
   its last-known-good value.
4. **Unconfigured multi-app mode fails honestly.** `mode: :manual` or `:heartbeat` with
   no credential ⇒ `{:error, :not_configured}` ⇒ the cockpit renders the
   not-configured state **naming the exact config it needs**, never a confident empty
   dashboard. (`CLAUDE.md`'s fail-honest contract; the `Samen.Files.Storage.S3` /
   `Samen.Delivery.Smtp` class.)
5. **One product reads as one product — and this is DERIVED, not branched.** The first
   draft stated this as a chrome requirement while §8.3 simultaneously claimed no `n == 1`
   branch exists; those cannot both be true if the chrome is conditional. They are
   reconciled by making the chrome a **function of the row set** rather than a mode:
   - the header is `"#{n} #{pluralize(n, "product")}"` — one expression, no branch;
   - every comparison affordance (rank column, per-product delta vs fleet median,
     "other products" shelf) is rendered **per row inside the same comprehension** as the
     tiles, so with one row there is simply nothing to emit. Their absence at n=1 is a
     consequence of iterating one row, not of a conditional suppressing them;
   - the roll-up header is always `"across #{reporting} of #{total} products reporting"`,
     which reads correctly and truthfully at n=1 with no special case.

   The only genuinely conditional element is the **not-configured** state (rule 4), which
   is keyed on `mode` and credential presence — not on `n` — and is therefore not a
   single-product branch at all.
6. **A revoked or deregistered app is shown as such**, with its last report excluded
   from roll-ups — not quietly dropped (which would silently change a total) and not
   quietly retained (which would report a dead product as live).

### 8.3 · Why this is honest *by construction*

Because `:embedded` is a `Samen.Fleet.Transport` implementation and the LiveView reads
only `Samen.Fleet.read/2`, **the 1-product render is the N-product render with n=1**.
There is no "single product mode" branch that could drift from the real one, and no
demo-data path that could be reached in production. Per rule 5, the single-product chrome
is *derived from the row count* rather than selected by it, so there is no `n == 1` code
path for the honesty rules to be asserted against separately — they are assertions over
one path.

**Testable form (RP-J-9b, T82/T84):** render the same component with 1 row and with 3
rows, from the same call site with **no mode flag**, and assert the DOM directly —
n=1 shows `1 product`, no rank column, no delta column, no peer shelf; n=3 shows
`3 products` and all three affordances. A grep assertion accompanies it: the cockpit
module contains no comparison against a row-count literal (`== 1`, `<= 1`, `length(...) ==
1`) outside the pluralization helper — which is what makes "derived, not branched"
checkable rather than aspirational.

---

## 9 · Where the code lives (INV-5), ≈0-LOC adoption, and the ≥2-vertical proof

### 9.1 · Placement

| module | package | why |
|---|---|---|
| `Samen.Fleet` (facade), `Samen.Fleet.{Registry,Report,Report.Schema,Directive,Credential,Transport,Transport.{Embedded,Pull,Push},HeartbeatActor,Handle}` | **`samen_core`** | kernel: resources, schema, crypto, policy. Web-dep free, like `Samen.FeatureFlags`. |
| `Samen.Policy.FleetIngressOnly` | **`samen_core`** | the default-deny policy for the heartbeat actor, beside `AggregateActorOnly`. |
| `mix samen.verify.fleet_wire` | **`samen_core`** | a verifier tier, beside `samen.verify.aggregate_privacy`. |
| `Samen.Web.FleetController` (`/fleet/health`, `/fleet/directive`), `Samen.Web.FleetIngressController` (`/fleet/enroll`, `/fleet/heartbeat`) — the full route table is §4.4a | **`samen_web`** | HTTP surfaces, `Samen.Web.MetricsController`-shaped: self-gating, fail-honest, no plane. |
| `Samen.Web.Operator.Fleet{Live,DetailLive,DirectivesLive,RegisterLive}` | **`samen_web`** (operator plane) | the cockpit. Mounted inside `samen_operator_routes/2` so it inherits the T146 `on_mount` gate (§6.3). |
| router macros `samen_fleet_routes/1` (app side) and `samen_fleet_ingest_routes/1` (cockpit side); `fleet_cockpit: true` opt on `samen_operator_routes/2` | **`samen_web`** | the ≈0-LOC adoption seam, following `samen_metrics_route/1`. |

**Nothing fleet-shaped is authored in `demo`, `driftwood`, or `pawchart`.** ADR-037
§5.13's REJECT is honored by construction: the cockpit is a first-party operator-plane
LiveView with plane-differentiated rendering, not a generic admin renderer (§10).

### 9.2 · Adoption cost per product

```elixir
# router.ex — reporting side (every product, including cockpits)
samen_fleet_routes(otp_app: :pawchart)

# config.exs — mode. Omit entirely for the zero-config :embedded default.
config :pawchart, :fleet, mode: :heartbeat   # + SAMEN_FLEET_ENROLL_TOKEN, SAMEN_FLEET_COCKPIT_URL

# router.ex — cockpit side, on whichever product hosts the cockpit
samen_operator_routes(MyAppWeb, fleet_cockpit: true)
samen_fleet_ingest_routes(namespace: MyApp.Fleet)
```

**T82 correction (fix round, LOW):** the macros take a required `otp_app:`/
`namespace:` option (the `mode/1`/`Registry` namespace they operate over is
not otherwise derivable) — the bare zero-arg `samen_fleet_routes()` shown in
an earlier draft of this section does not exist and would raise. Still ≈0-LOC
(one line, one required keyword), and the generator supplies the argument
automatically (`otp_app: :<%= otp_app %>`) — a generated app's author never
types it. Two lines to report, two more to host a cockpit, zero to be honest
with one product. The generator (ADR-022) emits `samen_fleet_routes(otp_app:
...)` by default, which is what makes the J5 zero-config probe pass without
the generated app knowing what a fleet is.

**No per-vertical projection MFA is required.** The `{Driftwood.OperatorAggregate,
:load, []}` pattern (the existing `AggregateLive` seam) remains available as an
**optional** enrichment for vertical-specific tiles, but `Samen.Fleet.Report.build/1`
derives the whole tier-1 report from substrate resources every product already has. A
generated app with zero authored aggregate code produces a complete, truthful report.

### 9.3 · The ≥2-vertical proof plan

**A dependency that shapes this plan:** backlog **T157** records that pawchart does not
yet mount the operator plane (only driftwood and demo do). The proof plan therefore must
not — and does not — require pawchart to host a cockpit. `samen_fleet_routes/1` is a
plain controller pipeline with no operator-plane dependency, so **pawchart can report
without mounting the operator plane at all.** The proof splits reporting from viewing.

| tier | what it proves | where |
|---|---|---|
| **(a) two real verticals emit** | `driftwood` **and** `pawchart` each mount `samen_fleet_routes()`, build a report from their own substrate, and `GET /fleet/health` returns a **schema-valid, correctly-signed** `FleetReport` for each. `mix samen.verify.fleet_wire` green in **both** hosts' `ci.sh`. This is the genuine two-vertical proof: two different domain shapes (freight, veterinary) through one wire. | `driftwood/ci.sh`, `pawchart/ci.sh` (T82) |
| **(b) cockpit renders ≥2 apps** | in `samen_web`, one `:embedded` app plus two ingested reports (driftwood-shaped and pawchart-shaped **fixtures captured from tier (a)**, so the fixtures cannot drift from reality): MRR roll-up **sums exactly**, queue depth and attention list match the seeded fixtures, `n of m reporting` is correct with one report forced stale. | `samen_web/test/.../fleet_cockpit_test.exs` (T84) |
| **(c) flag fan-out reaches ≥2 engines** | a cockpit publish is applied by **two** independent `Samen.FeatureFlags` engine instances; `kill: true` turns both OFF within one broadcast hop; a local kill is **not** overridden by a fleet enable (§7.3). | `samen_web` + a driftwood/pawchart integration assertion (T84) |
| **(d) J5 zero-config** | the `gen_app` probe: a freshly generated app boots with **no fleet config**, self-registers in `:embedded` mode, and `/operator/fleet` renders exactly one truthful tile with no fabricated peers. | `samen_core/priv/gen_*_probe.exs` wiring (T82) — **and the probe must restore `priv/abbrev_registry.json` SHA-256 byte-exact on every exit path including SIGINT/SIGTERM**, per `CLAUDE.md` / T107; the existing `ci.sh` `run_gen_probe` wrapper covers this and must not be bypassed. |
| **(e) privacy verifiers** | `mix samen.verify.no_pii_columns` and `mix samen.verify.aggregate_privacy` green over the `flt_*` registry and the cockpit projections (the J2 verify clause, literally). | root `ci.sh` (T82/T84) |

Tier (a) is the load-bearing one for "≥2 verticals": it exercises two real domain models
against the closed schema. Tier (b) deliberately avoids booting two endpoints inside one
test run — the fixtures are captured from tier (a), so the integration is proven where it
is cheap and the render is proven where it is fast.

---

## 10 · ADR-037 verdicts consumed

**§5.13 ash_admin — REJECT.** *"The first-party operator plane remains the only operator
surface."* Honored without qualification:

- The cockpit is `Samen.Web.Operator.Fleet*` — first-party LiveViews in the existing
  operator plane, mounted behind the T146 `on_mount` gate.
- The C1 objection (ash_admin "runs read actions and renders returned field values
  directly", with no plane concept) is answered structurally rather than by policy: the
  cockpit's inputs are `FleetReport` payloads whose schema has no PII-capable field
  (§5.2), and its resources are `Samen.Aggregate.Resource`s under the C7 compile
  verifier. There is no generic renderer and no arbitrary action invocation anywhere in
  the fleet surface.
- The C2 objection (MaskingCase 3-proofs are unwritable against a generic renderer) does
  not arise: the cockpit renders **no** 🔒 field, so it adds **no** entry to the masking
  watch-list. §6.4(c)'s structural grep probe is the proof that this stays true.

**§5.9 ash_oban — ADOPT** is consumed for the three standing sweeps this ADR introduces
(key retirement, enrollment-token prune, `flt_report` history prune) — same pattern as
the ADR-035 §4.2 token sweep. **§5.14 ash_rate_limiter — ADOPT (narrow: auth + webhook
ingress)**: `POST /fleet/enroll` and `POST /fleet/heartbeat` are webhook-class ingress and
are covered by that adoption, with keys that are non-PII by construction (`app_id`,
`key_id`). No other §5.x verdict is engaged, and this ADR adds no dependency.

---

## 11 · Keyless / fail-honest posture

Per the standing ruling and ADR-014/024/026, every fleet path is keyless by default and
fail-honest when unconfigured:

| condition | result |
|---|---|
| no fleet config at all | `:embedded` mode — fully functional, one honest product, **zero** credentials |
| `mode: :manual \| :heartbeat` with no credential configured | `Samen.Fleet.Credential.load/1` ⇒ `{:error, :not_configured}`; the app's `/fleet/health` returns `503` empty; the cockpit renders the named not-configured state |
| cockpit configured for pull, app unreachable | `{:error, :unreachable}`; the tile reads `unreachable · last seen …`; the app is excluded from roll-ups |
| report received but schema-invalid | `422`, **not stored**, `attention` entry raised. A malformed report never becomes a rendered number |
| any credential missing, revoked, retired, or unparseable | `401`/`403`, empty body, `aud_event` row |

**There is no default secret, no baked-in dev secret, and no fallback that could ship.**
Dev and test convenience is `:embedded` mode, which requires no credential at all — so
unlike `dev_operator_role/2` there is not even a named dev credential to arm incorrectly.
A stub that returned `{:ok, report}` for work it did not do is the exact lie the gate
sabotages test for; §4.7 and the table above are its refutation.

---

## 12 · Deferred sub-decisions (explicit, with owners)

| deferred | to | revisit trigger |
|---|---|---|
| exact `flt_*` abbrev strings | **T82**, via `mix samen.abbrev.reserve` only (ADR-023) | — |
| `Samen.Kms` key-derivation spelling for mode-A secret wrapping (constraint fixed: never a plaintext column, never logged) | T82 | — |
| heartbeat/pull interval + `stale_after_s` defaults beyond the stated 60 s / 300 s | T82 | operational tuning |
| app-initiated directive **pull** (`GET /fleet/directives/:app_id` + a read-capable app-held credential) | **not built** (§7.5) — **operator ruling 2026-08-06 CONFIRMED honest degradation exactly as specced; this is a settled decision, no longer an open question** | a real on-prem/NAT deployment that requires fleet flags. Requires re-stating §4.6 for a second credential kind |
| **the `{:accounts, set}` assignment model** — RESOLVED by operator ruling R-A: a dedicated per-product resource (operator principal × `app_id` → account set) + a minimal `:operator_admin` surface; `scope_of/2` is its only reader; **absent row ⇒ `:none`** (§16.5 #1). The draft's "CRM owner field" default was a **mis-citation of a nonexistent primitive** and is withdrawn | **T84 builds it** | — (contract fixed; only the implementation is open) |
| **`fleet_subject_key(app_id)` custody, stability, and rotation — now an AUTHORIZATION dependency** (§16.2, carried-LOW 2) | **T82** states custody + the rotation mechanism; T84 consumes it | — (must be closed, not deferred: rulings R-A/R-B make the key load-bearing for access control, not just unlinkability) |
| **`/operator/accounts` account-level scoping retrofit** — today it shows every org's name to any operator role, with no scoping; Amendment 1 makes the cockpit *stricter* than it (§16.4) | **T159** (Phase 7) — **related, NOT owned by this ADR** | — |
| **reveal-grant ceremony for name resolution** instead of standing role scoping (§16.5 #2) | **not adopted** — standing authorization, per the ruling's framing | the operator prefers the stricter reading; it is a swap of one clause in `may_resolve?`, not a redesign |
| **cross-origin name resolution** for separately-deployed fleets — blocked on the §6.5 SSO seam; until then the cockpit **cannot make the resolution call** and renders every tier-2 row masked (§16.2). **Scope-gated drill-ins are NOT affected** — the product-local gate answers from the product's own data in every topology (§16.4a) | with §6.5 | a real multi-host fleet needs names |
| fleet SSO / a shared operator session across separately-deployed products | **not built** (§6.5) | a real multi-host fleet where per-product IdP login is measurably insufficient |
| **automated (unattended) mode-B key rotation** — design fixed in §4.5: proof-of-possession of the OLD key over a cockpit challenge nonce **plus** operator confirmation of a `pending` successor before activation | **not built** (§4.5); rotation is operator-issued re-enrollment | enough apps that manual rotation stops being practical. Do **not** re-introduce a bare app-initiated `POST /fleet/rotate` — that is the self-takeover primitive this ADR removed |
| **eliminating the §5.2b opaque-id residue** — delete `git_sha` from the wire; make `fleet_handle` cockpit-assigned on first sight instead of producer-derived | T84 or later | a deployment where a compromised-producer covert channel is in the threat model. Both are cheap; neither is done by default |
| cockpit-side alerting/paging off the `attention` list | T84 or later | an operator asks to be woken up |
| historical fleet time-series beyond the 30-day `flt_report` window | later | a retention requirement appears |
| vertical-specific cockpit tiles via the optional `{Mod, :load, []}` projection MFA | T84 (optional) | a vertical needs a tile the substrate cannot derive |
| renaming `scripts/fleet-status.sh` to avoid the §3.1 "fleet" name collision | later | the overlap actually confuses someone; runbooks reference the current name |

---

## 13 · Consequences

**Positive.** The portfolio question — *"across everything I run, what needs me today?"*
— gets an answer that is token-blind by construction rather than by policy, so the
easiest place in the system to build an accidental PII aggregator is the one place a PII
value has no field to occupy. Per-product role scoping costs a resolver and no new
primitive, because T146's seam already carried the right shape. T156 lands as tier 2 of
one cockpit instead of a second, divergent aggregate stack. Verticals adopt at two lines,
and a generated app is honest about being alone on its very first boot.

**Negative / accepted, named plainly.**

- **An unreachable app gets observability but not fleet flags** (§7.5). This is a real
  capability gap for on-prem/NAT deployments, accepted deliberately to keep the
  heartbeat credential's capability set at exactly one write verb with zero read. The
  revisit trigger is recorded.
- **Mode A's shared secret is symmetric and held on both sides** (§4.2), and its blast
  radius is materially larger than "read a PII-free report": a leak lets an attacker
  **kill any flag in that product** (availability) and **publish up to 2120 characters of
  attacker-authored text into that product's tenant-visible announcement banner** — a
  branded phishing surface (§4.6). Named, audited, and mitigated (forged-directive
  detection + provenance line), not eliminated. Mode B is strictly better and is what the
  generator emits.
- **A stolen heartbeat credential can submit a false report for its own app** (§4.6).
  Mitigated by making reports advisory, computing staleness cockpit-side, and giving
  reports no power over money, access, or behaviour — but not eliminated, because a
  push-based transport cannot eliminate it.
- **The wire's opaque-id fields remain a low-bandwidth covert channel for a fully
  compromised producer** (§5.2b): ≤ `20 + 16 × 3 × 256 = 12,308` bytes per report
  (three cohort lists, corrected by T82 — see §5.2b), in fields that are
  never rendered as text or searched. This is the same already-accepted exposure the
  shipped wide-event sink carries on `trace_id`/`actor_id`; it is not eliminable by any
  schema for an opaque-id field, and §12 records the two cheap ways to shrink it further.
  Named rather than papered over, because §5.2 puts the compromised producer in scope.
- **Mode-B key rotation requires an operator action** (§4.5) — unattended rotation was
  removed because the obvious implementation is a credential self-takeover primitive.
- **`fleet_handle` costs a resolution hop, and reaching a tenant's DATA lands in tier 3.**
  Following a deep link opens a T150 impersonation session with a reason, in that tenant's
  ledger (§5.3). This is more friction than a dashboard link normally has, and it is the
  correct amount: the cockpit's convenience must not become an unaudited path into one
  tenant's data. *(Amended by §16: the tenant's **name** now resolves inline, per viewer,
  without a drill-in — so the friction applies to data, not to identity. The name
  resolution adds its own cost: a per-render seam call per product and a masking 3-proof
  obligation, and it renders nothing at all in the separately-deployed posture until the
  §6.5 SSO seam exists.)*
- **The fleet report is a new, wide, versioned contract.** Adding a metric means a
  schema version bump and a compatibility window; `mix samen.verify.fleet_wire` makes a
  careless addition a build failure, which is the point, but it is friction.
- **Separately-deployed fleets need per-product login** until the §6.5 seam is filled.

**Neutral.** `Samen.FeatureFlags`, `Samen.Aggregate`, `Samen.Impersonation`,
`Samen.Reveal`, `Samen.Web.Operator.Authz`, and the whole masking watch-list are consumed
**unchanged** — this ADR adds a layer above them and modifies none of them. No new
dependency is introduced. The abbrev registry is untouched by this ADR; T82 allocates
through the sanctioned allocator.

---

## 14 · Red paths / verification (the WS-J adversarial floor)

Every red path pairs denial with a positive control (anti-tautology, `CLAUDE.md`).

- **RP-J-1 (bad-secret handshake + no timing oracle, J1).** A mode-A pull signed with a
  wrong secret ⇒ `401` + `aud_event`; the same request correctly signed ⇒ `200` + a
  schema-valid report. Plus the §4.4 oracle assertion: an **unknown `kid`** and a **known
  `kid` with a bad signature** are indistinguishable in both response and timing
  distribution (the ADR-035 §4.4 dummy-verify shape). **Sabotage twins:** (a) make the
  signature comparison non-constant-time / short-circuit true; (b) remove the unknown-kid
  dummy verification so the unknown path returns early — each must flip its named test.
- **RP-J-2 (zero-read heartbeat credential, J1 — the load-bearing one).** The §4.6
  capability matrix, every row with its control. **Sabotage twin:** change
  `POST /fleet/heartbeat` from `204` empty to `200` + a fleet list, and the named
  zero-read test must fail.
- **RP-J-3 (forged / revoked / replayed / retired credential, J1).** Each ⇒ `401`/`409`
  with an empty body; valid-and-current ⇒ `204`. **Sabotage twin:** drop the
  `revoked_at IS NULL` clause from credential lookup and the revocation test must fail.
- **RP-J-4 (the wire cannot carry PII, J2 — INV-2).** `mix samen.verify.fleet_wire`
  fails the build when a field of any non-bounded class is added to
  `Samen.Fleet.Report.Schema` — asserted **per forbidden type atom** against
  `Samen.WideEvent.Schema.known_forbidden_types/0` (`:string`, `:binary`, `:text`,
  `:atom`, `:map`, `:any`, `:term`, `:list`) in the verifier's own fixture, plus a
  positive control that a `:number`/`:enum`/`:opaque_id`/`:token` field compiles green.
  Second assertion: the fleet schema's permitted class set is **equal to or a subset of**
  `Samen.WideEvent.Schema.bounded_types/0` — a direct test that ADR-044 never widens the
  discipline it inherits, which would have caught the first draft's `:semver`/`:slug`.
  Third: a report containing an out-of-schema key, an out-of-`range:` number, a malformed
  `form:` value, or an over-`max_len:` list is rejected `422` and **not stored**. Fourth:
  a vault-seeded canary planted in every product surface appears in **no** `flt_report`
  payload, **no** cockpit render, and **no** cockpit CSV/API response.
  `no_pii_columns` + `aggregate_privacy` green over `flt_*` and the cockpit projections.
  **Sabotage twin:** add a `:string` field to the schema — the build must fail.
- **RP-J-4b (route surface is closed, J1/J2).** `verify.fleet_wire` cross-checks the
  router against the §4.4a table: a fleet route present in the router but absent from the
  table (or vice versa) fails the build. Prevents an undeclared read endpoint being added
  beside the credential-authenticated ones.
- **RP-J-5 (role isolation, J3).** A role in product A confers **zero** capability in
  product B — asserted per capability at the resolver **and** end-to-end at the surface,
  with a same-product control on every row. Cockpit access without `roles[:fleet]`
  renders nothing. Publishing a directive as `:operator_readonly`/`:operator_support` ⇒
  denied; `:operator_admin` ⇒ allowed.
- **RP-J-6 (impersonation unchanged, J3).** Existing per-product impersonation masking
  suites green in the same run; fleet actors refused by `Samen.Impersonation.open/3` and
  `Samen.Reveal.reveal/5` with `%OperatorPlane.Actor{}` controls; the §6.4(c) structural
  grep probe finds no fleet reference to impersonation / reveal / `PiiResolution`.
- **RP-J-7 (k-anon survives the wire, J2/T156).** A cohort below the k / l floor is
  `%Suppressed{}` **in the emitted payload** (asserted on the captured wire bytes, not
  just the render), renders `⊘`, and cannot be recovered by differencing tier-1 totals
  against tier-2 rows.
- **RP-J-8 (fan-out + kill, J4).** A cockpit publish is applied by two independent flag
  engines; `kill: true` turns both OFF within one broadcast hop; an unreachable app
  renders `unreachable` and **never** `applied`.
- **RP-J-8b (fleet is a one-way OFF authority, J4 — §7.3).** For **each** local off-state
  — `enabled: false` (kill), a matching explicit deny, and **`rollout_pct: 0`** — a fleet
  directive with `rollout_pct: 100` leaves the flag **OFF** with `reason: :local_off`.
  Positive control per row: remove the local off-state and the same directive turns it
  ON. The `rollout_pct: 0` row is the one the first draft's ranked ladder got wrong
  (`feature_flags.ex:174-182`), so it is asserted explicitly rather than by implication.
  **Sabotage twin:** reorder the layer so fleet rollout precedes the `local_off?`
  predicate — the `rollout_pct: 0` row must fail.
- **RP-J-9 (1-product honesty, J5).** The gen_app probe: zero config, one tile, no
  fabricated peers, no seeded registry rows, `1 product` chrome. A stale report is
  labelled and **excluded from the roll-up** (assert the total changes when the report
  goes stale). An unknown metric renders `—`, **never `0`** — asserted as a refutable
  distinction.
- **RP-J-9b (single-product chrome is DERIVED, not branched, J5 — §8.3).** Render the same
  cockpit component with **1** row and with **3** rows from the same call site with **no
  mode flag**, and assert the DOM: n=1 ⇒ `1 product`, no rank column, no delta column, no
  peer shelf; n=3 ⇒ `3 products` and all three affordances. Accompanying grep assertion:
  the cockpit module contains no comparison against a row-count literal (`== 1`, `<= 1`,
  `length(...) == 1`) outside the pluralization helper — which is what makes "derived, not
  branched" checkable rather than aspirational.
- **RP-J-10 (fail-honest unconfigured, J1/J5).** `mode: :manual` with no credential ⇒
  `{:error, :not_configured}` and a named not-configured render; the app's
  `/fleet/health` ⇒ `503` empty. **Sabotage twin:** return `{:ok, %Report{}}` from the
  unconfigured path and the named test must fail (the ADR-014 class, per
  `samen_core/test/files_storage_test.exs`).
- **RP-J-11 (the tier-2 deep link does NOT bypass T150, J2/J3 — §5.3).** Follow a cockpit
  deep link as an operator holding a role in that product but with **no** impersonation
  session ⇒ the drill-in renders the open-session-with-reason form and **zero tenant
  rows** (asserted on the DOM, refuting any row leak). Positive control: open a session
  with a reason ⇒ the same link renders masked rows, and an `imp_impersonation_session`
  row + its `aud_event` exist. Second red path: the same link with **no role** in that
  product ⇒ redirect to `/login`, nothing rendered, and the handle is **not resolved**
  (asserted by instrumenting the resolver — resolution must not precede the T146 gate).
  **Sabotage twin:** remove `Samen.Web.Operator.Impersonation.gate/2` from the resolve
  target and the zero-rows assertion must fail.
- **RP-J-12 (cockpit routes are gated, J3 — §6.3).** The router-enumerating test: every
  route in the cockpit `live_session` carries the `:require_operator` `on_mount`; a
  tenant user gets a redirect and zero cockpit markup on each. **Sabotage twin:** delete
  the `on_mount` from the macro's cockpit branch — the enumerating test must fail. (This
  is the T146-rounds-2/3 regression class, made refutable rather than asserted.)
- **RP-J-13 (rate-limit oracles + starvation, J1 — §4.4a).** Over-limit responses are
  byte-identical for known and unknown `kid`; a signature-invalid flood against app X's
  `kid` does **not** prevent app X's valid heartbeats from succeeding, and raises an
  `:heartbeat_rejected` attention entry (so the cockpit shows "flooded", never a silent
  "stale"). Positive control: no flood ⇒ no attention entry, heartbeats normal.
- **RP-J-14 (name resolution is authorized per row per viewer, Amendment 1 —
  §16.2/§16.3/§16.4a).** The **scope-mask** 3-proof, run with the new
  `Samen.ScopeMaskCase` helpers (**not** `MaskingCase`'s plane helpers, which do not apply
  — §16.3): **green** — a viewer whose `scope_of/2` covers the handle sees the display
  name inline (`assert_scope_resolved!/2`, so the proof cannot pass on an empty render);
  **red** — a viewer with `roles[app_id]` but an `{:accounts, …}` scope *excluding* that
  handle, and a viewer with `:none`, both get a masked row carrying **no name, no
  `org_id`, no deep link, and no handle in any DOM attribute**, in DOM **and** in every
  cockpit CSV/API response (`assert_scope_masked!/3` — the no-handle clause is the §16.4a
  DOM ruling, asserted, not left to the renderer); **sabotage twin** — flip `scope_of/2`
  permissive and the red assertion must fail (`assert_leak_detected!/2`). Plus the
  mixed-render case: **one** table with named rows and masked rows for the same viewer
  (the salesperson), asserted in a single render. Plus fail-closed: no seam, an erroring
  seam, or an unknown return ⇒ every row masked (positive control: a wired seam resolves).
- **RP-J-16 (account scope gates tier-3 entry, operator ruling R-B — §16.4a).** An
  operator with a valid role in product X **and** an active intent to drill into an
  account **outside** their `{:accounts, …}` scope is **denied at the product's drill-in
  door**, and is denied **before** the open-session-with-reason form is offered (so the
  prompt never becomes a scope oracle). **Positive controls, both required:** the same
  operator drilling into an **in-scope** account gets the normal T150 reason form and,
  after opening a session, the masked drill-in; and an `:all`-scope operator is unaffected
  on **every** per-tenant drill-in route — **enumerated from `Phoenix.Router.routes/1`,
  never hand-listed** (the RP-J-12 pattern), so a fourth drill-in landing later is covered
  the day it is added rather than silently escaping the control. Third assertion: scope is
  **not** a substitute for T150 — an in-scope operator with no session still sees the
  reason form, never rows. Fourth: the gate is **fleet-independent** — the same
  enumerated assertions pass with no fleet configured at all (§16.4a), which is what
  refutes the "separately-deployed fleet locks everyone out" composition error.
  **Sabotage twin:** drop the scope conjunct from `may_drill_in?` and the scoped-out
  denial test must fail.
- **RP-J-15 (resolved names never come to rest, Amendment 1 — §16.1).** After a render in
  which names were resolved: **no** resolved name appears in `flt_*` rows, in
  `flt_report.payload`, in any cockpit cache/ETS table, in any log line or telemetry
  event, or in any cockpit export — asserted by scanning storage + captured logs for the
  seeded tenant names, in the shape of the ADR-043 §3.2b/EG6 captured-log assertions. The
  zero-tenant-data-at-rest property is thereby a test, not a claim. **Sabotage twin:**
  memoize the resolver's output into the cockpit's assigns-backed cache and the storage
  scan must fail.

---

## 15 · References

- spec §WS-J J1–J5 — `_orch/plan/traceability.yaml` (J1–J5 verify clauses);
  `_orch/plan/roadmap.md` Phase 6. INV-1..INV-6.
- **M10 ruling** (BOTH registration modes + a secured heartbeat credential story) —
  `_orch/plan/spec-questions.md` §M10.
- **Backlog T156** (cross-tenant platform-health dashboards — merged into T84 by §5.3 +
  §5.4) and **T157** (pawchart operator-plane adoption — the §9.3 dependency note) —
  `_orch/plan/backlog.yaml`.
- ADR-037 §5.13 (ash_admin REJECT — consumed in §10), §5.9 (ash_oban ADOPT), §5.14
  (ash_rate_limiter ADOPT, narrow).
- ADR-010 §7.2 (the operator/tenant identity line) · **T146** —
  `samen_web/lib/samen/web/operator/authz.ex`, `samen_web/lib/samen/web/auth_gate.ex`,
  `samen_core/lib/samen/operator_plane/actor.ex`.
- **T150** — `samen_core/lib/samen/impersonation.ex`,
  `samen_web/lib/samen/web/operator/impersonation.ex` (the "what is NOT gated" partition
  §5.4 extends).
- ADR-020 + `samen_core/lib/samen/feature_flags.ex` (precedence, fail-SAFE cache,
  `NonPiiTargeting`, `TargetRule`).
- T4.2/T4.5 — `samen_core/lib/samen/aggregate.ex`,
  `samen_core/lib/samen/aggregate/{resource,privacy,cohort_spec,suppressed,query_budget}.ex`,
  `samen_core/lib/samen/verifiers/no_pii_columns.ex`,
  `samen_core/lib/mix/tasks/samen.verify.aggregate_privacy.ex`.
- ADR-035 §4.2 (the emitted-secret discipline reused verbatim for the enrollment token);
  ADR-001 (KMS hierarchy); ADR-014/024/026 (fail-honest); ADR-022 (generator emits a
  running product); ADR-023 (abbrev allocator); ADR-031 (host-owned authn).
- Mirrored constructions: `Samen.WideEvent.Schema` (the closed-schema build check §5.1
  copies), `Samen.Web.MetricsController` (the self-gating, fail-honest controller shape
  §9.1 copies), `Samen.Web.Operator.AggregateLive` + `Driftwood.OperatorAggregate` (the
  `⊘` chrome and the optional projection-MFA seam), `Samen.Policy.AggregateActorOnly`
  (the default-deny policy `FleetIngressOnly` copies), `scripts/fleet-status.sh` (the
  existing per-product secret-drift check — a sibling operational tool, not superseded).
- Downstream: `_orch/tasks/T82/handoff.md`, `_orch/tasks/T83/handoff.md`,
  `_orch/tasks/T84/handoff.md`.

---

## 16 · Amendment 1 (operator rulings, 2026-08-06) — tenant identity is usable data, resolved per-viewer by role-scoped unmasking

- **Status:** Accepted amendment. **Binds:** T84 (the resolution layer + its 3-proof),
  T83 (the scoping seam rides the J3 args carrier). **Amends:** §5.3, §5.4. **Leaves
  untouched:** §5.1/§5.2/§5.2b (the report-wire INV-2 proof is *not* reopened), §6.4
  (impersonation), tier 3.
- **Ruling 1 (verbatim):** *"I think the tenant name is useable data, but we should
  probably be visible via a data unmasking per roles/rights/responsibilities. Maybe a
  sales person can only see their accounts for example."*
- **Ruling 2:** the §7.5 honest-degradation posture for unreachable apps is **CONFIRMED
  exactly as specced** — no design change; §12's row is now a settled decision rather than
  an open question.

### 16.1 · What changes, and what deliberately does not

The original §5.3 answered "which tenant is bouncing?" with *indirection only*: an opaque
handle plus a deep link, and the operator never saw a name in the cockpit. The ruling
rejects that as too strict — a tenant's **name** is data the SaaS legitimately owns (the
ADR-010 §7.2 identity line: tenant-org and tenant-admin identity is operator-visible; it
is the tenant's **end-customer** PII that is masked), and `/operator/accounts` already
renders org names in the clear today. The ruling also rejects rendering names to everyone:
visibility is **role-scoped unmasking**, down to account level.

So the cockpit now shows names — **masked by default, unmasked per viewer**. Three things
that do **not** change, stated so the amendment cannot be read as a loosening:

1. **The wire stays pseudonymous.** `FleetReport` still carries `fleet_handle` only
   (`:token {:hex,32}`). No `org_id`, no name, no new field. §5.1/§5.2/§5.2b stand
   verbatim and the closed INV-2 proof for the report wire is not reopened.
2. **Nothing is stored.** Resolution is per-viewer, per-render, in memory. No resolved
   name is written to `flt_*`, cached in cockpit storage, logged, or included in any
   cockpit CSV/API export. **The zero-tenant-data-at-rest property survives intact** — a
   dump of the cockpit database still contains no tenant identity, only handles.
3. **Tier 3 is untouched.** Seeing a name is not seeing a tenant's data.

**Net effect on strictness:** relative to the shipped operator plane this is a
*tightening*, not a loosening. `/operator/accounts` today shows every org's name to any
operator role; the fleet's tier-2 rows show a name only to a viewer whose scope covers
that account.

### 16.2 · The resolution-scoping contract (binds T83/T84)

**The question this answers: "may THIS operator resolve THIS handle?" — and the owning
product, never the cockpit, decides.**

```
may_resolve?(principal, app_id, handle) :=
     roles[app_id] != nil                      # J3 args-carrier scoping — necessary, not sufficient
 AND handle ∈ scope_of(principal, app_id)      # the product's resolution seam

scope_of/2  ->  :all | {:accounts, MapSet.t(org_id)} | :none
```

- **The seam mirrors `:operator_authority` exactly** — an `{mod, fun, args}` MFA whose
  **args list carries the product scope**, the same J3 carrier §6.2 established:
  `config :driftwood, :fleet_resolution, {Fleet.Auth, :resolution_scope, [:driftwood]}`,
  called with the principal id appended. **Fails closed**: no seam, an error, an unknown
  return, or `nil` ⇒ `:none` ⇒ every handle renders masked. A host that wires nothing gets
  no names, never all names.
- **`fleet_subject_key(app_id)` is now an AUTHORIZATION dependency, not merely a privacy
  one — and must be treated as such by T82.** Testing `handle ∈ scope_of(…)` for
  COCKPIT-SIDE NAME RESOLUTION (§16.2's own subject) requires the product to recompute
  `HMAC(fleet_subject_key(app_id), org_id)` to relate a wire handle to a real org. **T82
  correction (this bullet originally continued "and under ruling R-B that same relation
  gates tier-3 drill-in entry … it decides who may see which names and enter which
  drill-ins" — both drill-in clauses are FALSE and are struck here.)** §16.4a (below,
  written in a later fix round) settles this precisely: the drill-in gate tests
  `org_id ∈ scope_of(…)` **directly**, never via a handle, and so has **no dependency on
  this key at all** — it is keyless. The key therefore decides only **who may see which
  NAMES** in the cockpit (tier-2 resolution); it decides nothing about who may **enter**
  a drill-in (tier-3 entry is gated by `scope_of/2` read straight off the `org_id`, plus
  T146 plus T150 — §16.4a). So the key no longer only protects unlinkability (§5.3); it
  decides who may see which names. Two consequences bind T82: **custody** — the key is
  per-product, product-held, KMS-wrapped, never in a plaintext column, never logged, and
  never sent to the cockpit (the cockpit must remain unable to relate handles to orgs,
  §16.1); and **stability** — the key must be stable for the lifetime of every stored
  report, because **rotating it silently re-keys every handle**: handles already stored in
  `flt_report` were computed under the old key, recomputation under the new key matches
  nothing, and **every tier-2 row in the cockpit masks** until each app re-reports (with
  the 30-day stored history permanently unresolvable).

  **Blast radius, bounded precisely — rotation does NOT break access control.** Because
  the drill-in gate tests `org_id ∈ set` directly and never touches the key (§16.4a),
  rotation affects **only** cockpit-side handle resolution and the relabeling of stored
  reports. **Product-local drill-in gating is unaffected**, so a rotation degrades the
  cockpit's *display* without ever locking an operator out of a product surface they are
  entitled to. That is a materially smaller failure than the first draft implied. It is
  still fail-**closed** (rows mask, nothing leaks), but it presents as a cockpit-wide
  naming outage rather than as a key event — so rotation must be an explicit,
  operator-visible operation that re-labels or invalidates affected history, not a silent
  config change. The mechanism (most likely an additive `:number` `handle_key_version`,
  which stays inside §5.1's class discipline and so does **not** reopen the INV-2 proof) is
  T82's to specify.
- **`:all`** is the operator-admin/support posture (parity with `/operator/accounts`
  today). **`{:accounts, set}`** is the ruling's salesperson: a book-of-business subset;
  handles outside the set stay masked in the same render, row by row. **`:none`** is the
  fleet-only viewer who legitimately sees cross-product health but no tenant identity.
- **Resolution is operator-authenticated, not credential-authenticated.** The viewer's own
  operator identity is what the product evaluates. **No fleet credential gains any
  capability**, so §4.4a's route table and §4.6's mode-A blast radius are unchanged — a
  stolen probe secret still cannot resolve a single name, because it cannot produce an
  authenticated operator principal. This is the reason the seam is shaped this way.
- **Two consumers, one seam, DIFFERENT inputs — and the distinction is load-bearing.**
  `scope_of/2` is consulted from two places, and they are not symmetric:

  | consumer | has | membership test | needs the HMAC key? |
  |---|---|---|---|
  | **cockpit-side name resolution** (§16.2) | a wire **handle** | relate handle → org, then `org_id ∈ set` | **yes** |
  | **product-local drill-in gate** (§16.4a) | the **`org_id`** from its own URL | `org_id ∈ set` directly | **no** |

  The drill-in already holds the `org_id` and `scope_of/2` already returns `org_id`s, so
  the gate path is a plain set membership — **no handle, no HMAC, no round-trip.**

- **Posture split — the degradation is a property of the COCKPIT-SIDE RESOLUTION PATH,
  never of the seam.** *Co-resident* — the products share a BEAM and an identity store, so
  the cockpit calls `Samen.Fleet.Resolution.resolve/3` **in-VM** through the product's
  seam. This is what T84 builds and tests. *Separately deployed* — the cockpit cannot get
  the viewing principal authenticated **at the product** until the §6.5 fleet-SSO seam
  exists, so the **cross-origin resolution call** cannot be made and the cockpit renders
  every tier-2 row masked, saying *"names unavailable — resolution seam not reachable"*
  rather than showing handles as if that were the intended design.

  > **This degradation applies ONLY to cockpit-side name resolution. It does NOT reach the
  > product-local seam.** A product's own drill-in gate answers `scope_of/2` from **its own
  > assignment data, in its own VM, for a viewer already authenticated at that product** —
  > which works identically no matter how the fleet is deployed, or whether a fleet exists
  > at all. An `:all` admin who never opens the cockpit is completely unaffected; the three
  > shipped drill-ins keep working in every topology. Reading the two bullets together as
  > "separately deployed ⇒ `scope_of/2` ⇒ `:none` ⇒ every drill-in denies" is the
  > composition error this note exists to prevent: **cross-origin unavailability is not a
  > scope answer.** §12's row scopes it the same way, and §6.5's "the cockpit deep-links"
  > stays true — the link still works; only the *name shown beside it in the cockpit* is
  > unavailable.
- **Mask by omission.** The resolver returns `%{handle => name}` containing **only**
  permitted handles; denied handles are *absent from the map*, not present-with-a-mask.
  The renderer masks anything it did not receive. This is the shipped ADR-028
  mask-by-omission discipline, so a resolver bug fails toward masking.

### 16.3 · Masking discipline — the 3-proof obligation (T84)

**This is a NEW mask class, and the first draft of this amendment mis-stated it.** It
claimed resolved names "join the masking watch-list and carry the standard
`Samen.MaskingCase` three proofs", which is wrong twice over: it contradicted §6.4's
"no new `MaskingCase` consumer" claim (both sides are now corrected), and
`Samen.MaskingCase` does not actually fit this shape. Stated precisely:

| | **vault/plane mask** (the shipped discipline) | **scope mask** (NEW, this amendment) |
|---|---|---|
| axis | the actor's **plane** (tenant / operator / operator-with-grant) | the viewer's **account scope** within one product |
| data | a vault-routed 🔒 field, resolved via `Samen.Api.PiiResolution` | a plain `:string` of **SaaS-owned** data (a tenant's display name) |
| masked form | `%Samen.Masked{}` → `••••`; a `vt_*` token must never appear | the row simply carries no name, and no handle (§16.4) |
| helpers | `resolve_on_plane/4`, `assert_plane_clear!/2`, `assert_plane_masked!/2`, `assert_two_plane!/3` | **none of those apply** — they take a value resolved on a plane from a vault-routed field |

**What actually transfers from `Samen.MaskingCase`: `assert_masked_dom!/2` and
`assert_leak_detected!/2`.** Both operate on rendered HTML plus a list of plaintexts,
which is exactly the scope-mask assertion, and reusing them keeps the "assert on the DOM,
not on the assigns" discipline. Everything plane-shaped does not transfer and must not be
claimed.

**T84 builds a small sibling harness — `Samen.ScopeMaskCase` — with two new helpers**
(named here so T84 implements rather than improvises, and so nobody assumes `MaskingCase`
already covers this):

- `assert_scope_masked!(html, names, handles)` — the render contains **none** of `names`
  and **none** of `handles` (delegating to `assert_masked_dom!/2` for the name half, and
  extending it to attribute values for the handle half, §16.4);
- `assert_scope_resolved!(html, names)` — the render **does** contain exactly the expected
  names, so the green proof cannot pass vacuously on an empty render.

**The three proofs (the obligation itself is unchanged — only the harness claim is
corrected):**

- **green** — a viewer whose `scope_of/2` covers the handle sees the tenant's display name
  inline (`assert_scope_resolved!/2`);
- **red** — a viewer with `roles[app_id]` but an `{:accounts, …}` scope **excluding** that
  handle, and a viewer with `:none`, both see the masked row: **never the name, never an
  `org_id`, and never the handle** — asserted in DOM **and** in every cockpit CSV/API
  response (`assert_scope_masked!/3`);
- **sabotage twin** — flip the `scope_of/2` check to permissive and the red assertion must
  **fail** (`assert_leak_detected!/2` is the shipped way to prove a mask assertion
  refutable).

Note the ordinary case this makes explicit: **one render, mixed visibility.** A
salesperson's cockpit shows named rows for their accounts and masked rows for everyone
else's, in the same table — so the red and green proofs run against a *single* render, not
two. That is also why the helpers take lists: one call asserts the whole table.

### 16.4 · The boundary: name visible ≠ tenant data visible

Inline unmasking is a read of **identity**, not a drill-in. It answers *"who is this
row?"* and nothing else. Reaching that tenant's rows — deliverability detail, activity,
automation state, anything at `/operator/*/:org_id` — remains **tier 3** and still
requires the owning product's **T146 role gate plus a T150 impersonation session with a
reason**, landing in that tenant's ledger (§5.3, §5.4). Resolving a name does not
pre-authorize the drill-in, shorten a TTL, or substitute for a reason.

**Why an identity read does not need a T150 session:** T150 gates *peering into one
tenant's house*. An org's name is not inside the house — it is the SaaS's own record of
who its customer is, the same datum `/operator/accounts` renders and the same line ADR-010
§7.2 draws. What the amendment adds on top of that existing posture is **scoping**, which
`/operator/accounts` does not yet have (retrofit filed as **T159**, §12).

#### 16.4a · Account scope gates tier-3 entry too (operator ruling R-B)

The first draft of this amendment left scope governing **only** tier-2 name visibility, so
a partial-scope operator could be denied a customer's *name* in the cockpit and still walk
into that same customer's *drill-in* by opening a session — visibility strictly weaker
than access, which is incoherent. **Operator ruling R-B closes it:**

> **`scope_of/2` is checked at the owning product's drill-in door, in addition to — never
> instead of — the T146 role gate and the T150 impersonation session.**

The composed tier-3 predicate, all three conjuncts required:

```
may_drill_in?(principal, app_id, org_id) :=
     T146:  the product's :operator_authority seam returns an operator role
 AND SCOPE: org_id ∈ scope_of(principal, app_id)                # NEW — ruling R-B
 AND T150:  an ACTIVE impersonation session for {principal, org_id} with a reason
```

- **The gate-side test is plain `org_id` membership — no handle, no HMAC.** The drill-in
  URL already carries the `org_id` and `scope_of/2` already returns `org_id`s, so relating
  a handle here would be a gratuitous round-trip through `fleet_subject_key`. Only the
  **cockpit-side** path starts from a handle and needs the key (§16.2). Consequence worth
  stating: **the drill-in gate has no dependency on the handle key at all**, so it is
  unaffected by key rotation, by handle staleness, and by whether a fleet is deployed.
- **Enforcement point: product-side, at the drill-in mount** — the *same* `scope_of/2`
  seam the cockpit consults for names (§16.2), so there is one scope definition per
  product and no chance of the two answers diverging. Concretely it composes into
  `Samen.Web.Operator.Impersonation.gate/2`'s existing deny path: a scoped-out operator is
  denied **before** the open-session-with-reason form is offered, so the product does not
  invite a session it would refuse to honor.
- **This gate is product-local and fleet-independent.** It reads the product's own
  assignment data for a viewer already authenticated at that product. It behaves
  identically whether the fleet is co-resident, separately deployed, or absent — the
  §16.2 cross-origin degradation **does not reach it** (see the boxed note there).
- **`:all` roles are unchanged** — operator-admin/support/break-glass keep today's
  behaviour exactly; this narrows nothing that works now.
- **Ordering matters for honesty:** scope is checked *before* the session prompt, so a
  scoped-out operator sees "this account is not in your scope", not a reason form that
  leads nowhere. Opening a session must never be a way to *discover* that you lack scope.
- **Scope is not a substitute for T150.** An in-scope operator still needs a session with
  a reason, still lands in that tenant's ledger. Scope subtracts; it never adds.

**Consequent DOM ruling — masked rows carry no link and no handle.** Since a scoped-out
viewer can no longer enter the drill-in, rendering the deep link (or stashing the handle in
a `data-` attribute / `phx-value-*`) on a masked row would be a dead affordance *and* an
identifier leak — a stable per-tenant pseudonym the viewer is not entitled to, usable to
correlate rows across renders and reports. So:

> **Mask by omission extends to the DOM: a masked tier-2 row carries no name, no deep
> link, no handle in any attribute, and no handle in any CSV/API projection of that row.**
> It renders its counts and an inert "not in your scope" affordance. The handle exists
> server-side to key the row; it does not reach the client for a row the viewer cannot
> resolve.

This is the ADR-028 mask-by-omission discipline applied one layer further out, and it is
asserted as a property in **RP-J-14** (below) rather than left to the renderer's
discretion.

### 16.5 · Ambiguities in the ruling — interpretation stated, alternative named

Flagged rather than silently resolved. Each is cheap to reverse if the interpretation is
wrong; none blocks T84 from starting.

1. **Who populates `{:accounts, set}`? — RESOLVED by operator ruling R-A. The first
   draft's answer was WRONG and cited a field that does not exist.**

   **The error, owned plainly:** the draft proposed deriving the account set from "the
   existing CRM owner field on the operator-plane account record". **There is no such
   field.** `owner_id` exists in samen only on **tenant-plane** scopes — `work`,
   `calendar`, `docs`, `automation`, `views` (`samen_core/lib/samen/scopes/*/blueprint.ex`)
   — where it means *a tenant user owns this tenant record*. The CRM blueprint has **zero**
   owner concept, and no resource anywhere models *an operator owns these tenant
   accounts*. The draft invented a primitive and then built a default on it.

   This is the **same failure class round 1 caught** (`:semver`/`:slug` "mirroring"
   `WideEvent.Schema` while actually widening it): reasoning from a plausible-sounding
   memory of a primitive instead of reading it. Recorded here rather than quietly fixed,
   because the pattern is the finding — an ADR that misreads a primitive produces
   downstream tasks that build against something that isn't there.

   **Operator ruling R-A — the resolution:** scope comes from a **dedicated assignment
   model**, built in T84. Contract sketch (shape fixed here; implementation is T84's):

   - **A small per-product resource** mapping an **operator principal × `app_id` → an
     account set** — product-owned (it lives in the product's DB alongside the orgs it
     references), token-blind (operator id + org ids are bounded uuids; no names, no PII).
   - **`scope_of/2` reads it**, and is the only reader: `:all` for broad roles
     (operator-admin / support / break-glass — today's behaviour, unchanged), the row's
     account set for an assigned operator, and **`:none` when no row exists** — so a
     newly-added operator starts with no name visibility and no scoped drill-in access
     until someone assigns them. Fail-closed by absence, not by configuration.
   - **A minimal admin surface** in the product's operator plane to create/edit
     assignments, gated `:operator_admin`. Deliberately minimal: no bulk import, no
     hierarchy, no delegation — those are speculative until someone asks.
   - It is **not** a new tenant-facing concept and **not** a CRM ownership model; it
     governs operator visibility only. T84 allocates its abbrev via
     `mix samen.abbrev.reserve` (ADR-023) like any other resource.
2. **Does "unmasking per roles/rights/responsibilities" mean a standing role check, or a
   reveal-grant ceremony?** **Interpretation adopted: standing, role-scoped
   authorization** — no request→approve→time-boxed grant. Rationale: the ruling's own
   framing ("roles/rights/responsibilities", the salesperson example) describes durable
   job-function authority, and org display names are SaaS-owned data (ADR-010 §7.2), not
   subject PII in the vault. **Alternative not taken:** routing resolution through
   `Samen.Reveal.Grants`, which would make every name view a two-party, audited,
   expiring ceremony — correct for vaulted subject PII, disproportionate for a customer's
   company name. If the operator wants the stricter reading, it is a swap of the
   `may_resolve?` predicate's second clause, not a redesign.
3. **Does the ruling extend to tier 1?** **No — nothing to extend.** Tier-1 aggregates
   carry no tenant axis (§5.1), so there is no identity to resolve there. Recorded only so
   the amendment's scope is unambiguous.
4. **Audit posture for resolution — CONFIRMED (standing role right, token-only audit).**
   Each resolution request writes a token-only audit event recording **the principal, the
   `app_id`, and the resolved handle SET** — the actual handles, not merely a count. The
   count alone would show *that* someone enumerated but not *whose* rows they unmasked,
   which is the question an after-the-fact review actually asks. Handles are bounded
   `:token {:hex,32}` pseudonyms, so recording the set stays token-only; **names are never
   recorded.**

   **Where it lands: the OWNING PRODUCT's audit chain (`aud_event`), never `flt_*`.** This
   is load-bearing, not incidental — writing handles or names into cockpit storage would
   violate RP-J-15's zero-tenant-data-at-rest property directly. The product already holds
   the handle↔org mapping and the hash-chained audit tier (ADR-002), so the event belongs
   there and nowhere else. Not made *tenant*-visible: that would be a T150-class ledger
   entry, which §16.4 argues an identity read does not warrant.

### 16.6 · Consequent changes elsewhere in this ADR

- **§5.3** — tier-2 rows render a **masked-by-default, per-viewer-resolvable** display
  name; the handle remains the wire key, and reaches the DOM **only** on rows the viewer
  can resolve (§16.4a).
- **§5.4** — the tier-2 row's gate gains the resolution clause; **tier 3 gains the scope
  conjunct** (ruling R-B, §16.4a); tier 1 unchanged.
- **§6.4** — its "no new `MaskingCase` consumer" clause is **corrected**: the fleet adds no
  *vault/plane* mask and adds exactly one *scope* mask (§16.3).
- **§12** — both original operator questions struck (ruling 1 = this third path; ruling 2 =
  honest degradation confirmed); rows added for the R-A assignment model and the T159
  `/operator/accounts` scoping retrofit (related, not owned here).
- **§14** — new **RP-J-14** (scope-mask 3-proof + no-handle-in-DOM), **RP-J-15** (names
  never at rest), **RP-J-16** (scoped-out drill-in denial, ruling R-B); **RP-J-9b**
  promoted from inline-only into the enumeration.
- **Not changed:** §4.4a route table, §4.6 blast radii, §5.1/§5.2/§5.2b, §7.x, §8.x.
