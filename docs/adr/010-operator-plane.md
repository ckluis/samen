# ADR-010 — The Operator / SaaS-company plane: accounts ARE tenant orgs, platform billing over tenants, the SaaS's own help desk, and the identity line

- **Status:** Accepted (design; Build phase follows this contract)
- **Date:** 2026-07-08
- **Task:** Framework-layer DESIGN of the OPERATOR / control plane — the "SaaS-employee side."
  Specify the operator-org model, the operator CRM (accounts = tenant orgs), platform billing
  (the SaaS billing its tenants), the SaaS's own support desk, and — load-bearing — the
  IDENTITY LINE (tenant-admin PII clear to the operator, tenant-end-customer PII masked),
  expressed through `Samen.Api.PiiResolution` so it is masking-by-construction and testable.
- **Deciders:** opus (framework layer), grounded in the vision doc
  (`docs/samen-foundry.txt` — "operator CRM where accounts ARE tenant orgs; billing/MRR over
  tenants; tickets tenants file with the SaaS") and the owner's Phase-2 mandate.
- **Builds on:** **ADR-009** (`samen_web`, the two-plane pattern, `Samen.Web.{Mount,Plane,Router}`,
  the framework CRM/Billing/Support LiveViews + reads). ADR-009 §5.3 explicitly deferred the
  *native operator CRM* ("accounts = `Identity.Org` list") to Phase 2 and named the seam
  (`Samen.Web.Plane` already carries `operator_id` + `target_org_id`; the mount threads the
  namespace). **This ADR is that Phase-2 contract.** It also builds on ADR-004 (library-authored
  scope blueprints, host-materialized resources), the kernel's `Samen.Api.PiiResolution`
  (`plane_of/1` + `impersonated?/1`), `Samen.Impersonation` (T4.1), and `Samen.Aggregate.Actor`
  (T4.2, token-blind).
- **Supersedes / touches:** nothing. `samen_core` is UNTOUCHED (842 green; the only sanctioned
  append is abbrev-registry rows). All new code is framework-level in `samen_web`; the driftwood
  vertical only PROVES it.

---

## 1 · Context — the realization that makes the whole plane fall out of the kernel

The owner's Phase-2 idea, stated exactly: **the SaaS company is ITSELF an org — the OPERATOR ORG
— running the SAME universal scopes, whose ACCOUNTS/CUSTOMERS/REQUESTERS ARE THE TENANT ORGS.**

This is not a new data model. It is the thesis turned on itself. ADR-004 already made every scope
a mountable blueprint (`use Samen.Scopes.{Identity,Billing,Support}`), materialized in a host
namespace, org-scoped by `Samen.Policy.OrgScope`. The operator org is **just another host org**
that mounts those scopes — except its rows describe *its book of business as a SaaS vendor*:

| Operator surface | Reads (framework scope) | Each row IS… |
|---|---|---|
| Operator **CRM** — "Accounts" | `Samen.Scopes.Identity.Org` (+ `.User`, `.Membership`) | a **tenant org** + its **admins** |
| Operator **BILLING** — platform billing | `Samen.Scopes.Billing.{Customer,Subscription,Plan,Invoice,Payment}` | a **tenant's subscription TO the SaaS** |
| Operator **SUPPORT** — the SaaS help desk | `Samen.Scopes.Support.{Ticket,Conversation,Message,Agent}` | a **ticket a tenant filed WITH the SaaS** |

The critical consequence — and the single decision this ADR most needs to get right — is the
**identity line**. There are TWO distinct PII populations reachable from an operator seat, and they
are governed by OPPOSITE rules:

1. **The operator's OWN customers** — the tenant orgs and their admins. The tenant-admin
   (e.g. Blue Ridge's owner) *signed up with the SaaS*; the SaaS owns that PII. The operator sees
   it **in the clear** — because to the operator org, this is *tenant-plane-over-its-own-data*
   (the same tenant-as-owner rule ADR-009 §5.1 states: an org reads its own PII with no reveal
   grant).

2. **The tenant's DOWNSTREAM end-customers** — Blue Ridge's drivers/shippers, its CRM contacts,
   its support message bodies. That PII belongs to the *tenant*, not the SaaS. The operator sees
   it **masked `••••`**, reachable only via impersonation + a second-party reveal (ADR-009 §5.3(1),
   the existing `Samen.Impersonation` path).

**The whole design must make (1) clear and (2) masked BY CONSTRUCTION — through the existing
`PiiResolution` resolver, with no new plaintext path and no per-LiveView masking branch.** §5 is
that mechanism, and it is the load-bearing section. Everything else (the operator org model, the
three surfaces, the mount, seeds) exists to make §5 real and testable.

### 1.1 The key realization: the identity line IS the plane line, already built

`Samen.Api.PiiResolution` masks off exactly one thing: `plane_of(actor) = actor.plane`
(`pii_resolution.ex:158`). `Samen.Policy.OrgScope` filters off exactly one thing:
`actor.org_id` (`org_scope.ex:filter/2`). Compose them:

- **Operator reads its OWN book of business** ⇒ actor `%{org_id: <operator_org_id>, plane: :tenant}`.
  `OrgScope` narrows every read to the operator org's own rows (its `Identity.Org` accounts, its
  `Billing.Customer` = tenant subscriptions, its `Support.Ticket` = tenant-filed tickets). `plane:
  :tenant` ⇒ `PiiResolution` reveals the tenant-admin's name/email **in the clear**. This is
  population (1) — and it is *literally the tenant plane, scoped to the operator org*. **No new
  code path.** The operator org is a tenant over its own vendor data.

- **Operator opens ONE tenant's downstream world** ⇒ actor `%{org_id: <target_tenant_org_id>,
  plane: :operator, impersonation: %{...}}` (ADR-009 `Plane.operator/3`). `OrgScope` narrows to the
  target tenant's rows; `plane: :operator` + `impersonated?` ⇒ `PiiResolution` returns `%Masked{}`
  ⇒ `••••`. This is population (2) — and it is the EXISTING impersonation path.

So the identity line is not something to invent; it is the **composition of two already-tested
kernel primitives** (`OrgScope` by `org_id`, `PiiResolution` by `plane`). The operator plane's job
is to (a) name the operator org, (b) build the operator-org tenant-plane scope, (c) frame the
three inherited scopes with operator vocabulary ("Accounts", "Platform MRR", "Tickets filed with
us"), and (d) prove — with tests — that (1) is clear and (2) is masked. This ADR specifies exactly
that, staged and minimal-viable per the scope-decomposition discipline.

---

## 2 · Decision (overview)

Ship, framework-level in `samen_web`, a thin **operator-org context + three operator LiveViews +
a one-line host mount**, all reusing the ADR-004 scopes and the ADR-009 machinery unchanged:

- **`Samen.Web.Operator` context** — a small module that (a) resolves the well-known **operator
  org id** for a host, (b) builds the **operator-org tenant-plane** `Samen.Web.Mount` + scope, and
  (c) exposes the "accounts ARE tenant orgs" bridge (§3).
- **`Samen.Web.Operator.AccountsLive`** — the operator CRM. Lists `Identity.Org` rows as ACCOUNTS
  (health/plan/MRR/seats), with primary-contact = the tenant's admins (`Identity.User` via
  `Membership.role == :admin`), PII **clear** (§4a, §6 read layer).
- **`Samen.Web.Operator.PlatformBillingLive`** — platform billing. Each tenant's subscription-to-
  the-SaaS (plan/MRR/status), invoices the SaaS issues tenants, dunning/past-due, total platform
  MRR — reconciled against the token-blind `AggregateLive` number (§4b).
- **`Samen.Web.Operator.DeskLive`** (+ `DeskTicketLive`) — the SaaS's own help desk. Tickets
  TENANTS file WITH the SaaS (requester = a tenant-org admin), SLA/priority/assignment to SaaS
  support staff (§4c).
- **`Samen.Web.Operator.Reads`** — one operator read layer over the three scopes, mount-
  parameterized exactly like the ADR-009 `{CRM,Billing,Support}.Reads` (§6).
- **`samen_operator_routes/2`** — a host router macro (sibling to `samen_module_routes/3`) that
  mounts all operator pages in ONE line over the operator-org namespace + repo (§7).
- **Provisioning + seed map** — a well-known operator org, mounted Identity/Billing/Support in the
  operator namespace, and a seed that makes tenant orgs appear as accounts with real
  admins/subscriptions/tickets (§8).

Nothing here adds a plaintext path. The operator CRM/billing/desk read the *operator org's own*
scope rows on the *tenant plane*; the downstream-tenant masking stays the ADR-009 impersonation
path. `samen_core` is untouched (§9).

The staging is explicit (§10): **Phase 2a** (this ADR's Build target) ships the operator-org
context, the AccountsLive + read layer, the mount, the seed, and — mandatorily — the identity-line
test. **Phase 2b/2c** (registered follow-ups) deepen PlatformBillingLive dunning + DeskLive
assignment/threading. The contract for all of them is fixed here so each is a bounded add.

---

## 3 · The OPERATOR ORG model (surface (a))

### 3.1 What "the operator org" is, precisely

The operator org is **an `Identity.Org` row like any other**, mounted in a dedicated host
namespace, distinguished ONLY by being the well-known org the operator seat is scoped to. There is
no new resource type, no `is_operator` boolean bolted onto the kernel Org (that would touch
`samen_core`). It is a *convention over existing rows*: one org id, known to the host, that the
operator LiveViews scope to on the tenant plane.

Three framing questions and their answers:

- **Where do its scopes live?** In an **operator namespace** the host mounts, e.g.
  `Driftwood.Operator` (a domain that does `use Samen.Scopes.Identity`, `Billing`, `Support`).
  This is a *second* mount of the same blueprints alongside the vertical's own tenant mounts
  (`Driftwood.Crm`/`Billing`/`Support`), with FRESH abbrevs (the abbrev registry is global —
  ADR-006; every mount reserves its own, append-only). The operator namespace's rows describe the
  SaaS's book of business; the vertical namespace's rows describe the vertical's own tenants.

  > **Why a separate namespace, not "the operator org lives inside the tenant Billing table"?**
  > Because the two are DIFFERENT org populations under DIFFERENT ownership. Blue Ridge's
  > `Billing.Customer` rows are Blue Ridge's downstream shippers (tenant-owned PII → masked to
  > operator). The operator's `Billing.Customer` rows are the tenant orgs themselves as the SaaS's
  > customers (operator-owned PII → clear to operator). Same blueprint, two mounts, two org
  > populations, two ownership planes. Co-mingling them in one table would make the identity line
  > un-drawable — `OrgScope` could not separate "my downstream customers" from "the platform's
  > customers." Two namespaces makes the line a mount boundary, which is exactly where ADR-004 puts
  > all such boundaries.

- **How is it identified?** By a **well-known operator org id** the host configures. The
  `Samen.Web.Operator` context resolves it via, in order: an explicit `operator_org_id:` mount
  option → `Application.get_env(otp_app, :operator_org_id)` → the single row in the operator
  namespace's `Org` table (the seed guarantees exactly one). This mirrors ADR-009's "host supplies
  the irreducible facts; the framework derives the rest."

- **How is it provisioned + seeded?** By `mix <host>.seed` inserting one operator `Org`, its SaaS
  support staff as `Identity.User`s + `Support.Agent`s, and — the bridge — one `Billing.Customer` +
  `Subscription` + `Support` requester per TENANT org (§8). The operator org is created exactly as
  any org is (the `Org` create policy is `authorize_if always()` — bootstrap-friendly, `identity/
  blueprint.ex:132`).

### 3.2 The `Samen.Web.Operator` context

```elixir
defmodule Samen.Web.Operator do
  @moduledoc """
  The operator / SaaS-company control-plane context (ADR-010). The SaaS company is ITSELF an
  org — the OPERATOR ORG — running the same universal scopes, whose accounts/customers/
  requesters ARE the tenant orgs.

  This context resolves the well-known operator org id and builds the operator-org
  TENANT-PLANE scope. That is the identity-line hinge: the operator reads its OWN book of
  business (tenant orgs as accounts, tenant-admins as contacts) on the tenant plane, so that
  PII is CLEAR — the SaaS owns it. The tenant's DOWNSTREAM end-customer PII stays masked,
  reachable only via the ADR-009 impersonation plane (`Samen.Web.Plane.operator/3`), which
  this context does NOT change.
  """

  alias Samen.Web.{Mount, Plane}

  @doc """
  The operator org id for a mount. Resolution order:
    1. the mount's `:operator_org_id` label (explicit),
    2. `Application.get_env(otp_app, :operator_org_id)`,
    3. the single seeded row in the operator namespace's `Org` table.
  """
  @spec org_id(Mount.t()) :: String.t()
  def org_id(%Mount{} = mount), do: # (impl per resolution order above)

  @doc """
  The operator-org TENANT-PLANE scope. The operator acts as an org OVER ITS OWN vendor data:
  `%{org_id: operator_org_id, plane: :tenant}`. `OrgScope` narrows every read to the operator
  org's rows; `plane: :tenant` reveals the operator's OWN customers' PII (the tenant-admins) in
  the clear. This is population (1) of the identity line — clear by construction.
  """
  @spec scope(Mount.t()) :: Samen.Scope.t()
  def scope(%Mount{} = mount), do: Plane.scope(Plane.tenant(), org_id(mount))
