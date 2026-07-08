# Operator / SaaS-company plane — BUILD report (ADR-010)

**Status:** GREEN. The operator / control-plane surfaces are built framework-level in
`samen_web` exactly per ADR-010. The SaaS company is itself an org — the OPERATOR ORG —
running the same universal scopes, whose accounts/customers/requesters ARE the tenant orgs.

- `mix compile --warnings-as-errors` clean (samen_web + driftwood, dev + test).
- **samen_web: 67 tests pass** (43 baseline + 24 new operator tests), incl. the mandatory
  identity-line test.
- **samen_core UNTOUCHED (842 green).** Zero kernel code changes; the only appends are
  abbrev-registry rows (data, the sanctioned append — ADR-006).
- **Root `ci.sh` GREEN end-to-end** before and after (spikes · samen_core 842 · samen_web 67 ·
  demo · driftwood 20-step + game-day · pawchart 17-step).
- Driftwood self-verify (booted, PORT=4033): `/operator/accounts` · `/billing` · `/desk` all
  render the SaaS's own book of business with tenant-admin PII **in the clear**, no vault token
  leak.

---

## What shipped

### Framework layer — `samen_web` (the deliverable; the vertical only proves it)

| Module | Role |
|---|---|
| `Samen.Web.Operator` | The context: resolves the well-known operator org id (label → app-env → single seeded Org row) and builds the **operator-org TENANT-plane scope** — the identity-line hinge. |
| `Samen.Web.Operator.Reads` | One read layer over the three scopes; assembles "accounts" (Org + admin Users + Subscription + open tickets), platform billing (subs/invoices/dunning/MRR), and the desk (tenant-filed tickets + requester + agent). Inherits the ADR-009 masking invariant (never reveals, never unwraps a `%Masked{}`). |
| `Samen.Web.Operator.AccountsLive` | Operator CRM — accounts = tenant orgs; primary contact = the tenant-admin (PII clear); health/plan/MRR/seats; "Open account →" drill link. |
| `Samen.Web.Operator.PlatformBillingLive` | Platform billing — per-tenant subscriptions-to-the-SaaS (customer clear), invoices, dunning/past-due, total platform MRR. |
| `Samen.Web.Operator.DeskLive` | SaaS help desk — tickets tenants file WITH the SaaS; requester = tenant-admin (clear); SLA/priority; SaaS agent assignee (clear). |
| `Samen.Web.Operator.Live` | Shared operator sidebar + the four-tab nav (Accounts · Platform billing · Desk · Portfolio) + PII render helpers (never unwrap). |
| `Samen.Web.Router.samen_operator_routes/2` | Sibling of `samen_module_routes/3`: one-line host mount of the operator workspace. New `:operator` `scope_kind` on `Samen.Web.Mount` (a one-line union append). |

### Vertical proof — `driftwood` (proves the mount API; not the implementation)

- `Driftwood.Operator` — a new domain: a SECOND mount of Identity + Billing + Support (fresh
  `do*/dp*/dq*` abbrevs). Driftwood's FIRST Identity mount — correct, because the operator's
  accounts ARE `Identity.Org`s.
- Migration `20260708140000_mount_operator_scopes.exs` (21 operator tables, catalog-in-tx).
- `Driftwood.OperatorSeeds` — stands up the operator org's book of business OVER the two
  EXISTING tenant orgs (Blue Ridge + Summit): each an account Org (slug = tenant_org_id
  back-ref) + tenant-admin User + admin Membership + Customer/Subscription/Plan/Price/Invoice
  (one past-due) + 2 desk tickets whose requester is the tenant-admin. Wired into
  `Driftwood.Seeds.dev_seed/0`.
- Router: `samen_operator_routes(Driftwood.Operator, repo: Driftwood.Repo, operator_org_id: …,
  include_aggregate: false)` — three lines of data, zero UI code. `config :driftwood,
  operator_org_id: …`.

---

## The surface API — how a host mounts the operator workspace

One line over the host's operator namespace (a domain that mounted Identity + Billing +
Support):

```elixir
import Samen.Web.Router

scope "/" do
  pipe_through :browser

  samen_operator_routes Driftwood.Operator,
    repo: Driftwood.Repo,
    operator_org_id: "…",        # else resolved via app-env or the single seeded Org row
    include_aggregate: false,     # host wires its own vertical-shaped token-blind aggregate
    labels: %{operator_workspace: "Samen SaaS", operator_glyph: "S"}
end
```

Mounts `/operator/accounts`, `/operator/billing`, `/operator/desk`. The operator seat is the
operator org over its OWN book of business on the **TENANT plane** (PII of the SaaS's own
customers — the tenant-admins — CLEAR). Crossing to a tenant's masked downstream world is the
explicit "Open account" impersonation link (the existing ADR-009 `plane: :operator` path).

---

## THE IDENTITY LINE — enforced by construction, and TESTED (the load-bearing result)

The line is the **composition of two already-tested kernel primitives**, with NO new masking
code:

| Population | Actor | `OrgScope` → | `PiiResolution` (`plane_of`) → |
|---|---|---|---|
| (1) SaaS's own book of business (tenant-org accounts + tenant-ADMINS) | `%{org_id: operator_org_id, plane: :tenant}` (`Samen.Web.Operator.scope/1`) | operator org's OWN rows | `:tenant` → **CLEAR** (own-org PII, no grant) |
| (2) A tenant's DOWNSTREAM end-customers | `%{org_id: tenant_org_id, plane: :operator, impersonation: %{…}}` (ADR-009) | the target tenant's rows | `:operator` + impersonated → `%Masked{}` → **`••••`** |

