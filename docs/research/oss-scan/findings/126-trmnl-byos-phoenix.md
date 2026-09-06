---
project: TRMNL BYOS Phoenix
url: https://github.com/usetrmnl/byos_phoenix
category: Media and Personal
relevance: low
verdict: A single-tenant Elixir/Phoenix hobby server for e-paper display devices — no multi-tenancy, no Ash, no PII/billing/auth depth, nothing samen's foundry needs.
---

## What the project is

`byos_phoenix` ("Bring Your Own Server") is a small self-hosted Elixir/Phoenix application that lets owners of TRMNL e-ink display devices (official hardware or DIY builds) run their own backend instead of using TRMNL's cloud service. Core mechanics:

- Plain Phoenix + Ecto app (no Ash, no umbrella/monorepo structure) — 28 commits, 39 stars, MIT licensed, single maintainer-scale project.
- Device registry/inventory schema; devices poll a REST endpoint for their next screen.
- Screens are rendered as HTML, rasterized via headless-browser screenshot (Puppeteer) and converted to 1-bit bitmaps (ImageMagick) for the e-paper hardware.
- Playlist-style rotation across screens with a GenServer driving periodic re-render (~every 15 min).
- Ships example/plugin-style screen templates (e.g. "HelloWorld").
- Deployment model is explicitly single-tenant/self-hosted: one operator runs one instance for their own device(s), with local Puppeteer/ImageMagick installs as a deploy dependency.

There is no multi-tenancy, no user-facing SaaS billing/auth/org model, no PII handling, no Ash resources, and no verification/gate discipline — it's a narrow, single-purpose hardware-companion service.

## What samen could adopt

Nothing rises above marginal-curiosity level; the domains barely overlap. The two candidates below are listed for completeness but neither clears the bar samen already holds itself to.

1. **What**: The HTML→headless-browser-screenshot→raster pipeline as a reference pattern for "render a UI surface to a static image" (e.g. if samen ever needed PDF/image exports of dashboards or reports).
   **Why it fits samen**: samen's `samen_web/lib/samen/web/csv` and export chokepoints already handle structured data egress (CSV with formula-injection neutralization); an analogous "image/PDF export chokepoint" isn't currently in samen's scope, so this is speculative fit at best.
   **Effort**: S (if ever needed) — but not a current samen gap per the digest.

2. **What**: GenServer-driven periodic re-render loop.
   **Why it fits samen**: samen already solved recurring/scheduled work with `oban` + `ash_oban` (durable, DB-backed, multi-node-safe per ADR-040/L4 proofs) — strictly more robust than a bare GenServer timer for a multi-tenant SaaS substrate. This is a downgrade, not an upgrade, for samen's needs.
   **Effort**: N/A — not worth adopting.

## What to ignore and why

- **Entire device/hardware domain model** (device inventory, e-paper bitmap conversion, playlist rotation) — irrelevant to a B2B SaaS foundry; samen has no IoT/hardware surface and no roadmap item suggesting one.
- **Single-tenant architecture** — directly contradicts samen's two-plane, multi-tenant-by-construction design (ADR-009/010); nothing here demonstrates multi-tenant patterns to borrow.
- **Plain Ecto/Phoenix without Ash** — samen deliberately builds on Ash for declared types, policies, and code-generation leverage (ADR-004/036/037); this project has no Ash usage to compare against.
- **No PII/vault/masking/audit concerns** — the project touches no personal data beyond device ownership, so there's no masking, reveal-grant, or crypto-shred pattern to compare.
- **No billing, no verification/CI discipline, no generator tooling** — 28-commit hobby project scale; nothing resembling samen's sabotage harness, gate reports, or generative-proof CI.

Overall: correctly triaged as low relevance. Recommend no further evaluation depth.
