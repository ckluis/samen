# ADR-008: Samen product-UI kit (function components + shared CSS)

Status: Accepted
Date: 2026-07-08
Supersedes: none
Related: ADR-001 (key hierarchy / `%Masked{}`), the T5.3 web planes
(`DriftwoodWeb.{BrokerLive, OperatorImpersonationLive, OperatorDashboardLive}`)

## Context

The three approved product-UI mockups —

  * `_mockup-samen-ui.html`        — operator masked impersonation (driver roster, `••••` PII)
  * `_mockup-samen-aggregate.html` — token-blind aggregate / MRR (k-anon suppression)
  * `_mockup-samen-broker.html`    — tenant broker dashboard (data in the clear + settlement reshape)

share one visual language: a `:root` token palette (`canvas / panel / card / ink /
muted / line` + brand/red/amber/green/violet washes), Inter + JetBrains Mono, a
sidebar + main app shell, a data table, `.pill` status badges (ok/warn/bad/info/mut),
`.prog` bars, `.metric` cards, a `.mask-bar` impersonation banner, a `.tb-bar`
token-blind banner, and a `.settle` settlement-reshape card.

Today each Driftwood LiveView hand-rolls unstyled tables. We want the mockup look to be
a REAL, reusable kit so any vertical (driftwood / demo / pawchart) inherits it, rather
than each vertical re-implementing the CSS. The kit must:

  * ship the tokens as a single CSS asset (`samen_ui.css`);
  * expose HEEx function components (app shell, sidebar nav group/item, topbar, button,
    tabs, data table, pill, progress, metric, mask-bar, token-blind bar) that take
    assigns, not hardcoded content;
  * NOT introduce any way to render plaintext PII that bypasses masking — a cell/pill
    renders whatever value it is given; a `%Masked{}` shows `••••`.

## Decision

**Where the kit lives: driftwood-local now (`DriftwoodWeb.UIKit` + a static CSS asset),
documented as extractable to a shared `samen_ui` path-dep lib once a second vertical
adopts it (Rule-of-Three).**

Concretely:

  * `driftwood/priv/static/assets/samen_ui.css` — the mockups' `:root` tokens + component
    classes, cleaned and organized. Served at `/assets/samen_ui.css` by a scoped
    `Plug.Static` (`only: ["assets"]`) added to `DriftwoodWeb.Endpoint`, and linked from
    the root layout so every LiveView plane picks it up.
  * `driftwood/lib/driftwood_web/ui_kit.ex` — `DriftwoodWeb.UIKit`, a `Phoenix.Component`
    module with one function component per kit element. Components take assigns + slots;
    nothing imports a Driftwood domain module.
  * `driftwood/lib/driftwood_web/ui_kit_live.ex` — `DriftwoodWeb.UIKitLive`, the `/ui-kit`
    preview page (a living catalog exercising every component, including masked cells).

### The three homes considered

**(i) Add the kit to `samen_core` behind an optional `phoenix_live_view` /
`phoenix_component` dep** — truest to "part of the framework." REJECTED for now.
`samen_core` is the pure substrate kernel (self-qualifying storage, machine catalog,
PII vault). It deliberately depends on `phoenix_html` ONLY for the `%Masked{}`
`Phoenix.HTML.Safe` impl, and carries an 842-test suite + a standalone verifier gate
(catalog_parity / prefixes / pii_reads / pii_classify / no_plaintext_pii / migrations /
… — see `demo/ci.sh`, `driftwood/ci.sh`). Dragging `phoenix_live_view` +
`phoenix_component` into the kernel adds a web dependency to a data/security substrate,
enlarges its compile surface, and risks the gate that must stay untouched. The kernel
should not grow a view layer to host a design system that only two web verticals use.

**(ii) A small shared path-dep lib (`samen_ui`) now** — the eventual home. REJECTED for
timing, not direction. With exactly one live consumer today (driftwood), standing up a
new mix project + its own `ci.sh` wiring is more ceremony than the kit has earned while
it is still stabilizing against the mockups. Premature extraction would freeze an API we
are still shaping.

**(iii) Driftwood-local now, extractable — Rule-of-Three.** ACCEPTED. Driftwood already
depends on `phoenix`, `phoenix_live_view`, `phoenix_html` — the kit needs no new deps.
The `DriftwoodWeb.UIKit` namespace + the static asset are self-contained (no Driftwood
domain coupling), so the extraction to `samen_ui` is a file move + a namespace rename
when the second consumer (demo or pawchart) actually adopts it. That is exactly the
Rule-of-Three posture: build it once where it is needed, extract on the third use.

### Honest dep-boundary statement

