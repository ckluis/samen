# ADR-050 — The public status page on the fleet substrate: a token-blind projection, opt-in per app, rate-limited, with no second notion of "up"

- **Status:** **ACCEPTED (2026-09-20)** — implemented in the same change that authors this ADR.
  Amends nothing. ADR-044's registry, probe modes, report wire and dead-man staleness are
  consumed **unchanged**; ADR-038 §6.1's single rate-limit seam is reused, not forked.
- **Date:** 2026-09-20
- **Build status:** **BUILT (first increment).** `Samen.Fleet.PublicStatus` (samen_core),
  `Samen.Web.Fleet.PublicStatus` + `Samen.Web.FleetStatusController` +
  `Samen.Web.Router.samen_fleet_status_route/1` (samen_web), one `flt_app` column
  (`publish_status`), one admin-gated verb (`Samen.Fleet.Registry.set_publish_status/4`),
  32 owning tests across the two apps, sabotage patches **360–363**. §7 names exactly what
  is deferred.
- **Task:** close the last open G11 line (`saas-gap-roadmap.md:64`) — a public status page —
  **without** giving the product a second, disagreeable notion of health. At HEAD the fleet
  substrate computed per-app status correctly and nothing published it: all 16 route tables in
  `Samen.Web.Router.__routes__/2` and all 21 `samen_*_routes` macros were authenticated or
  tenant-scoped, and `status_page|public_status|StatusPage` returned zero hits across
  `samen_web` + `samen_core`.
- **Deciders:** no operator decision is opened by this ADR. The three judgement calls (§4.2's
  lossy enum mapping, §4.3's opt-in mechanism, §7's deferral) are ruled here and are all
  reversible in the narrowing direction.

---

## 1. Context

`Samen.Fleet.Registry.build_row/3` (ADR-044 §4.6, §8.2) already derives, per registered app, a
bounded status from the app's own `stale_after_s` and the **cockpit's** `received_at` — never the
producer's `generated_at_us`. That is the dead-man semantics ADR-044 shipped, and it is the
single hardest thing about a status page to get right.

A public status page therefore has exactly one legitimate job: **project** that row onto a plane
with no identity on it. The failure mode worth designing against is not "the page is wrong" — it
is "the page is *separately* right", i.e. a second uptime computation that drifts from the
cockpit's and eventually contradicts it in front of customers.

## 2. Decision

1. **The public page computes nothing.** `Samen.Fleet.PublicStatus.read/2` calls
   `Registry.read_rows/2` and projects. There is no probing, no staleness arithmetic, no
   scheduler and no second threshold anywhere in the public path.
2. **The projection is a closed two-field struct**, `%PublicStatus.Entry{slug:, status:}`, with
   `@enforce_keys` on both. Widening the public plane requires editing that struct — a visible,
   reviewable act rather than a passing `Map.put/3` in a template.
3. **Publication is opt-in per app and defaults to off** (§4.3).
4. **The surface is unauthenticated and rate-limited** through the one shared seam (§4.4).
5. **It fails closed** (§4.5).
6. **It is framework-first**: a vertical adopts it with one router line and zero authored LOC
   (§6). No vertical re-implements any of it.

## 3. Why a narrowing, not a scrubber

The cockpit row carries `app_id`, `display_name`, `mode`, `transport`, `received_at`,
`stale_after_s` and the producer's `report` payload. A scrubbing design would render from that
row and remove the dangerous fields; every future template edit would then be a chance to
re-add one.

Instead the narrowing happens **one layer below the renderer**, in samen_core. The web module
never holds a row — it holds `Entry` structs — so no change to the HTML can widen the plane.
The `report` payload in particular never crosses: it is schema-validated at ingest but it is
still the only field on the row this cockpit did not author, so keeping it out by construction
is what makes the page token-blind rather than token-scrubbed.

## 4. Mechanism

### 4.1 Storage

One additive column, `flt_app.publish_status` (`:boolean`, `allow_nil?: false`,
`default: false`), declared in `Samen.Fleet.Scope.Blueprint.define_app/5`. Nullable in Postgres
with `DEFAULT false` (the expand-safe shape), so pre-existing rows read `false`: the migration
publishes nothing. Not a `pii_` column, not vault-routed — INV-2 untouched, and the C7
`NoPiiColumns` verifier still runs on the resource.

### 4.2 Two vocabularies, mapped lossily on purpose

| internal (`build_row/3`) | public | rationale |
|---|---|---|
| `:active` | `:operational` | reporting inside its window |
| `:stale` | `:degraded` | dead-man overdue (ADR-044 §4.6) |
| `:unreachable` | `:down` | has never reported |
| `:revoked` (suspended) | `:maintenance` | a credential revocation or suspension is an operator/security **act**; the public plane states an effect, never an act |
| `:deregistered` | *excluded* | the app is gone; it is not "down", and a gone app is not a public incident |
| anything else | `:down` | fail closed — an unrecognised internal state is never an all-clear |

`overall` is the worst published status, or `:unknown` when nothing is published — so an empty
page never renders "operational" for a fleet it is publishing nothing about.

The public vocabulary is deliberately **smaller** than the internal one. That is the point: the
mapping is not a rename, it is a loss of operator-meaningful distinctions.

### 4.3 Opt-in is a DB flag, flipped only by an operator

`Samen.Fleet.Registry.set_publish_status/4` is the only verb. It is gated by the resource's
existing update policy (`Samen.Policy.FleetAdminOnly`), so a `HeartbeatActor` — the reporting
app itself — is refused. That is ADR-044 §4.5's "never an app-initiated verb" lesson applied to
visibility: an app must not be able to publish itself, and the refusal is a policy, not an `if`.