end
```

The scope is **`Plane.tenant()` scoped to the operator org id** — deliberately reusing the exact
tenant-plane actor ADR-009 already tests (`plane: :tenant`, `kind: :tenant`). No new actor shape;
the identity-line clarity for population (1) is inherited verbatim from the tenant-plane guarantee.

### 3.3 The bridge — "accounts ARE tenant orgs"

The operator CRM's account list is `Identity.Org` rows read on the operator-org tenant plane. But
*which* Org rows? Here is the precise bridge, and it has TWO valid realizations; this ADR CHOOSES
the second and registers the first as an explicitly-considered alternative:

- **(Bridge-A, rejected as primary) Read the tenant orgs directly from the VERTICAL's Identity
  mount.** The operator would read `Driftwood.Identity.Org` (the tenant population) on a
  cross-tenant operator actor. Rejected: it requires an org-LESS cross-tenant read of a
  tenant-plane resource, which `OrgScope` refuses by construction (`nil` org_id ⇒ `expr(false)` ⇒
  zero rows — `org_scope.ex`). Bending `OrgScope` to admit a cross-tenant reader would punch a hole
  in the one policy every tenant read depends on. Unacceptable.

- **(Bridge-B, CHOSEN) The operator org has its OWN row per tenant, in the operator namespace.**
  The seed mirrors each tenant org into the operator namespace as: an operator-side `Identity.Org`
  *account* row (carrying the tenant's display name + plan + a `custom.tenant_org_id` back-
  reference), whose *admins* are operator-side `Identity.User` rows holding the tenant-admin's name
  + email (the PII the SaaS owns), plus a `Billing.Customer`/`Subscription` (the tenant's
  subscription to the SaaS) and a `Support` requester. **The operator's account list is then a
  plain tenant-plane `OrgScope` read of the operator namespace, scoped to the operator org id — no
  cross-tenant read, no policy bend.**

  > **Isn't Bridge-B "denormalizing the tenant into the operator namespace"?** Yes — deliberately,
  > and it is the correct model, not a shortcut. The SaaS's *record of its customer* is a distinct
  > fact from the tenant's *record of itself*: the SaaS stores the billing contact it signed the
  > tenant up with, the plan it sold, the MRR it books — data the SaaS OWNS and the tenant may not
  > even see. Bridge-B makes that ownership a storage fact (operator-namespace rows, operator-org-
  > scoped), which is exactly what makes the identity line hold: the operator sees these in the
  > clear because they are *its own* rows on *its own* tenant plane. The `custom.tenant_org_id`
  > back-reference is the join key that lets "open this account" launch the ADR-009 impersonation
  > into the real tenant namespace (masked). One field bridges the two planes without merging them.

The bridge is thus: **operator-namespace account row → `custom.tenant_org_id` → ADR-009
`Plane.operator(operator_id, tenant_org_id)` impersonation into the vertical namespace.** Clear
side and masked side meet at exactly one field, and crossing from clear (the account) to masked
(the tenant's downstream world) is the deliberate impersonation click.

---

## 4 · The three operator surfaces

All three are framework LiveViews reading the operator-org tenant plane via `Samen.Web.Operator.
Reads` (§6). They reuse the ADR-009 `Samen.UI` kit and the ADR-009 read patterns; the only new
work is operator VOCABULARY + the account-join + the platform-MRR/dunning/desk aggregations.

### 4a · Operator CRM — `Samen.Web.Operator.AccountsLive`

An ACCOUNTS view where each account IS a tenant org.

- **List** = `Identity.Org` rows (operator namespace, operator-org-scoped): account name, plan,
  status/health, `custom.tenant_org_id`.
- **Primary contacts** = the account's admins: `Identity.User` rows joined via `Identity.Membership`
  where `role == :admin`, **PII CLEAR** (name/email of the tenant-admin — the SaaS's own signup
  contact). This is the identity-line clear side, rendered directly.
- **MRR / seats per account** = joined from the operator Billing scope (the tenant's subscription
  to the SaaS) + a seat count (Billing `Usage` metric `:seats`, or membership count).
- **Row action "Open account"** = launches ADR-009 impersonation into the tenant namespace via the
  `custom.tenant_org_id` back-reference — that view renders the tenant's downstream CRM MASKED
  (the existing `Samen.Web.CRM.*` LiveViews under `plane: :operator`). The masked side is not
  re-implemented; the account list LINKS to it.

Health is minimal-viable in 2a: a computed pill from subscription status (`active` → healthy,
`past_due` → at-risk, `cancelled` → churned). Richer health scoring is a registered follow-up.

### 4b · Operator BILLING — `Samen.Web.Operator.PlatformBillingLive`

The PLATFORM billing its tenants.

- **Per-tenant subscription-to-the-SaaS** = operator Billing `Subscription` joined to `Customer`
  (billing_name/email = the tenant-admin's, CLEAR) + `Plan` (the SaaS plan the tenant is on) +
  MRR (from `Price.unit_amount_cents` on the monthly price) + status.
- **Invoices the SaaS issues tenants** = operator Billing `Invoice` rows (the SaaS is the biller,
  the tenant org is the customer). Dunning/past-due = invoices with `status in [:open]` past
  `due_date`, plus subscriptions `status == :past_due`.
- **Total platform MRR** = `sum(monthly Price for active subscriptions)` over the operator org —
  computed by the SAME `Samen.Web.Billing.Reads.metrics/2` MRR logic (`mrr_cents`), just scoped to
  the operator org. This is the reconciliation hinge (§4b.1).

The Billing scope is REUSED unchanged — the operator org is the *biller*, tenant orgs are the
*customers*, exactly the Stripe-mirror shape the blueprint already models (`billing/blueprint.ex`:
Customer/Subscription/Plan/Price/Invoice/Payment). No new billing resource.

#### 4b.1 Reconciliation with the token-blind Aggregate MRR

There are now TWO platform-MRR numbers, and they MUST agree:

1. **Operator-plane platform MRR** — `PlatformBillingLive` sums the operator org's active
   subscriptions' monthly prices (per-tenant, PII-clear customer names). Subject-level, exact.
2. **Token-blind aggregate MRR** — `Samen.Web.Operator.AggregateLive` (ADR-009 §5.3(2)), fed by the
   host's `aggregate_loader` over the `Samen.Aggregate` domain, k-anon-suppressed, NO subject.

**The reconciliation rule (fixed here):** both derive from the SAME underlying subscription/price
facts, so their UNSUPPRESSED total must be equal; the aggregate number is the operator number with
small cohorts suppressed (`⊘`) and never larger. Formally:
`aggregate.total_cents == platform_billing.mrr_cents − Σ(suppressed cohort cents)`, and with no
suppression the two are identical. The Build ships a reconciliation TEST asserting this equality on
the seed (where no cohort is below the k-anon floor, so they are exactly equal). This makes "MRR"
one number with two lawful views (exact-with-subjects vs blind-aggregate), not two numbers that
might drift — the drift is what the test forbids.

> The two views remain the doc's mutually-exclusive operator paths (T4.2): `PlatformBillingLive`
> reads the operator org's own Billing rows on the TENANT plane (the SaaS's own customers, clear);
> `AggregateLive` reads the token-blind projection with the aggregate actor (no subject). One is
> "my customers, by name"; the other is "the portfolio, blinded." The reconciliation test asserts
> they footer to the same MRR — proving the blind view is honest — without either crossing into the
> other's plane.

### 4c · Operator SUPPORT — `Samen.Web.Operator.DeskLive` (+ `DeskTicketLive`)

The SaaS's OWN help desk.

- **Tickets tenants file WITH the SaaS** = operator Support `Ticket` rows (operator-org-scoped).
  The **requester = a tenant-org admin** — realized by a `custom.requester_org_id` +
  `custom.requester_user_id` on the ticket pointing at the operator-namespace account + its admin
  User (whose name/email are CLEAR — the SaaS's own customer). SLA/priority ride the existing
  Ticket columns (`sla_breach_at`, `priority`, `Sla` config rows — `support/blueprint.ex`).
- **Assignment to SaaS support staff** = the ticket's handling `Agent` = an operator-namespace
  `Support.Agent` (the SaaS's employee), joined via `Message.agent_id` (as ADR-009's
  `Support.Reads` already joins). Assignment as a first-class column is a registered 2c follow-up;
  2a uses the existing agent-on-message join.
- **Conversation/message threading** = the ADR-009 `Support.Reads.conversations_for_ticket/3` verbatim,
  scoped to the operator org — message bodies are the SaaS↔tenant-admin conversation, PII-resolved
  on the tenant plane (CLEAR, because both parties are the SaaS's own — the tenant-admin is the
  SaaS's customer; the SaaS agent is the SaaS's employee).

The Support scope is REUSED unchanged: requester = tenant-admin, agent = SaaS staff, both operator-
namespace rows on the operator-org tenant plane.

---

## 5 · THE IDENTITY LINE — the exact rule + by-construction mechanism (LOAD-BEARING)

This is the section the task says to "get right." State the rule, then prove it is enforced by the
existing resolver with zero new code paths.

### 5.1 The rule (one sentence, two populations)

> **To an operator seat, PII the SaaS OWNS (its tenant-org accounts and those accounts'
> tenant-admins — its own signup/billing/support contacts) is CLEAR; PII the SaaS's TENANTS own
> (a tenant's downstream end-customers — CRM contacts, message bodies, drivers/shippers) is
> `••••`, reachable only through impersonation + a second-party reveal.**

### 5.2 The mechanism — the line is the COMPOSITION of two kernel primitives

Nothing new masks or reveals. The line is drawn by composing `OrgScope` (which rows) with
`PiiResolution` (clear vs masked), both already in `samen_core`, both already tested:

| Population | Actor the operator LiveView uses | `OrgScope` filters to | `PiiResolution` (`plane_of`) → |
|---|---|---|---|
| (1) SaaS's own book of business — tenant-org accounts + tenant-admins | `%{org_id: operator_org_id, plane: :tenant}` (`Samen.Web.Operator.scope/1`) | the **operator org's own** rows (its accounts, its billing customers, its desk tickets) | **`:tenant` → CLEAR** (own-org PII, no grant — `pii_resolution.ex:125-128`) |
| (2) A tenant's downstream end-customers | `%{org_id: tenant_org_id, plane: :operator, impersonation: %{...}}` (`Samen.Web.Plane.operator/3`, ADR-009) | the **target tenant's** rows | **`:operator` + `impersonated?` → `%Masked{}` → `••••`** (`pii_resolution.ex:139-141`) |

The load-bearing facts, verbatim from the kernel:

- **Population (1) is clear because it is the TENANT plane of the operator org.** The resolver's
  `:tenant` branch reveals own-org PII with no reveal grant (`resolve_field/8`, `:tenant ->
  reveal_plaintext(masked, opts) || masked`). The operator org reading its OWN `Identity.User`
  (a tenant-admin it signed up) is byte-identical to Blue Ridge reading its own CRM contact — same
  branch, same clarity. The SaaS owns this PII; the tenant-as-owner rule applies to the SaaS over
  its own vendor data.

- **Population (2) is masked because it is the OPERATOR plane over a target tenant.** The resolver's
  `:operator` branch, with the impersonation marker present, returns `%Masked{}`
  (`impersonated?(actor) -> masked`), which renders `••••` via `Phoenix.HTML.Safe`. The session
  carries no reveal grant, so plaintext is unreachable without a live second-party grant — the
  existing reveal seam, unchanged.

- **The two populations are STORAGE-separated by mount (§3.1, Bridge-B).** Population (1) lives in
  the operator namespace (operator-org-scoped); population (2) lives in the vertical namespace
  (tenant-org-scoped). `OrgScope` cannot leak one into the other: an operator-org actor reading the
  operator namespace never sees a vertical-namespace row, and impersonation into the vertical
  namespace flips the plane to `:operator` (masked). The line is a mount boundary AND a plane
  boundary at once — belt and suspenders, both by construction.

### 5.3 Why the operator seat CANNOT accidentally see tenant-end-customer PII in the clear

Three independent barriers, any one sufficient — this is the fail-safe posture:

1. **Plane barrier:** to read a vertical-namespace tenant row at all, the operator uses
   `Plane.operator/3` (impersonation), which sets `plane: :operator` — the resolver never reveals
   on that plane without a grant. There is no operator actor with `plane: :tenant` AND a foreign
   `org_id` — `Samen.Web.Operator.scope/1` only ever produces the operator org's OWN id.
2. **Mount barrier:** the operator LiveViews read `Samen.Web.Operator.Reads` over the OPERATOR
   namespace. To touch a vertical-namespace row they would have to be handed a vertical-namespace
   mount — which only the ADR-009 impersonation route does, and that route is `plane: :operator`.
3. **`OrgScope` barrier:** even if a wrong `org_id` were somehow supplied, `OrgScope` filters to
   that exact org's rows; there is no cross-tenant reader (Bridge-A was rejected precisely to keep
   this true).

### 5.4 The test that pins the line (MANDATORY in Build — the task's named test)

A `samen_web`-local test, independent of any vertical, using the operator-namespace test mounts
(`Samen.WebTest.Operator.*`, §8.2) seeded with (i) a tenant-admin User in the operator namespace
(the SaaS's own customer) and (ii) a downstream end-customer Person in a separate tenant namespace:

- **Clear side (population 1):** mount `Samen.Web.Operator.AccountsLive` on the operator-org tenant-
  plane mount; assert the seeded tenant-admin's name/email render **in the clear** (the distinctive
  sentinel string is PRESENT in the DOM).
- **Masked side (population 2):** open the same account's downstream CRM via the ADR-009 operator/
  impersonation mount into the tenant namespace; assert the tenant end-customer's name/email render
  `••••` and the vault token string is **ABSENT** from the DOM.
- **Cross-leak red path:** assert that reading the operator plane does NOT surface any tenant-
  namespace end-customer row (the account list contains the account, never the tenant's downstream
  contacts), and that the operator-org tenant-plane actor reading the vertical namespace returns
  zero rows (the `OrgScope` cross-mount refusal).

This is the direct analogue of ADR-009 §6's tenant-clear/operator-masked render tests, extended to
the operator plane's two-population line. It travels with the framework, not the vertical.

---

## 6 · The operator read layer — `Samen.Web.Operator.Reads`

Mount-parameterized exactly like the ADR-009 `{CRM,Billing,Support}.Reads` (resource + repo from
`Samen.Web.Mount`, PII through `Samen.Api.PiiResolution.resolve/4`). The ONLY differences from the
three ADR-009 reads modules are (a) it reads the operator-org tenant-plane scope from
`Samen.Web.Operator.scope/1`, and (b) it JOINS across the three scopes to assemble an "account"
(Org + admin Users + Subscription + open Tickets).

```elixir
defmodule Samen.Web.Operator.Reads do
  @moduledoc """
  Operator control-plane read layer (ADR-010). Reads the OPERATOR ORG's own book of business
  on the TENANT plane, so tenant-org accounts and their tenant-admins render PII CLEAR — the
  SaaS owns this data. Assembles "accounts" by joining the Identity/Billing/Support scopes
  over the operator org.

  MASKING INVARIANT (inherited from ADR-009): never calls Samen.Vault.reveal/3, never unwraps
  a %Masked{}, never has a "show plaintext" branch. Tenant-admin PII is clear ONLY because the
  operator-org TENANT-plane resolver clears own-org PII — the same chokepoint, the same rule.
  The DOWNSTREAM tenant's end-customer PII is never read here; that is the impersonation path.
  """

  # accounts(mount, scope) — Identity.Org rows (operator-org-scoped) each joined to:
  #   :__admins__       [Identity.User (PII clear) via Membership role == :admin]
  #   :__subscription__ Billing.Subscription (+ Plan, + monthly Price → mrr_cents)
  #   :__open_tickets__ count of operator Support.Ticket for this account
  #   :tenant_org_id    custom.tenant_org_id (the impersonation back-reference)
  def accounts(mount, scope), do: # (per §4a)

  # platform_billing(mount, scope) — per-tenant subscriptions + invoices + dunning + total MRR
  def platform_billing(mount, scope), do: # (per §4b), reusing Billing.Reads MRR logic

  # desk(mount, scope) — operator Support tickets with requester (tenant-admin, clear) + agent
  def desk(mount, scope), do: # (per §4c), reusing Support.Reads threading
