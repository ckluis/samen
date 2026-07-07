# Driftwood dogfood runbook (T5.3)

A human-followable walkthrough of both planes of the running Driftwood app on
**localhost + local Postgres**. It drives the same story the scripted test
(`test/dogfood_walkthrough_test.exs`) asserts: create a brokerage tenant → add
carriers/drivers/loads → dispatch → settle → operator impersonates masked → reveal one
driver → token-blind aggregate view.

> **Deploy seam (OPERATOR TODO).** The vision doc's target is Fly.io + Neon (Postgres
> branch with PITR) + AWS KMS/S3. NONE of that runs here — this runbook runs the app on
> `http://localhost:4010` against local Postgres (role `clank`, no password) with a
> file-backed KMS key store (`priv/dev_keystore`). A real deploy: injects
> `secret_key_base` + DB creds from the environment, points `DATABASE_URL` at a Neon
> branch, swaps `Samen.Kms.FileBacked` for AWS KMS, fronts Bandit with TLS, and derives
> the tenant org + operator identity from an authenticated session instead of the
> query-param convenience used below. Every one of those is a named seam, not a faked
> pass.

## 0. Prerequisites

- Elixir 1.20 / OTP 29, local Postgres on `localhost:5432` (role `clank`, no password).
- From `driftwood/`:

```bash
mix deps.get
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ecto.migrate
```

## 1. Seed the fleet + open an impersonation session

The seed builds TWO brokerage tenant orgs (so the cross-tenant aggregate has >1 tenant
per cohort), each with a carrier + shipper, a compliant driver + an expired-medical-card
driver (both with vaulted CDLs), loads, a dispatch of the compliant driver, and a
settlement — then rebuilds the tenant rollup + the cross-tenant aggregate. It also opens
a masked impersonation session for operator `op-dogfood-1` over org A.

Create `/tmp/dw_seed.exs`:

```elixir
alias Samen.OperatorPlane.Actor
alias Samen.Impersonation

result = Driftwood.DogfoodScenario.build_fleet()
[a, b] = result.orgs
op = Actor.new("op-dogfood-1", :operator_support)
{:ok, session} = Impersonation.open(op, a.org_id, "ticket #4210: carrier reports settlement discrepancy")

IO.puts("ORG_A=#{a.org_id}")
IO.puts("ORG_B=#{b.org_id}")
IO.puts("COMPLIANT_DRIVER=#{a.compliant_driver_id}")
IO.puts("BLOCKED_DRIVER=#{a.blocked_driver_id}")
IO.puts("OPERATOR=#{op.id}")
```

```bash
MIX_ENV=dev mix run /tmp/dw_seed.exs
```

Copy the printed `ORG_A`, `COMPLIANT_DRIVER`, `BLOCKED_DRIVER`, `OPERATOR` values.

## 2. Boot the server

```bash
MIX_ENV=dev PORT=4010 mix run --no-halt
# => Running DriftwoodWeb.Endpoint with Bandit at 127.0.0.1:4010
```

Liveness: `curl http://localhost:4010/healthz` → `ok`.

## 3. TENANT plane — the broker console (`/broker`)

Substitute `$ORG_A` from step 1.

- **Dashboard (rollup-backed, never raw scans):**
  `http://localhost:4010/broker?panel=dashboard&org=$ORG_A`
  Loads-by-status + a settlement summary read from the `dbs_broker_summary` rollup.
- **Load board:** `?panel=loads` — load name / lane / value / status.
- **Driver roster (FMCSA status):** `?panel=roster` — the compliant driver shows
  `FMCSA: OK` with an enabled **Dispatch** button; the expired-medical driver shows
  `BLOCKED: medical card expired` with a **disabled** Dispatch button. Driver name +
  CDL render `••••` (the broker's own scope carries no reveal grant here).
- **Settlements (reshaped money):** `?panel=settlements` — linehaul − advances −
  factoring fee − claims = **net payable**, with carryover. For the seeded settlement:
  `$4800 − $500 − $156 − $50 = $4494` (gross = linehaul + fuel + accessorial = $5200;
  factoring = trunc($5200 × 300bps) = $156).

## 4. OPERATOR plane — masked impersonation (`/operator/impersonate`)

```
http://localhost:4010/operator/impersonate?operator_id=$OPERATOR&org_id=$ORG_A
```

- The accountability banner shows the reason + expiry of the impersonation session.
- The REAL driver roster + load board render — **driver name and CDL are `••••`**,
  because the impersonation scope carries no reveal grant. The FMCSA badge is visible
  (non-PII), so the operator can support the tenant without seeing driver PII.
- **Red-path checks (do these):**
  - View source; confirm no plaintext CDL (`CDL-...`) or driver name appears, only `••••`.
  - Open the page for org A with an operator that has NO session (`operator_id=nobody`):
    the page renders **"access denied"** and no driver rows.

## 5. Reveal ONE driver end-to-end (T1.6 second-party grant)

Clicking **Reveal CDL** with no grant denies (`••••` stays). To unmask one driver, a
DISTINCT party must approve a grant. Create `/tmp/dw_reveal.exs` (substitute ids):

```elixir
alias Samen.Reveal.Grants
{:ok, req} = Grants.request(%{subject_id: "$COMPLIANT_DRIVER", requestor_id: "$OPERATOR",
                              reason: "ticket #4210 — verify CDL against carrier packet"})
{:ok, _}   = Grants.approve(req, %{granted_by: "compliance-lead-9"})   # DISTINCT party
{:ok, pt}  = Driftwood.OperatorReveal.reveal_cdl("$OPERATOR", "$COMPLIANT_DRIVER")
IO.puts("REVEALED=#{pt}")
```

```bash
MIX_ENV=dev PORT=4099 mix run /tmp/dw_reveal.exs   # alt PORT: server is on 4010
```

Self-approval (`granted_by == requestor_id`) is refused with `{:error, :self_approval}`.
Only that ONE driver's CDL is unmasked; every other driver stays `••••`.

## 6. OPERATOR plane — token-blind cross-tenant aggregate (`/operator/aggregate`)

```
http://localhost:4010/operator/aggregate
```

- **Load volume by lane** across ALL brokerages (lane `TX->CA` spans both seeded orgs,
  `tenants: 2`) and **MRR by tier** (`growth` tier, total MRR = sum across both orgs).
- This plane reads ONLY the token-blind aggregate domain (`Driftwood.Aggregate`) with the
  singleton aggregate actor — **no PII, no impersonation, no reveal**. A cohort below the
  k-anonymity floor renders `⊘` (suppressed). Confirm no `••••`, no `CDL-`, no name.

## 7. The scripted version (assertions)

Everything above is asserted end-to-end in
`test/dogfood_walkthrough_test.exs` (create → dispatch → settle → rollup → dashboard →
impersonate masked → reveal one → aggregate). The adversarial red-path matrix against the
live render path is in `test/web_red_paths_test.exs`; the anti-tautology probe on the
masked-render path is documented in `test/web_anti_tautology_probe.md`. Run the whole
gate with `bash ci.sh` (18 steps: 16 verifiers + default suite + adversarial suite).
```