The kit is NOT "in samen_core" and does not claim to be. It is a Driftwood-web
component library that consumes samen_core's `%Masked{}` value type through the already-
present `Phoenix.HTML.Safe` protocol — the same seam the existing LiveViews use. The
kernel's dep list, test suite, and verifier gate are unchanged by this ADR. When
extraction happens, `samen_ui` will depend on `phoenix_live_view` + `phoenix_html` +
`samen_core` (for `%Masked{}`), and the verticals will swap their local reference for a
path dep — samen_core still never grows a view layer.

## The masking invariant (load-bearing)

The kit introduces NO plaintext-PII path. Every component is a dumb renderer:

  * `pill/1`, `data_table/1` cells, `progress/1` labels, `metric/1` values — all render
    whatever value the caller hands them via `{@value}` / the inner block.
  * If that value is a `%Samen.Masked{}`, HEEx renders it through
    `Samen.Masked`'s `Phoenix.HTML.Safe` impl (ADR-001), which emits `••••`.
  * The kit never calls `Samen.Vault.reveal/3`, never pattern-matches a token out of a
    `%Masked{}`, and has no "show plaintext" branch. Plaintext reaches a cell ONLY if the
    caller already resolved it through `Samen.Api.PiiResolution` / `Samen.Reveal` (the
    single vault chokepoint) — exactly as `BrokerLive` (tenant plane, own-org clear) and
    `OperatorImpersonationLive` (operator plane, `••••`) do today.

The `/ui-kit` preview renders a real `%Masked{}` in both a name cell and a CDL cell to
make the guarantee visible: the page shows `••••`, and the vault token never appears in
the DOM. `test/ui_kit_test.exs` asserts this (the mask renders; the token
`"vault:preview-token"` is absent) plus a direct-injection test that hands a `%Masked{}`
straight to `pill/1` / a `data_table` cell / `progress/1` and asserts `••••`, never the
token.

## Component surface

`DriftwoodWeb.UIKit` (all take assigns/slots):

| Component            | Renders                                                        |
|---------------------|---------------------------------------------------------------|
| `app_shell/1`       | `.app` grid: `:sidebar` slot + `<main class="main">` inner    |
| `sidebar/1`         | `.side` w/ workspace header, `:search` / `:footer` slots      |
| `nav_group/1`       | `.grp` label + `.nav` wrapping its `nav_item`s                |
| `nav_item/1`        | one `.nav a` link (`:active` → `.on`, `count`/`dot`, `:icon`) |
| `topbar/1`          | `.top` breadcrumb (`crumbs` list) + `<h1>` + `:actions` slot  |
| `button/1`          | `.btn` (default / `variant="primary"`), `:icon`, `:rest`      |
| `tabs/1` + `tab/1`  | `.tabs` underline bar (`:active` → `.on`)                     |
| `data_table/1`      | `.card > table` with `:head` slot + inner `<tbody>` rows      |
| `pill/1`            | `.pill.<variant>` badge (ok/warn/bad/info/mut)                |
| `progress/1`        | `.prog` bar (`value` 0-100, `label`, `color`)                 |
| `metric/1`          | `.metric` card (`label`/`value`/`delta`/`sub`/`spark`/`:icon`)|
| `mask_bar/1`        | `.mask-bar` impersonation banner (`:inner_block` + `chip`)    |
| `token_blind_bar/1` | `.tb-bar` token-blind banner (`:inner_block` + `chip`)        |

## Consequences

  * Positive: the mockup look is now real + reusable; verticals opt in by serving the CSS
    + calling components. samen_core untouched (its 842-test suite + verifier gate are not
    affected — the kit lives in driftwood-web and adds no kernel dep). No new mix project.
  * Positive: the masking invariant is preserved by construction and covered by tests +
    the live preview.
  * Neutral / future: the existing `BrokerLive` / `OperatorImpersonationLive` /
    `OperatorDashboardLive` still use their original hand-rolled markup; migrating them to
    the kit is a follow-up (they keep their existing test-asserted class names, so the
    migration is mechanical and out of scope here).
  * Extraction trigger: when demo or pawchart adopts the kit, move
    `ui_kit.ex` + `samen_ui.css` into a `samen_ui` path-dep lib, rename the namespace to
    `SamenUI`, and have all three verticals depend on it. This ADR is the pre-registered
    plan for that move.

## Verification

  * `driftwood/ci.sh` (full 20-step verifier gate) + `mix test --warnings-as-errors`
    green after the change; `test/ui_kit_test.exs` (11 tests) added to the default suite.
  * `/ui-kit` returns HTTP 200 with all component markers present; `/assets/samen_ui.css`
    returns HTTP 200 `text/css`. The masked cell renders `••••`; the token is absent.
  * The root `ci.sh` (spikes + samen_core + demo gate + driftwood gate + pawchart gate)
    stays green — samen_core / demo / pawchart are unmodified by this ADR.