end
```

Because it reads the operator-org tenant plane, the tenant-admin PII resolution is the SAME
`resolve_pii/4` the ADR-009 reads use (tenant branch → clear). No new resolution code; the identity-
line clarity for population (1) is the ADR-009 tenant-clear guarantee, reused.

---

## 7 · The framework surface + how a host mounts the operator workspace

### 7.1 New LiveViews (all under `Samen.Web.Operator.*`, framework-level)

| Module | Route (default) | Reads |
|---|---|---|
| `Samen.Web.Operator.AccountsLive` | `/operator/accounts`, `/operator/accounts/:id` | `Operator.Reads.accounts/2` |
| `Samen.Web.Operator.PlatformBillingLive` | `/operator/billing` | `Operator.Reads.platform_billing/2` |
| `Samen.Web.Operator.DeskLive` (+ `DeskTicketLive`) | `/operator/desk`, `/operator/desk/tickets/:id` | `Operator.Reads.desk/2` |
| `Samen.Web.Operator.AggregateLive` (ADR-009, EXISTING) | `/operator/aggregate` | host `aggregate_loader` |

The four together are the operator workspace; `AggregateLive` already exists and is reused as the
blind-portfolio tab. `Samen.UI.module_nav/1` gains an operator nav group (Accounts · Platform
billing · Desk · Portfolio) exactly as ADR-009 §4.1 added the inherited-module nav — parameterized,
no vertical coupling.

### 7.2 The host mount — one macro, one operator namespace

A sibling to ADR-009's `samen_module_routes/3`, in `Samen.Web.Router`:

```elixir
defmacro samen_operator_routes(namespace, opts \\ []) do
  # namespace = the host's OPERATOR namespace (e.g. Driftwood.Operator), which has mounted
  # Identity + Billing + Support blueprints. opts: repo:, operator_org_id:, labels:.
  # Builds ONE operator-plane mount (scope_kind: :operator) carrying the operator org id in
  # labels, threads it via live_session, declares all operator routes.
