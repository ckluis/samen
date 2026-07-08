# CRM UI — Inherited Module Pages

**Task:** Build the CRM module pages as LiveViews using DriftwoodWeb.UIKit, wired to the real Driftwood.Crm resources.

---

## Routes Added

Three new LiveView routes in `DriftwoodWeb.Router`:

| Route | LiveView | Description |
|-------|----------|-------------|
| `/crm/companies` | `DriftwoodWeb.CrmCompaniesLive` | Companies data_table + 4 metric cards |
| `/crm/contacts` | `DriftwoodWeb.CrmContactsLive` | Contacts data_table — PII via PiiResolution |
| `/crm/pipeline` | `DriftwoodWeb.CrmPipelineLive` | Opportunities grouped by pipeline stage |

A "CRM" nav group was added to the sidebar in each LiveView (`nav_group label="CRM"`), linking Companies / Contacts / Pipeline.

---

## Files Created

- `lib/driftwood/crm_reads.ex` — shared CRM read layer (`companies/1`, `contacts/1`, `pipeline/1`, `metrics/1`)
- `lib/driftwood_web/crm_companies_live.ex` — `/crm/companies` LiveView
- `lib/driftwood_web/crm_contacts_live.ex` — `/crm/contacts` LiveView (PII-bearing)
- `lib/driftwood_web/crm_pipeline_live.ex` — `/crm/pipeline` LiveView
- `test/crm_ui_test.exs` — 7 tests covering routes + masking invariant

---

## PII / Plane Threading

`Driftwood.Crm.Person` carries three vault-routed PII fields: `full_name`, `emails`, `phones`.

`CrmReads.contacts/1` calls `Samen.Api.PiiResolution.resolve/4` after the Ash read — the same shared resolver used by `Driftwood.Reads.driver_roster/1`. The plane key on the actor determines the output:

- `plane: :tenant` → plaintext (the org reads its own contacts in the clear, tenant-as-owner rule)
- `plane: :operator` + `:impersonation` marker → `%Masked{}` (→ ••••, present-but-masked)
- no plane / unknown → `%Masked{}` (fail-safe default)

The `CrmContactsLive` render helpers (`render_full_name/2`, `render_email/1`, `render_phone/1`) return a `%Masked{}` value UNTOUCHED when they encounter one — they never unwrap a vault token or call `Samen.Vault.reveal/3`. The UIKit `data_table` is a dumb renderer; `Phoenix.HTML.Safe` on `%Masked{}` emits `••••`.

`operator_scope/1` is exported from `CrmContactsLive` for test use, exposing the impersonation actor shape (`plane: :operator` + `impersonation: %{session_id: …}`).

---

## Masking Test Result

**Test file:** `test/crm_ui_test.exs`

```
Result: 7 passed
```

### Tenant plane — contacts in the clear

```elixir
tenant_scope = DriftwoodWeb.CrmContactsLive.crm_scope(org_id)   # plane: :tenant
contacts = CrmReads.contacts(tenant_scope)
html = render(DriftwoodWeb.CrmContactsLive, %{no_org: false, org_id: org_id, contacts: contacts, flash: %{}})
assert html =~ "Dana"    # seeded first name — PRESENT in the clear
refute html =~ "vt_"     # vault token never leaks
```

**Result: PASS** — the tenant org reads its 12 seeded contacts with `full_name` decrypted to plaintext through the single vault chokepoint.

### Operator/impersonation plane — contacts masked (••••)

```elixir
operator_scope = DriftwoodWeb.CrmContactsLive.operator_scope(org_id)   # plane: :operator + impersonation
contacts = CrmReads.contacts(operator_scope)
html = render(DriftwoodWeb.CrmContactsLive, %{no_org: false, org_id: org_id, contacts: contacts, flash: %{}})
assert html =~ "••••"         # mask IS present
refute html =~ "Whitfield"    # last name NOT present in plaintext
refute html =~ "dana.whitfield"  # email NOT present
refute html =~ "vt_"          # vault token never leaks
```

**Result: PASS** — the operator/impersonation scope sees the same 12 rows (org-scoped, real data shape) with `full_name`/`emails`/`phones` rendered as `••••` by construction.

### UIKit masking invariant (no DB needed)

```elixir
masked_name = Samen.Masked.new("vault:test-tok-name", :full_name)
fake_contact = %{id: ..., full_name: masked_name, emails: masked_emails, phones: masked_phones, ...}
html = render(DriftwoodWeb.CrmContactsLive, %{contacts: [fake_contact], ...})
assert html =~ "••••"
refute html =~ "vault:test-tok-name"   # raw token never leaks
```

**Result: PASS** — the LiveView render path never inspects or leaks a `%Masked{}` value.

---

## Gate + Suite Status

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | PASSED |
| `schema.dict.json` drift (27 tables, no new resources) | PASSED |
| `samen.verify.catalog_parity` | PASSED |
| `samen.verify.prefixes` | PASSED |
| `samen.verify.pii_reads` | PASSED (2 laundered-flow advisories, not failures) |
| `samen.verify.pii_classify` | PASSED |
| `samen.verify.no_plaintext_pii` | PASSED |
| `samen.verify.no_pii_columns` | PASSED |
| `samen.verify.same_org_fk` | PASSED |
| `samen.verify.api_contract --version v1` | PASSED |
| `samen.verify.tnt_catalog` | PASSED |
| `samen.verify.tnt_boundary` | PASSED |
| `samen.verify.aggregate_privacy` | PASSED |
| `samen.verify.never_read_current` | PASSED (CDC tier off, vacuously satisfied) |
| `mix test --warnings-as-errors` | **80 passed** (73 pre-existing + 7 new CRM UI) |
| `mix test --only adversarial` | **4 passed** |

No new migrations: the CRM resources (`Driftwood.Crm.*`) were already migrated by the existing schema — this task added only LiveViews, a reads module, routes, and tests.