Rejected alternative: a cockpit-side allowlist of published slugs passed to the router macro. It
needs no migration, but it makes publication a **deploy**, and it puts the list in code where a
copy-paste can publish a slug nobody audited. Per-row state with a `false` default is auditable
and reversible in one call.

### 4.4 Public and rate-limited

Mounted in a host's PUBLIC router scope (no auth pipeline, no `on_mount`, no session, no CSRF) —
the posture `samen_module_routes :kb` and `:csat` already use. The request's identity is not
consulted because there is none; the substrate read runs as the internal
`Samen.Aggregate.Actor` resolved server-side, so **a request parameter can never widen what is
published** (`index/2` ignores params entirely).

The flood guard is the only gate the surface has, so it goes through
`Samen.Web.RateLimit` (ADR-038 §6.1 — never a parallel implementation) as a new
`:public_status_ip` surface, default **120/min per remote IP**, keyed on the IP alone (§6.2's
non-PII key discipline; never persisted). Over the window is a bare **429 with an empty body**:
a differentiated 429 would be an oracle for whether this cockpit publishes anything at all.

The path is `/status`, deliberately **not** under `/fleet`. Everything under `/fleet*` is
authority-gated and cross-checked by `mix samen.verify.fleet_wire` against
`Samen.Fleet.RouteTable.declared/0`; a public path does not belong in that surface, and keeping
it out leaves RP-J-12's "no un-gated `/fleet*` path" enumeration exact rather than carve-out-ridden.

### 4.5 Fail closed

No namespace, an unreadable namespace, or any raise during resolution is `{:error, :unavailable}`
in the projection and a **503** that says "unavailable" on the page. Never an empty 200: a
reader — human or monitor — takes an empty status page as an all-clear, which is precisely the
fabricated-completeness ADR-014/024/026 refuse. Sabotage 363 is a 200 carrying the unavailable
text, and the named red is the status code.

### 4.6 Masking the one string that crosses

ADR-044 §5.2 already makes `slug` cockpit-side/operator-typed only. This ADR does not take that
on trust. A slug outside the bounded operator shape `[a-z0-9][a-z0-9-]{0,62}` renders `••••`.
`_` is outside the shape, so every `vt_*` vault token is masked on that count alone, and the
`vt_` prefix is refused explicitly as well; so are legal names, e-mail addresses, capitals and
anything with whitespace or punctuation. Both strings that reach the HTML (the bounded slug and
the mount's operator-authored title) are `Plug.HTML.html_escape/1`-escaped.

## 5. Not published, and why

`app_id`/`org_id` (cross-surface correlatable), `display_name` (the likeliest place a tenant's
legal name appears), `base_url` (internal topology), `mode`/`transport`/`received_at`
(operational detail about how often a tenant's infrastructure answers), and the producer
`report` payload. None of these reach the web layer at all.

## 6. Adoption (≈0 LOC)

```elixir
scope "/", MyAppWeb do
  pipe_through :browser
  samen_fleet_status_route(namespace: MyApp.Fleet)
end
```

Mounting it on a live cockpit exposes an **empty** page, never the fleet, until an operator
publishes an app. No vertical (demo/driftwood/pawchart) contains any part of this feature.

## 7. Deferred, named (first increment)

**Uptime percentages and an incident TIMELINE are NOT in this increment**, and the page says
nothing about history — it renders current status and a line stating that it reports no history.

Both need decisions this change does not make: a retention window over `flt_report` (which
ADR-046's retention story governs), a bounded rule for what constitutes one "incident" rather
than N adjacent stale reports, and a masking rule for incident *timing* (exact timestamps are
themselves operational detail about a tenant, §5). Rendering "uptime: 100%" computed from
whatever reports happen to be in the table would be exactly the fabricated completeness this
repo refuses, so it is absent rather than approximate. A follow-on backlog row should carry it.

## 8. Proof obligations, discharged

| # | Obligation | Where |
|---|---|---|
| 1 | Opt-in defaults off; registering publishes nothing | `samen_core/test/fleet_public_status_test.exs` + sabotage **360** |
| 2 | A `vt_`-shaped or out-of-shape slug renders `••••`, never plaintext | both test files + sabotage **361** |
| 3 | No `app_id`/`display_name`/`base_url`/payload value/internal enum in the bytes, with an upstream positive control proving each value exists to leak | both test files |
| 4 | Publication is operator-only; the app's own heartbeat actor is refused, with the admin call as positive control | `samen_core/test/fleet_public_status_test.exs` |
| 5 | Rate-limited per IP; over-limit is an empty 429, with a raised-limit positive control | `samen_web/test/samen/web/fleet_public_status_test.exs` + sabotage **362** |
| 6 | Fails closed to a 503 that says so | both test files + sabotage **363** |
| 7 | The mount is genuinely public and carries its namespace — proven by dispatching through a real compiled router | `samen_web/test/support/public_status_router.ex` |
| 8 | Staleness is ADR-044's, not a second one | the `:degraded` test drives `stale_after_s` alone; no threshold exists in the public path |

## 9. Consequences

* G11's last open line closes with no new dependency, no cloud credential and no new probe.
* One more `flt_app` column for any future cockpit host to migrate (two test mounts migrated here).
* `Registry.build_row/3` gains one key (`publish_status`) so the projection can filter without
  re-reading the app rows or re-deriving staleness.
* The public/internal vocabulary split is now a thing to maintain: a new internal status must be
  mapped in `public_status/1` or it renders `:down` by the fail-closed clause.
