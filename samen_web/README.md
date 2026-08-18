# samen_web

The Samen foundry's **framework UI library** (ADR-009). It promotes the inherited-80% product
UI — the component kit + the CRM/Billing/Support LiveViews + the two-plane masking — out of any
one vertical and into a shared path-dep lib every vertical mounts, not copies.

It depends on `phoenix_live_view` / `phoenix_html` / `phoenix` (the web deps) plus `samen_core`
(the pure kernel, path dep). `samen_core` gains no web dep — the web dep lives here, so the
kernel's test suite + verifier gate stay green by construction.

## What it ships

- **`Samen.UI`** — the shared function-component kit + `samen_ui.css` (ADR-008/009).
- **`Samen.Web.{Mount, Plane, Router}`** — the host-parameterization contract and the two-plane
  (`:tenant` / `:operator`) abstraction that drives PII masking by construction. See
  [`docs/concepts/two-plane-masking.md`](../docs/concepts/two-plane-masking.md) for the
  reader-facing explainer, and [ADR-009](../docs/adr/ADR-009-samen-web.md) /
  [ADR-010](../docs/adr/ADR-010-operator-plane.md) for the full specs.
- **`Samen.Web.{CRM, Billing, Support}`** — the inherited product surfaces every vertical mounts
  at ~5 lines via `samen_module_routes/3`.
- **`Samen.Web.Operator.*`** — the operator/control-plane workspace (accounts, platform
  billing, the SaaS's own help desk) via `samen_operator_routes/2`.
- The mountable end-user surfaces: files, search (⌘K), CSV import/export, self-serve settings,
  and cross-plane chat.

In `:test` it ships its own test-support host (`Samen.WebTest.{Repo, Crm, Billing, Support,
Operator}`) so the render tests exercise real materialized scope resources with no dependency
on any vertical — the two-plane masking guarantee is proven framework-local.

See the root [README.md](../README.md) and [docs/README.md](../docs/README.md) for the rest of
the foundry.
