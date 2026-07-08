# Support UI Task Report

## Status: GREEN

All 20 CI gate steps PASSED. All 105 tests pass (14 new Support UI tests + 91 pre-existing).

---

## Routes Added

| Route | LiveView | Description |
|-------|----------|-------------|
| `/support` | `DriftwoodWeb.SupportLive` | Ticket inbox: data_table + metric cards |
| `/support/tickets/:id` | `DriftwoodWeb.SupportTicketLive` | Conversation thread + Details tab |

Both routes added to `DriftwoodWeb.Router` in the browser scope, replacing the dead "Support" stub link.

---

## Files Created

- `lib/driftwood/support_reads.ex` — read layer for Support resources (tickets, conversations, messages, agents, csats, metrics). Mirrors `BillingReads`/`CrmReads` pattern. All PII goes through `Samen.Api.PiiResolution.resolve/4`.
- `lib/driftwood_web/support_live.ex` — `/support` inbox LiveView using `DriftwoodWeb.UIKit` (app_shell, sidebar, topbar, data_table, pill, metric).
- `lib/driftwood_web/support_ticket_live.ex` — `/support/tickets/:id` detail LiveView with Conversation/Details tabs. Uses all UIKit components.
- `test/support_ui_test.exs` — 14 tests covering routes, pill variants, PII masking, and cross-org isolation.

---

## PII Masking

### Surfaces masked per plane

| Field | Resource | Vault | Tenant plane | Operator plane |
|-------|----------|-------|-------------|----------------|
| `full_name` | `Support.Agent` | `:pii_name` (composite) | plaintext | `%Masked{}` → •••• |
| `email` | `Support.Agent` | `:pii_email` (scalar) | plaintext | `%Masked{}` → •••• |
| `body` | `Support.Message` | `:pii_body` (scalar) | plaintext | `%Masked{}` → •••• |

### Masking invariant

- `SupportReads` calls `Samen.Api.PiiResolution.resolve/4` after every Ash read for PII resources. Never calls `Samen.Vault.reveal/3`.
- `SupportLive` and `SupportTicketLive` render whatever value the resolver returns. Never unwrap `%Masked{}`. Never pattern-match a vault token.
- A `%Masked{}` renders `••••` via `Phoenix.HTML.Safe` — the UIKit `data_table` and inline HEEx cells are dumb renderers.

### Test results (masking assertions)

- `TENANT plane: agent handle + name renders IN THE CLEAR` — PASSED. "claims-desk" agent handle visible; no vault tokens.
- `OPERATOR/impersonation plane: agent PII renders ••••` — PASSED. "Marchetti" and "sofia.marchetti" absent; `••••` present.
- `OPERATOR plane: message body renders ••••` — PASSED. `%Masked{}` body confirmed on operator scope; "disputing the charge" absent.
- Synthetic `%Masked{}` UIKit invariant tests for both agent name and message body — PASSED.

---

## CI Gate

All 20/20 steps passed:
- `mix compile --warnings-as-errors` — clean
- schema.dict.json drift — no change (Support UI adds no new DB tables/columns)
- All verifiers (catalog_parity, prefixes, pii_reads, pii_classify, no_plaintext_pii, migrations, sink_schema, metric_labels, vault_declared_parity, tnt_catalog, tnt_boundary, api_contract v1, same_org_fk, no_pii_columns, aggregate_privacy, never_read_current) — all PASSED
- `mix test` (105 tests, 1 property) — PASSED
- `mix test --only adversarial` — PASSED
- T5.4 crypto-shred game-day — PASSED
- T5.5 PITR game-day + red-path probe — PASSED
