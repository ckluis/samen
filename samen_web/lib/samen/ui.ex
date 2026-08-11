defmodule Samen.UI do
  @moduledoc """
  The Samen framework product-UI kit — reusable HEEx function components that render the
  approved mockup design (ADR-009, promoted from ADR-008's driftwood-local `DriftwoodWeb.UIKit`).

  These components pair with the `samen_ui.css` static asset
  (`priv/static/assets/samen_ui.css`, served at `/assets/samen_ui.css`): the CSS owns the
  tokens + component classes, the components own the markup that consumes them. A vertical
  that serves the stylesheet and calls these components inherits the identical look.

  ## Home / inheritance (ADR-009)

  This kit lives in `samen_web`, the FRAMEWORK UI library, so EVERY vertical inherits it by
  mounting `samen_web` — not by copying it into `driftwood_web`. It does NOT touch
  `samen_core`'s kernel (which stays free of `phoenix_live_view` / `phoenix_component`,
  keeping its 842-test suite + verifier gate untouched — the web dep lives here). Nothing
  here imports a vertical's domain module; the components take assigns only.

  ## Serving the CSS (host side)

  A host serves the stylesheet from THIS lib's priv, so driftwood and pawchart get the
  byte-identical sheet from the dependency, not a per-vertical copy:

      # in the host Endpoint:
      plug Plug.Static,
        at: "/assets",
        from: {:samen_web, "priv/static/assets"},
        only: ~w(samen_ui.css app.js fonts)

  `from: {:samen_web, "priv/static/assets"}` resolves via `:code.priv_dir(:samen_web)`.
  The `fonts` entry serves the self-hosted `@font-face` woff2 (T133) same-origin at
  `/assets/fonts/*.woff2`, so the stylesheet references them by `url()` (small, cached
  independently) instead of base64-inlining them — still ZERO external CDN.
  See `Samen.UI.stylesheet_path/0` for the on-disk path (documented serving helper).

  ## Masking invariant (LOAD-BEARING)

  The kit introduces NO way to render plaintext PII that bypasses masking. A cell or pill
  simply renders whatever value it is handed via `{@value}` / its inner block. If handed a
  `%Samen.Masked{}`, HEEx renders it through the existing `Phoenix.HTML.Safe` protocol impl
  on `Samen.Masked`, which emits `••••`. The kit never calls `Samen.Vault.reveal/3`, never
  pattern-matches a token out of a `%Masked{}`, and never has a "show plaintext" branch.
  Plaintext only reaches a cell if the CALLER already resolved it through
  `Samen.Api.PiiResolution` (the single vault chokepoint). The kit is a dumb renderer of
  already plane-resolved values.

  ## Structure — STABLE FACADE over `Samen.UI.*` submodules

  This module is a THIN FACADE. The component implementations live in family submodules
  under `Samen.UI.*` (each `use Phoenix.Component`, carrying its own `attr`/`slot`
  declarations); `Samen.UI` re-exports every public function verbatim via `defdelegate`, so
  `import Samen.UI; <.button>` and `<Samen.UI.button …>` both keep working with ZERO
  call-site churn. The families:

    * `Samen.UI.Shell`    — `app_shell/1`, `button/1`
    * `Samen.UI.Nav`      — `sidebar/1`, `nav_group/1`, `nav_item/1`, `module_nav/1`,
      `topbar/1`, `tabs/1`, `tab/1`
    * `Samen.UI.Table`    — `data_table/1`, `list_view/1`, `sort_header/1`
    * `Samen.UI.Board`    — `board/1` (the generic `%Samen.Web.Board{}` grouped-columns
      renderer — G1 kanban first client, reusable by calendar/gallery/tree)
    * `Samen.UI.Calendar` — `calendar/1` (the day-keyed `%Samen.Web.Board{}` month grid — G2)
    * `Samen.UI.Gantt`    — `gantt/1` (the lane `%Samen.Web.Board{}` horizontal timeline —
      records positioned as bars by a start/end range — G3 first client)
    * `Samen.UI.Form`     — `simple_form/1`, `form_field/1`
    * `Samen.UI.Overlay`  — `modal/1`, `delete_confirm/1`, `command_palette/1`, `search_box/1`
    * `Samen.UI.Feedback` — `empty_state/1`, `skeleton/1`, `progress/1`, `pill/1`,
      `metric/1`, `lifecycle_pill/1`, `lifecycle_stages/0`
    * `Samen.UI.Object`   — `object_card/1`, `timeline/1`, `mask_bar/1`, `token_blind_bar/1`
    * `Samen.UI.Helpers`  — `stylesheet_path/0`, `humanize_resource/1`, `palette_label/1`,
      `social_links/1`, `social_networks/0`

  ## Component index

    * `app_shell/1`      — the sidebar + main two-pane grid (slots: `:sidebar`, inner)
    * `sidebar/1`        — the sidebar container (workspace header + nav + footer slots)
    * `nav_group/1`      — a labelled group of nav items (`:label` + inner `nav_item`s)
    * `nav_item/1`       — one sidebar link (icon slot, `:active`, optional `:count`/`:dot`)
    * `module_nav/1`     — the INHERITED CRM/Billing/Support/Marketing/Workspace
      (Settings/Automation) nav (framework); host 20% nav via the `:extra` slot
    * `host_nav_extra/1` — renders a host's `:host_nav_extra` mount-label DATA (e.g.
      driftwood's freight "Operations") into that `:extra` slot identically from every
      framework sidebar (PP-10)
    * `topbar/1`         — breadcrumb + title + actions slot
    * `button/1`         — a `.btn` (default / `variant="primary"`)
    * `tabs/1` + `tab/1` — the underline tab bar
    * `data_table/1`     — `<table>` with a `:head` slot + inner rows
    * `list_view/1`      — `data_table/1` + filter box + sort headers + keyset
      pagination footer + bulk-select, as kit defaults (ADR-016; pairs with
      `Samen.Web.ListLive`)
    * `sort_header/1`    — a sortable `<th>` for `list_view/1`'s `:head` slot
    * `board/1`          — the generic grouped-columns board: one column per
      `%Samen.Web.Board{}` group (label + count + per-column-bounded cards + a
      `+N more`/load-more affordance); parameterized by a `:card` renderer slot
      (G1 kanban first client, reusable by calendar/gallery/tree — WS-G)
    * `empty_state/1`    — the standard zero-rows card (title/body/icon +
      `:actions`/`:sample` slots); `list_view/1`'s default `:empty` (ADR-016 §5)
    * `simple_form/1`    — the `AshPhoenix.Form`-backed form wrapper (ADR-016 §2;
      `:let={f}` inner block + `:actions` slot; pairs with `form_field/1`)
    * `form_field/1`     — one labelled input/select/textarea with inline errors +
      `aria-describedby`/`aria-invalid` (AC-G1-9); a `%Masked{}` value renders a
      READ-ONLY `••••` placeholder with NO `name` (it can never submit)
    * `modal/1`          — accessible dialog (`role="dialog"`, focus trap,
      escape/click-away close) hosting create/edit forms
    * `delete_confirm/1` — the delete-confirm affordance (a danger button carrying
      LiveView's `data-confirm` interlock)
    * `pill/1`           — a status pill (`variant` in ok|warn|bad|info|mut)
    * `progress/1`       — the `.prog` bar (`value` 0-100, `label`, `color`)
    * `metric/1`         — a metric card (`:label`, `:value`, optional delta/sub/spark)
    * `mask_bar/1`       — the masked-impersonation banner
    * `token_blind_bar/1`— the token-blind aggregate banner
  """

  # ---------------------------------------------------------------------------
  # Stable facade — every public function re-exported from its family submodule.
  # A defdelegate forwards ALL clauses/patterns of the named arity, so the
  # multi-clause components (form_field/1, object_card/1) and helpers
  # (humanize_resource/1, palette_label/1) delegate whole. Attr defaults are
  # applied INSIDE the callee (the attr-decorated real fn), so a `<.button>` that
  # imported this facade renders identically.
  # ---------------------------------------------------------------------------

  # Shell
  defdelegate app_shell(assigns), to: Samen.UI.Shell
  defdelegate button(assigns), to: Samen.UI.Shell

  # Nav
  defdelegate sidebar(assigns), to: Samen.UI.Nav
  defdelegate nav_group(assigns), to: Samen.UI.Nav
  defdelegate nav_item(assigns), to: Samen.UI.Nav
  defdelegate module_nav(assigns), to: Samen.UI.Nav
  defdelegate host_nav_extra(assigns), to: Samen.UI.Nav
  defdelegate topbar(assigns), to: Samen.UI.Nav
  defdelegate tabs(assigns), to: Samen.UI.Nav
  defdelegate tab(assigns), to: Samen.UI.Nav

  # Table
  defdelegate data_table(assigns), to: Samen.UI.Table
  defdelegate list_view(assigns), to: Samen.UI.Table
  defdelegate sort_header(assigns), to: Samen.UI.Table

  # Board (grouped columns — the %Samen.Web.Board{} renderer, G1 kanban first client)
  defdelegate board(assigns), to: Samen.UI.Board

  # Calendar (month grid — the day-keyed %Samen.Web.Board{} renderer, G2 first client)
  defdelegate calendar(assigns), to: Samen.UI.Calendar

  # Gantt (horizontal timeline — the lane %Samen.Web.Board{} bar renderer, G3 first client)
  defdelegate gantt(assigns), to: Samen.UI.Gantt

  # Gallery (responsive card grid — the %Samen.Web.Page{} card renderer, G5 first client)
  defdelegate gallery(assigns), to: Samen.UI.Gallery

  # Tree (hierarchical nodes — the %Samen.Web.Tree{} renderer, G6 first client)
  defdelegate tree(assigns), to: Samen.UI.Tree

  # Chart (aggregate lenses — the %Samen.Web.Series{} SVG renderers, G8 dashboard first client)
  defdelegate bar_chart(assigns), to: Samen.UI.Chart
  defdelegate line_chart(assigns), to: Samen.UI.Chart
  defdelegate pie_chart(assigns), to: Samen.UI.Chart

  # Dashboard (the tile-grid that composes metric + chart tiles, G8)
  defdelegate dashboard(assigns), to: Samen.UI.Dashboard

  # Map (the %Samen.Web.GeoSet{} SVG basemap + projected pins renderer, G7 first client)
  defdelegate map(assigns), to: Samen.UI.Map

  # Form
  defdelegate simple_form(assigns), to: Samen.UI.Form
  defdelegate form_field(assigns), to: Samen.UI.Form

  # Overlay
  defdelegate modal(assigns), to: Samen.UI.Overlay
  defdelegate delete_confirm(assigns), to: Samen.UI.Overlay
  defdelegate command_palette(assigns), to: Samen.UI.Overlay
  defdelegate search_box(assigns), to: Samen.UI.Overlay

  # Feedback
  defdelegate empty_state(assigns), to: Samen.UI.Feedback
  defdelegate skeleton(assigns), to: Samen.UI.Feedback
  defdelegate progress(assigns), to: Samen.UI.Feedback
  defdelegate pill(assigns), to: Samen.UI.Feedback
  defdelegate metric(assigns), to: Samen.UI.Feedback
  defdelegate lifecycle_pill(assigns), to: Samen.UI.Feedback
  defdelegate lifecycle_stages(), to: Samen.UI.Feedback

  # Object
  defdelegate object_card(assigns), to: Samen.UI.Object
  defdelegate timeline(assigns), to: Samen.UI.Object
  defdelegate mask_bar(assigns), to: Samen.UI.Object
  defdelegate token_blind_bar(assigns), to: Samen.UI.Object

  # Helpers
  defdelegate stylesheet_path(), to: Samen.UI.Helpers
  defdelegate humanize_resource(name), to: Samen.UI.Helpers
  defdelegate palette_label(display), to: Samen.UI.Helpers
  defdelegate social_links(assigns), to: Samen.UI.Helpers
  defdelegate social_networks(), to: Samen.UI.Helpers
end