Separated ALSO by a mount boundary (operator namespace vs vertical namespace) — belt and
suspenders. `Org` carries no PII, so the account grouping is a trusted non-PII read; ALL
PII-bearing joins (Users/Customers/Agents/Messages) go through the `PiiResolution` chokepoint on
the tenant plane.

### Identity-line test result — `test/samen/web/operator_identity_line_test.exs` — 6/6 GREEN

- **CLEAR side (population 1):** operator `/operator/accounts` renders the tenant-admin
  `Reginald Adminclear` + email **in the clear**; no `••••` on the operator's own plane. ✓
- **MASKED side (population 2):** on the SAME seeded data, the same account's downstream CRM via
  the ADR-009 impersonation mount renders the tenant END-customer `Aurelia Sentinelson` as
  `••••`; the plaintext name/email/phone are **absent**. ✓
- **RED PATH:** the impersonation render never leaks a `vt_`/`pii_` vault token. ✓
- **CROSS-LEAK:** the operator accounts view surfaces the account (the tenant org) but NEVER the
  tenant's downstream contacts. ✓
- **CROSS-MOUNT REFUSAL:** the operator-org tenant-plane actor reading the VERTICAL namespace
  returns **zero rows** (the seeded end-customer exists on the tenant's own scope — proving the
  empty result is an `OrgScope` refusal, not an empty DB). ✓

Additional operator tests (all green):
- `operator_accounts_render_test.exs` (5) — accounts = tenant orgs, primary contact clear,
  MRR/seats/health joins, Open-account back-reference.
- `operator_billing_render_test.exs` (4) — per-tenant subs (customer clear), platform-MRR sum,
  dunning/past-due, **§4b.1 reconciliation** (operator-plane MRR == token-blind aggregate MRR on
  the unsuppressed seed).
- `operator_desk_render_test.exs` (4) — tenant-filed tickets, requester (tenant-admin) clear,
  SaaS agent assignee clear, SLA/priority.
- `operator_context_test.exs` (6) — org-id resolution, the operator-org tenant-plane scope, the
  impersonation-plane crossing, the `samen_operator_routes` macro (aggregate off by default /
  on via `include_aggregate: true`).

---

## Booted driftwood self-verify (PORT=4033, `mix driftwood.seed`)

- `/operator/accounts` — Blue Ridge Logistics + Summit Freight Partners as accounts; primary
  contacts **Marlene Okafor** / **Desmond Vlahos** + emails **in the clear**; health pills;
  Platform MRR **$5500.00** (sum of both active subscriptions). Screenshot: `/tmp/operator_accounts.png`.
- `/operator/billing` — Platform MRR $5500, subscriptions (customer clear, Growth plan),
  dunning/past-due invoices surfaced.
- `/operator/desk` — tickets tenants filed ("Cannot invite a second admin", "Invoice PDF export
  failing"); requester = tenant-admin **clear**; assignee = SaaS agent **Priya Nakamura** clear;
  priority/SLA. Vault-token leak scan: **0**.

---

## Constraints honored

1. **NEVER ran git.** ✓
2. **samen_core code UNTOUCHED (842 green).** ✓ Only abbrev-registry rows appended (42:
   21 `Samen.WebTest.Operator.*` + 21 `Driftwood.Operator.*`), the sanctioned data append.
3. **Framework-level in samen_web; the vertical mounts it.** ✓ All new logic is
   `Samen.Web.Operator.*` + the `samen_operator_routes` macro + the one-line `:operator`
   `scope_kind` union append. Driftwood gains one domain + one migration + one seed + one
   router line + config.
4. **Masking by construction via `PiiResolution` — no plaintext bypass.** ✓ Population (1) clear
   is the tenant-plane resolver branch (reused verbatim); population (2) masked is the
   operator/impersonation branch (reused verbatim). `Samen.Web.Operator.Reads` never reveals,
   never unwraps a `%Masked{}`.
5. **`--warnings-as-errors` clean; all suites + `ci.sh` green before + after.** ✓ Root
   `ci.sh` exits 0.

## Files

- `samen_web/lib/samen/web/operator.ex`, `operator/reads.ex`, `operator/live.ex`,
  `operator/accounts_live.ex`, `operator/platform_billing_live.ex`, `operator/desk_live.ex`
- `samen_web/lib/samen/web/router.ex` (`samen_operator_routes/2`), `mount.ex` (`:operator` kind)
- `samen_web/test/support/{operator.ex,operator_seeds.ex}`, `data_case.ex` (`build_operator_mount/2`)
- `samen_web/priv/repo/migrations/20260708140000_mount_operator_scopes.exs`
- `samen_web/test/samen/web/operator_{identity_line,accounts_render,billing_render,desk_render,context}_test.exs`
- `driftwood/lib/driftwood/{operator.ex,operator_seeds.ex}`, `lib/driftwood_web/router.ex`,
  `config/config.exs`, `lib/driftwood/seeds.ex`, `schema.dict.json`,
  `priv/repo/migrations/20260708140000_mount_operator_scopes.exs`
- `samen_core/priv/abbrev_registry.json` (append-only rows; NO code change)
