# ADR-030 — Responsive: a kit-level CSS pass (one stylesheet, one shell component) so every vertical becomes mobile-usable at once

- **Status:** Accepted (design; WS-E phase E6 implements).
- **Date:** 2026-07-16
- **Task:** WS-E / G20 — `samen_ui.css` has `@media` count = 0; the `.app` grid is a fixed `252px 1fr` two-pane desktop layout; there are zero skeleton/loading states. Make the product mobile-usable, framework-first — one kit-level pass fixes every vertical at once.
- **Deciders:** opus (WS-E design), grounded in `docs/gap-discovery/end-user.md` G5 + G12, the fact that the kit (`Samen.UI` `app_shell`/`sidebar`/`data_table`) is inherited by every vertical, and the mobile-real verticals (Driftwood dispatchers, vet-clinic front desk on tablets).

---

## 1 · Context

The entire fleet's layout lives in ONE stylesheet (`samen_web/priv/static/assets/samen_ui.css`, 500 lines) and a handful of kit components (`app_shell/1`, `sidebar/1`, `topbar/1`, `data_table/1`). There are zero media queries — the `.app` grid is `grid-template-columns: 252px 1fr`, which on a phone renders a fixed sidebar squeezing the main pane to nothing. Because the kit is inherited, this is the rare gap where a SINGLE well-scoped change fixes every vertical simultaneously — the highest-leverage cosmetic fix in the fleet. The risk is scope creep: a "responsive pass" can balloon into a per-page redesign. This ADR bounds it.

## 2 · Decision

**Three load-bearing decisions:**

1. **The responsive pass is CSS-and-kit-only — no per-page LiveView changes.** It lands entirely in `samen_ui.css` (media queries) + at most the shared shell/sidebar/data_table components. It does NOT touch vertical LiveViews or per-page markup. This bounds the change to a reviewable, fleet-wide surface and honors the "fix the kit, every vertical inherits" thesis. Any page that needs bespoke responsive treatment beyond what the kit provides is an explicit follow-on, not this pass.

2. **Two breakpoints, mobile-first collapse: the sidebar becomes a toggle drawer; tables become card-stacks or horizontal-scroll.** At a tablet/phone breakpoint the `.app` grid collapses to a single column, the sidebar moves off-canvas behind a hamburger toggle (a small kit affordance — a checkbox/`phx-click` toggle, no new JS framework), the topbar gains the toggle, and `data_table` rows either horizontally scroll within a bounded container or restack as label:value cards (the kit `data_table` gets a responsive variant). The masking invariant is untouched — a `%Masked{}` value still renders `••••` at every breakpoint (CSS changes layout, never value resolution).

3. **Skeleton/loading states are added as kit primitives, scoped to the same pass.** G12's perceived-speed hole (no skeletons, no `assign_async`) is addressed at the kit level ONLY: a `Samen.UI.skeleton/1` component + CSS keyframes, and converting the kit `list_view`/strips to render a skeleton while loading is a bounded kit change. Full `stream`/`assign_async` conversion of every vertical list is explicitly deferred (it's per-page and belongs to a perf follow-on) — WS-E ships the skeleton PRIMITIVE and wires it into the framework list surfaces, not a fleet-wide async rewrite.

## 3 · Rationale

- **Kit-and-CSS-only** is what makes this cheap and safe: one diff, reviewed once, fixes the whole fleet, with zero risk to vertical logic or the masking spine.
- **Two breakpoints + drawer + table-restack** is the minimum that makes the product genuinely usable on the mobile-real verticals (freight dispatch, vet front-desk tablet) without a redesign.
- **Skeleton primitive, not async rewrite** bounds the G12 overlap: WS-E delivers the reusable primitive and wires it into the framework surfaces; the per-page `assign_async`/`stream` conversion is a separate, page-by-page effort that would balloon this workstream (decompose rule).

## 4 · Consequences

**Positive** — the entire fleet becomes mobile-usable from one kit-level diff; a reusable skeleton primitive lands in the kit; the masking invariant is provably untouched (CSS-only); mobile-real verticals become field-usable.

**Negative / accepted** — not a per-page mobile redesign (some dense pages remain scroll-heavy on phones — honest). Full `stream`/`assign_async` perf conversion is deferred (skeleton primitive ships; fleet-wide async rewrite does not). No a11y pass (G25/end-user.md G11 — separate P2). Two breakpoints, not a fully fluid system.

**Neutral** — media queries added to `samen_ui.css`; a `data_table` responsive variant + `skeleton/1` component + a sidebar-drawer toggle affordance in the shell; no new resources/routes/abbrevs.

## 5 · Red paths / verification

- **RP-RE-1 (AC-G20-2) masking survives responsive:** a `%Masked{}` value renders `••••` at every breakpoint; the responsive CSS/kit change never alters value resolution. A test (or design-review screenshot diff) at mobile + desktop widths confirms masked cells stay masked. Any CSS/kit change that touches PiiResolution FAILS review (structural: the pass is CSS-only, asserted by diff scope).
- **RP-RE-2 (AC-G20-3) fleet-wide inheritance:** pawchart + driftwood + demo render responsively through the SAME kit change with zero per-vertical CSS. A visual/DOM check at two widths on each vertical confirms the collapse works without vertical edits.
- **RP-RE-3 (AC-G20-4) scope guard:** the WS-E responsive diff touches only `samen_ui.css` + the named kit components — no vertical LiveView. A structural check on the diff's file list confirms the bound (the decompose guarantee, enforced).