end
```

Host usage (Driftwood router), one line for the whole operator workspace:

```elixir
scope "/" do
  pipe_through :browser
  samen_operator_routes Driftwood.Operator, repo: Driftwood.Repo
end
```

The mount carries `scope_kind: :operator` (a new value in the `Mount` type union — a one-line
append to the existing `:crm | :billing | :support | :aggregate` set, and to `Mount.from_session`'s
explicit `scope_kind/1` map). The operator LiveViews read `Samen.Web.Operator.scope/1` (operator-
org tenant plane) rather than a per-request plane, because the operator seat is always the operator
org acting over its own book of business; crossing to a tenant's masked world is the explicit
impersonation link (§3.3), which reuses the ADR-009 operator-plane mount unchanged.

> **Note — the operator seat's plane is `:tenant` (of the operator org), NOT `:operator`.** This is
> the subtle, correct thing. "Operator plane" in ADR-009 meant *impersonating a tenant, masked*.
> The operator's OWN control-plane workspace is the operator org on ITS OWN tenant plane (clear).
> The word "operator" names the ORG and the WORKSPACE; the PII PLANE for that workspace is
> `:tenant` (own data, clear). Only the drill-into-a-tenant action uses `plane: :operator` (masked).
> Getting this vocabulary exact is what makes the identity line unambiguous: operator-workspace ≠
> operator-PII-plane. Population (1) clear = operator org, tenant plane. Population (2) masked =
> operator impersonating, operator plane.

---

## 8 · Provisioning / migration / seed map

### 8.1 Host provisioning (Driftwood, the prover)

- **`Driftwood.Operator`** — a new domain: `use Samen.Scopes.Identity`, `use Samen.Scopes.Billing`,
  `use Samen.Scopes.Support`, `namespace: Driftwood.Operator`, `repo: Driftwood.Repo`, with FRESH
  abbrevs (append-only rows in the global registry — ADR-006; e.g. `oid/ous/omb/…` for operator
  Identity, `obc/obs/…` for operator Billing, `osk/osg/…` for operator Support). No `samen_core`
  code change — only registry rows, the sanctioned append.
- **Migrations** — the copied `Samen.Migration` templates for the three scopes run against
  Driftwood's repo for the operator namespace (ADR-004 pattern), materializing the operator tables
  + catalog rows + vault routing. The operator namespace's PII (tenant-admin name/email) routes into
  Driftwood's ONE Postgres vault, same as every mount.
- **Config** — `config :driftwood, operator_org_id: "<seeded uuid>"` (or resolved from the single
  seeded row, §3.1).

Driftwood does NOT currently mount Identity (only demo does — verified). Mounting the operator
namespace gives Driftwood its first Identity mount, which is correct: the operator's accounts ARE
Identity.Orgs. The vertical's own tenant population is the freight orgs; the operator's accounts are
those orgs mirrored as the SaaS's customers (Bridge-B).

### 8.2 `samen_web` test-support provisioning (for the §5.4 identity-line test)

- **`Samen.WebTest.Operator`** — a domain mounting Identity + Billing + Support in the operator
  namespace against `Samen.WebTest.Repo` (the existing throwaway DB, ADR-009 §6), FRESH abbrevs
  (`woi/wob/wos*` — append-only registry rows).
- **`Samen.WebTest.Operator.Seeds`** — seeds one operator Org, its SaaS agents, and (the bridge)
  per tenant: an operator-side account Org (`custom.tenant_org_id` → a tenant namespace org id) +
  its tenant-admin User (distinctive CLEAR sentinel name/email) + a Subscription + an open desk
  Ticket. Plus one DOWNSTREAM tenant end-customer Person in the EXISTING `Samen.WebTest.Crm`
  namespace (distinctive MASKED sentinel), so the test can assert clear (operator plane) vs masked
  (impersonation plane) on two different populations.

### 8.3 Seed map summary

| Population | Namespace | Rows seeded | PII sentinel | Operator sees |
|---|---|---|---|---|
| (1) Account = tenant org | `*.Operator` (Identity.Org) | 1 per tenant, `custom.tenant_org_id` | — (Org has no PII) | clear (own row) |
| (1) Tenant-admin | `*.Operator` (Identity.User + Membership admin) | 1+ per account | CLEAR sentinel name/email | **CLEAR** (own customer) |
| (1) Tenant subscription-to-SaaS | `*.Operator` (Billing) | Customer+Sub+Plan+Price+Invoice | billing_name = tenant-admin (CLEAR) | clear |
| (1) Desk ticket (tenant→SaaS) | `*.Operator` (Support) | Ticket + Conversation + Message + Agent | message body = SaaS↔admin (CLEAR) | clear |
| (2) Tenant end-customer | `*.Crm` (vertical namespace) | Person | MASKED sentinel name/email | **`••••`** (impersonation) |

---

## 9 · Constraints honored (the hard rules)

- **`samen_core` UNTOUCHED (842 green).** Zero kernel code changes. The operator plane is pure
  composition of existing kernel primitives (`OrgScope`, `PiiResolution`, `Impersonation`,
  `Aggregate.Actor`, the three scope blueprints). The only sanctioned append is abbrev-registry
  rows for the new operator-namespace mounts (ADR-006, append-only, data not code).
- **Framework-level in `samen_web`; the vertical only proves it.** All new modules are
  `Samen.Web.Operator.*` + the `samen_operator_routes` macro + the `Mount` `:operator` scope_kind
  append. Driftwood gains one domain (`Driftwood.Operator`) + one router line + seed rows — the
  proof, not the implementation.
- **Masking by construction via `PiiResolution` — no plaintext bypass.** §5: population (1) clear is
  the tenant-plane resolver branch (own-org, reused verbatim); population (2) masked is the operator/
  impersonation branch (reused verbatim). `Samen.Web.Operator.Reads` inherits the ADR-009 masking
  invariant (never reveals, never unwraps). No new plaintext path exists to bypass.
- **Tests incl. the identity-line test.** §5.4 (mandatory) + §4b.1 (reconciliation) + the operator
  render tests, all `samen_web`-local against `Samen.WebTest.Operator.*`. Plus the driftwood self-
  verify (§11).
- **`--warnings-as-errors` clean; all suites + `ci.sh` green before+after** — §11.

---

## 10 · Staging (minimal-viable per scope-decomposition; seams defined, not gold-plated)

Per the `feedback_scope_decomposition` discipline: ship the seam + the identity-line proof; phase
the deepening. The CONTRACT for all phases is fixed in §§3-8 so each is a bounded add, never a
refactor.

- **Phase 2a (this ADR's Build target — the unambiguous contract):**
  - `Samen.Web.Operator` context (org id resolution + operator-org tenant-plane scope, §3.2).
  - `Samen.Web.Operator.Reads.accounts/2` + `Samen.Web.Operator.AccountsLive` (§4a, §6).
  - `Mount` `:operator` scope_kind append + `samen_operator_routes` macro (§7).
  - `Driftwood.Operator` domain + migrations + seed + router line + config (§8.1).
  - `Samen.WebTest.Operator` mount + seeds + **the §5.4 identity-line test** (mandatory) + the
    operator AccountsLive render test.
  - Driftwood self-verify: `/operator/accounts` renders tenant-admin names CLEAR; drilling to a
    tenant renders downstream CRM `••••` (§11).
- **Phase 2b (registered follow-up) — PlatformBillingLive:** the full platform-billing page +
  dunning/past-due surfacing + the §4b.1 reconciliation test against `AggregateLive`. The read
  helper `Operator.Reads.platform_billing/2` + the MRR-reuse are specified (§4b) so this is a
  page + a test, not new plumbing.
- **Phase 2c (registered follow-up) — DeskLive:** the SaaS help desk page + ticket detail +
  first-class assignment column (Support blueprint gains an `assignee_agent_id` — a scope append,
  reviewed like any scope change). Threading reuses ADR-009 `Support.Reads` (§4c).

Phase 2a alone proves the thesis end-to-end (accounts ARE tenant orgs, tenant-admin clear, tenant-
end-customer masked) — the status-green bar. 2b/2c deepen billing + desk without touching the
identity line or the mount contract.

---

## 11 · Verification (the gate the Build phase must keep green)

- **Before + after:** the root `ci.sh` (spikes + samen_core 842 + demo + driftwood 20-step +
  pawchart + `samen_web` standalone) green. Capture the baseline before; prove no regression after.
- **`samen_web` standalone:** `mix compile --warnings-as-errors` clean; the new operator tests green
  against `Samen.WebTest.Operator.*` on `samen_web_test`:
  - **the §5.4 identity-line test** (tenant-admin CLEAR on the operator plane / tenant-end-customer
    `••••` on the impersonation plane / vault token absent / cross-leak red path) — the mandatory
    one;
  - the `AccountsLive` render test (accounts = Identity.Org rows, primary contacts = admin Users,
    MRR/seats joined);
  - (2b) the reconciliation test (`AggregateLive` MRR footers to `PlatformBillingLive` MRR on the
    unsuppressed seed).
- **Driftwood self-verify (booted, rendered text):**
  `BIN="$HOME/.claude/skills/gstack/browse/dist/browse"`;
  `cd .../driftwood && MIX_ENV=dev PORT=4033 elixir --erl "-detached" -S mix phx.server`; wait
  `/healthz`; `mix driftwood.seed`;
  - `"$BIN" goto "http://127.0.0.1:4033/operator/accounts"; "$BIN" text | grep` a seeded tenant-
    admin's name **in the clear** (population 1); `"$BIN" screenshot`.
  - drill "Open account" → the tenant's downstream CRM shows `••••` and the vault token is absent
    (population 2, the ADR-009 impersonation path).
  - `/operator/aggregate` still renders the token-blind chrome (unchanged), and its MRR agrees with
    `/operator/billing` on the seed (2b).
- **abbrev registry:** the new operator-namespace abbrev rows are append-only; the compile-time
  `Samen.Verifiers.AbbrevRegistry` stays green (no collision).

---

## 12 · Consequences

**Positive**

- The operator / SaaS-company plane is now framework-level: any vertical inherits the operator CRM
  (accounts = its tenant orgs), platform billing, and its own help desk by mounting one namespace +
  one router line — the ADR-004/ADR-009 inheritance story extended to the control plane.
- The identity line is drawn by COMPOSITION of two already-tested kernel primitives (`OrgScope` +
  `PiiResolution`), so it is by-construction and needs no new masking code — the strongest possible
  posture. `samen_core` stays untouched.
- "MRR" becomes one number with two lawful views (exact-with-subjects vs blind-aggregate), pinned
  equal by a reconciliation test — the blind portfolio number is provably honest.
- The two PII populations are separated by BOTH a mount boundary and a plane boundary (belt +
  suspenders), so a single misconfiguration cannot leak tenant-end-customer PII to the operator.

**Negative / accepted**

- Bridge-B denormalizes each tenant into the operator namespace (an account Org + admin User +
  subscription + desk requester per tenant). Accepted: this IS the SaaS's own record of its
  customer (distinct ownership, distinct PII plane), and it is what makes the identity line a
  storage fact rather than a policy exception. A sync seam (keeping account rows in step with tenant
  signups) is a registered follow-up; the seed materializes them for the proof.
- A new `Samen.Web.Operator.*` surface + the `:operator` `Mount` scope_kind + the
  `samen_operator_routes` macro are added indirection. Mitigated: the reads reuse the ADR-009
  patterns verbatim and the macro is a sibling of the existing one; the payoff (one-line operator
  workspace) is the point.
- Driftwood gains its first Identity mount (via `Driftwood.Operator`). Accepted and correct — the
  operator's accounts ARE Identity.Orgs; a SaaS control plane without Identity would be incoherent.

**Neutral**

- The operator workspace's PII plane is `:tenant` (of the operator org), not `:operator` — the word
  "operator" names the org/workspace, not the masking plane (§7.2). Only the drill-into-a-tenant
  action uses `plane: :operator` (masked). This vocabulary is documented so the two are never
  conflated.
- The abbrev registry stays global; the operator-namespace mounts reserve their own append-only
  rows, consistent with every host mount to date (ADR-006).
