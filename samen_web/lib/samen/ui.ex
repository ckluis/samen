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
        only: ~w(samen_ui.css)

  `from: {:samen_web, "priv/static/assets"}` resolves via `:code.priv_dir(:samen_web)`.
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

  ## Component index

    * `app_shell/1`      — the sidebar + main two-pane grid (slots: `:sidebar`, inner)
    * `sidebar/1`        — the sidebar container (workspace header + nav + footer slots)
    * `nav_group/1`      — a labelled group of nav items (`:label` + inner `nav_item`s)
    * `nav_item/1`       — one sidebar link (icon slot, `:active`, optional `:count`/`:dot`)
    * `module_nav/1`     — the INHERITED CRM/Billing/Support nav (framework); host 20% nav
      via the `:extra` slot
    * `topbar/1`         — breadcrumb + title + actions slot
    * `button/1`         — a `.btn` (default / `variant="primary"`)
    * `tabs/1` + `tab/1` — the underline tab bar
    * `data_table/1`     — `<table>` with a `:head` slot + inner rows
    * `list_view/1`      — `data_table/1` + filter box + sort headers + keyset
      pagination footer + bulk-select, as kit defaults (ADR-016; pairs with
      `Samen.Web.ListLive`)
    * `sort_header/1`    — a sortable `<th>` for `list_view/1`'s `:head` slot
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
  use Phoenix.Component

  @doc """
  The on-disk directory of the `samen_ui.css` asset inside THIS dependency. A host that
  needs the path directly (e.g. a bespoke static plug) can call this; the recommended
  form is the `{:samen_web, "priv/static/assets"}` tuple documented in the moduledoc.
  """
  def stylesheet_path do
    Path.join([:code.priv_dir(:samen_web), "static", "assets", "samen_ui.css"])
  end

  # ---------------------------------------------------------------------------
  # App shell
  # ---------------------------------------------------------------------------

  @doc """
  The two-pane app shell: a `:sidebar` slot on the left, the default inner block
  (the `<main>`) on the right. Mirrors `.app > .side + .main` from the mockups.

  ## Responsive drawer (WS-E E6.1, ADR-030 — CSS-only affordance)

  The shell carries a hidden checkbox (`#samen-nav-toggle`) plus a hamburger
  `<label>` and a scrim `<label>`. On desktop both labels are `display:none` and
  the checkbox does nothing — the 252px grid is unchanged. At the mobile
  breakpoint the sidebar becomes an off-canvas drawer that the hamburger opens
  and the scrim closes, driven ENTIRELY by CSS `:checked ~` sibling rules (no JS
  framework, no hook). The checkbox/labels are out-of-flow (fixed / display:none),
  so the grid still sees exactly `.side` + `.main` as its two items. Purely
  layout — it renders no field values, so it has no masking surface.
  """
  slot :sidebar, required: true
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="app">
      <input type="checkbox" id="samen-nav-toggle" class="nav-toggle-cb" aria-hidden="true" tabindex="-1" />
      <label for="samen-nav-toggle" class="nav-hamburger" aria-label="Toggle navigation menu">
        <svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M4 6h16M4 12h16M4 18h16" />
        </svg>
      </label>
      {render_slot(@sidebar)}
      <label for="samen-nav-toggle" class="nav-scrim" aria-hidden="true"></label>
      <main class="main">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Sidebar
  # ---------------------------------------------------------------------------

  @doc """
  The sidebar container. `title` / `subtitle` render the workspace header next to a
  square logo (`logo` = the single glyph, default "S"; `logo_style` optionally
  restyles the gradient). The default inner block holds `nav_group/1`s. Optional
  `:search` and `:footer` slots render the search box and the user footer.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :logo, :string, default: "S"
  attr :logo_style, :string, default: nil
  slot :switcher
  slot :search
  slot :footer
  slot :inner_block, required: true

  def sidebar(assigns) do
    ~H"""
    <aside class="side">
      <div class="ws">
        <div class="logo" style={@logo_style}>{@logo}</div>
        <div class="who">
          <b>{@title}</b>
          <span :if={@subtitle}>{@subtitle}</span>
        </div>
        <%= if @switcher != [] do %>
          {render_slot(@switcher)}
        <% else %>
          <div class="col">⌄</div>
        <% end %>
      </div>
      {render_slot(@search)}
      {render_slot(@inner_block)}
      {render_slot(@footer)}
    </aside>
    """
  end

  @doc """
  A labelled nav group: a `.grp` uppercase label followed by its `nav_item/1`s.
  """
  attr :label, :string, required: true
  slot :inner_block, required: true

  def nav_group(assigns) do
    ~H"""
    <div class="grp">{@label}</div>
    <nav class="nav">
      {render_slot(@inner_block)}
    </nav>
    """
  end

  @doc """
  A single sidebar nav item. `label` is the link text, `href` the target,
  `active` toggles the selected `.on` state. Provide an optional `:icon` slot for
  the leading glyph. `count` renders a right-aligned monospace count; `dot: true`
  renders a status dot instead (they are mutually exclusive — `count` wins).
  """
  attr :label, :string, required: true
  attr :href, :string, default: "#"
  attr :active, :boolean, default: false
  attr :count, :any, default: nil
  attr :dot, :boolean, default: false
  slot :icon

  def nav_item(assigns) do
    ~H"""
    <a href={@href} class={@active && "on"}>
      <span :if={@icon != []} class="i">{render_slot(@icon)}</span>
      {@label}
      <span :if={@count != nil} class="cnt">{@count}</span>
      <span :if={@count == nil and @dot} class="dot"></span>
    </a>
    """
  end

  @doc """
  The INHERITED module navigation — the framework single source of truth for the
  CRM/Billing/Support nav groups that EVERY vertical shows (the "inherited 80%").

  This is the ADR-009 split of the old driftwood-local `module_nav/1`: the freight
  "Operations" group was vertical-specific and moves OUT (a host passes its own 20% nav
  through the `:extra` slot); the CRM/Billing/Support groups are framework-level and stay
  here, parameterized so any host mounts them.

  Attrs:

    * `org_id`   — threaded into every href so navigation preserves the `?org=` selector.
    * `active`   — one of `:crm_companies | :crm_contacts | :crm_pipeline |
      :billing_overview | :billing_invoices | :billing_plans | :support_tickets` (or `nil`).
    * `crm_path` / `billing_path` / `support_path` — the mount path prefix per module
      (default `/crm`, `/billing`, `/support`). A host that mounted CRM at `/customers`
      passes `crm_path: "/customers"`.

  The `:extra` slot renders BEFORE the inherited groups — a host puts its vertical-specific
  nav groups (e.g. freight "Operations") there. The inherited nav is the framework's; the
  20% nav is the vertical's.
  """
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :crm_path, :string, default: "/crm"
  attr :billing_path, :string, default: "/billing"
  attr :support_path, :string, default: "/support"
  attr :marketing_path, :string, default: "/marketing"
  attr :notifications_path, :string, default: "/notifications"

  attr :notifications_unread, :any,
    default: nil,
    doc: "unread count feeding the nav_item badge (nil → unlit; AC-G2-7)"

  slot :extra

  def module_nav(assigns) do
    ~H"""
    {render_slot(@extra)}

    <.nav_group label="Inbox">
      <.nav_item
        label="Notifications"
        href={"#{@notifications_path}?org=#{@org_id}"}
        active={@active == :notifications}
        count={@notifications_unread}
      >
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9" /><path d="M13.7 21a2 2 0 0 1-3.4 0" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="CRM">
      <.nav_item label="Companies" href={"#{@crm_path}/companies?org=#{@org_id}"} active={@active == :crm_companies}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Contacts" href={"#{@crm_path}/contacts?org=#{@org_id}"} active={@active == :crm_contacts}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Pipeline" href={"#{@crm_path}/pipeline?org=#{@org_id}"} active={@active == :crm_pipeline}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 3v18M12 6v15M19 9v12" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="Billing">
      <.nav_item label="Customers" href={"#{@billing_path}?org=#{@org_id}"} active={@active == :billing_overview}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Invoices" href={"#{@billing_path}/invoices?org=#{@org_id}"} active={@active == :billing_invoices}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M6 2h9l5 5v15H6z" /><path d="M9 12h7M9 16h7M9 8h3" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Plans" href={"#{@billing_path}/plans?org=#{@org_id}"} active={@active == :billing_plans}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 10h18" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="Support">
      <.nav_item label="Tickets" href={"#{@support_path}?org=#{@org_id}"} active={@active == :support_tickets}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="Marketing">
      <.nav_item label="Campaigns" href={"#{@marketing_path}/campaigns?org=#{@org_id}"} active={@active == :marketing_campaigns}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 11l18-8-8 18-2-8-8-2z" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Segments" href={"#{@marketing_path}/segments?org=#{@org_id}"} active={@active == :marketing_segments}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="8" cy="8" r="4" /><path d="M14 20a6 6 0 0 0-12 0" /><path d="M15 7h6M18 4v6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Leads" href={"#{@marketing_path}/leads?org=#{@org_id}"} active={@active == :marketing_leads}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 17l6-6 4 4 8-8" /><path d="M17 7h4v4" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>
    """
  end

  # ---------------------------------------------------------------------------
  # Search — ⌘K command palette + per-list search box (WS-E E4.3; ADR-027)
  # ---------------------------------------------------------------------------

  @doc """
  The per-list SEARCH BOX that fills the sidebar `:search` slot (ADR-027 decision 4;
  the placeholder the design flagged as fed by nothing). A tiny GET form that carries
  the term (and current org) to the ⌘K search page — the same `Samen.Search` engine,
  scoped to the mount. Purely a navigation affordance: no value is rendered here, so
  there is no masking surface.

    * `action`  — the search page path (default `/search`).
    * `org_id`  — carried through so the target page resolves the same current org.
    * `placeholder` — input copy.

  The input carries `data-cmdk` so the framework-global ⌘K shortcut (an inline
  script in the shared root layout, WS-E E6 / ADR-027 carry) can focus it from
  anywhere on a list page. It renders the leading magnifier glyph + a `⌘K` kbd
  hint, so it is a visual drop-in for the old static `.search` placeholder. No
  value is rendered here (it is a navigation affordance) — no masking surface.
  """
  attr :action, :string, default: "/search"
  attr :org_id, :string, default: nil
  attr :placeholder, :string, default: "Search…"

  def search_box(assigns) do
    ~H"""
    <form class="search" method="get" action={@action} role="search">
      <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
      </svg>
      <input
        type="search"
        name="q"
        class="search-input"
        placeholder={@placeholder}
        autocomplete="off"
        aria-label="Search"
        data-cmdk
      />
      <span class="kbd">⌘K</span>
      <input :if={@org_id} type="hidden" name="org" value={@org_id} />
    </form>
    """
  end

  @doc """
  The ⌘K COMMAND PALETTE (ADR-027 decision 4) — a single framework panel that renders
  the ranked, org-scoped, per-plane-masked `%Samen.Search.Result{}`s from
  `Samen.Search.query/3`. Every vertical mounts it via `samen_search_routes` at ≈0 LOC;
  zero authored search LiveViews.

  ## Masking posture (masking watch-list)

  This component renders ONLY `result.display` — the bounded NON-PII allowlist the
  engine already projected through the PII resolver. It never touches `result.record`'s
  vaulted fields, never reveals a vaulted value, and never unwraps a masked value. The
  masking guarantee lives at the query seam (the engine); this surface cannot
  re-introduce a leak because it is handed only masked-safe display values.

    * `id`          — DOM id (default `"cmdk"`).
    * `q`           — the current term (echoed into the input).
    * `results`     — a list of `%Samen.Search.Result{}`.
    * `event`       — the LiveView event the debounced input fires (default `"search"`).
    * `placeholder` — input copy.
  """
  attr :id, :string, default: "cmdk"
  attr :q, :string, default: ""
  attr :results, :list, default: []
  attr :event, :string, default: "search"
  attr :placeholder, :string, default: "Search everything…"

  def command_palette(assigns) do
    ~H"""
    <div class="cmdk" id={@id}>
      <form class="cmdk-form" phx-change={@event} phx-submit={@event} role="search">
        <input
          id={"#{@id}-input"}
          type="search"
          name="q"
          class="cmdk-input"
          value={@q}
          placeholder={@placeholder}
          autocomplete="off"
          autofocus
          phx-debounce="150"
          aria-label="Search everything"
        />
      </form>

      <ul class="cmdk-results" role="listbox">
        <li :for={r <- @results} class="cmdk-hit" role="option">
          <span class="cmdk-kind">{Samen.UI.humanize_resource(r.resource_name)}</span>
          <span class="cmdk-label">{Samen.UI.palette_label(r.display)}</span>
        </li>
        <li :if={@q not in [nil, ""] and @results == []} class="cmdk-empty">No matches.</li>
      </ul>
    </div>
    """
  end

  @doc false
  # The last module segment of a result's resource name ("Driftwood.Primitives.File" → "File").
  def humanize_resource(name) when is_binary(name), do: name |> String.split(".") |> List.last()
  def humanize_resource(name), do: to_string(name)

  @doc false
  # Join the bounded NON-PII display values (already masked-safe) for a palette row.
  def palette_label(display) when is_map(display) do
    display
    |> Map.values()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  def palette_label(_), do: ""

  # ---------------------------------------------------------------------------
  # Topbar (breadcrumb + title + actions)
  # ---------------------------------------------------------------------------

  @doc """
  The main-pane topbar: a breadcrumb trail (`crumbs` = a list of strings, joined
  with `/`), the page `title` (an `<h1>`), and an optional `:actions` slot for
  buttons on the right.
  """
  attr :title, :string, required: true
  attr :crumbs, :list, default: []
  slot :actions

  def topbar(assigns) do
    ~H"""
    <div class="top">
      <div :if={@crumbs != []} class="crumb">
        <%= for {crumb, idx} <- Enum.with_index(@crumbs) do %>
          <span :if={idx > 0} class="sep">/</span>
          {crumb}
        <% end %>
      </div>
      <div class="head">
        <h1>{@title}</h1>
        <div :if={@actions != []} class="actions">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Button
  # ---------------------------------------------------------------------------

  @doc """
  A `.btn`. `variant="primary"` renders the dark filled button. Provide an optional
  `:icon` slot; the label is the default inner block. Extra attrs (`phx-click`,
  `type`, `disabled`, `class`, …) pass through via `:rest`.
  """
  attr :variant, :string, default: "default", values: ~w(default primary)
  attr :rest, :global, include: ~w(type disabled name value form phx-click phx-value-id)
  slot :icon
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button class={if @variant == "primary", do: "btn primary", else: "btn"} {@rest}>
      <span :if={@icon != []} class="i">{render_slot(@icon)}</span>
      {render_slot(@inner_block)}
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Tabs
  # ---------------------------------------------------------------------------

  @doc "The tab bar container. Holds `tab/1`s in its inner block."
  slot :inner_block, required: true

  def tabs(assigns) do
    ~H"""
    <div class="tabs">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "One tab. `active` toggles the selected underline. Optional `:icon` slot."
  attr :label, :string, required: true
  attr :href, :string, default: "#"
  attr :active, :boolean, default: false
  slot :icon

  def tab(assigns) do
    ~H"""
    <a href={@href} class={@active && "on"}>
      <span :if={@icon != []} class="i">{render_slot(@icon)}</span>
      {@label}
    </a>
    """
  end

  # ---------------------------------------------------------------------------
  # Data table
  # ---------------------------------------------------------------------------

  @doc """
  A data table wrapped in a `.card`. The `:head` slot supplies the `<tr>` of
  `<th>`s; the default inner block supplies the `<tbody>` rows (`<tr class="...">`).
  The kit does NOT interpret cell values — a row renders whatever the caller puts
  in it, so a `%Samen.Masked{}` cell shows `••••` via `Phoenix.HTML.Safe`.

  ## Responsive variant (WS-E E6.1, ADR-030)

  The `<table>` is wrapped in a `.table-scroll` container that, at the mobile
  breakpoint, gives the table a bounded HORIZONTAL scroll instead of clipping or
  reflowing cells. This is deliberately value-blind: it never reads, stringifies,
  or reflows a cell VALUE (which would be the only way to disturb masking), so a
  `%Samen.Masked{}` cell renders `••••` identically at every width (AC-G20-2).
  """
  slot :head, required: true
  slot :inner_block, required: true

  def data_table(assigns) do
    ~H"""
    <div class="card">
      <div class="table-scroll">
        <table>
          <thead>
            <tr>{render_slot(@head)}</tr>
          </thead>
          <tbody>
            {render_slot(@inner_block)}
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # List view (ADR-016 §2 — data_table + sort/filter/keyset-pagination/bulk as
  # KIT DEFAULTS; every vertical inherits list ergonomics at ≈0 lines)
  # ---------------------------------------------------------------------------

  @doc """
  The behaviour-bearing list primitive (ADR-016 §2, WS-A design §1.1): wraps
  `data_table/1` and adds, as **kit defaults**, a debounced filter box
  (`phx-change="filter"`), sortable headers (via `sort_header/1` in the `:head`
  slot), a KEYSET pagination footer (`phx-click="paginate"`, prev/next — stable
  under concurrent inserts, see `Samen.Web.Reads`), and an optional bulk-select
  affordance (checkbox column + a bulk-action bar that appears when ≥ 1 row is
  selected). Pairs with the `Samen.Web.ListLive` mixin, which owns every event
  this component emits.

  Attrs:

    * `page`        — a `%Samen.Web.Page{}` (the bounded read's result)
    * `state`       — a `%Samen.Web.ListState{}`; supplies `sort`/`filter`/
      `selected`/prev-availability (each also individually overridable)
    * `selectable`  — render the bulk-select checkbox column (default `false`)
    * `bulk_actions`— `[%{name: "archive", label: "Archive"}]` rendered in the
      default bulk bar (`phx-click="bulk"` with `phx-value-action`)
    * `empty_text`  — the default zero-row copy, rendered as the title of the
      default `empty_state/1` (ADR-016 §5 — every `list_view` adopter gets the
      consistent empty state at zero cost; the `:empty` slot overrides it)
    * `empty_icon` / `empty_body` — forwarded to the default `empty_state/1`
      (WS-A design §3.1 / AC-G5-1: icon + message on every list's empty state)

  Slots: `:head` (the `<th>`s — use `sort_header/1` for sortable columns),
  `:row` (`:let={item}` — the `<td>`s for one record), `:bulk_bar`
  (`:let={selected}` — replaces the default bulk-action buttons), `:empty`,
  `:empty_actions` (the surface's primary CREATE action, forwarded into the
  default empty state's `:actions` — AC-G5-1's "wired CTA" half), and
  `:empty_sample` (the load-sample-data affordance, forwarded into `:sample` —
  the AC-G5-3 hook).

  ## Masking (LOAD-BEARING)

  A row cell renders whatever the `:row` slot puts in it — an ALREADY-RESOLVED
  value. A `%Samen.Masked{}` renders `••••` via `Phoenix.HTML.Safe`; this component
  never stringifies, inspects, or unwraps a field value (rows are keyed by `id`
  only, a non-PII opaque uuid). The kit adds no unmasking here.
  """
  attr :id, :string, default: "list"
  attr :page, :any, required: true, doc: "a %Samen.Web.Page{}"
  attr :state, :any, default: nil, doc: "a %Samen.Web.ListState{} (or nil)"
  attr :loading, :boolean,
    default: false,
    doc: "render the skeleton/1 placeholder instead of rows/empty (WS-E E6.2)"

  attr :filter, :string, default: nil
  attr :selected, :any, default: nil, doc: "MapSet of selected row ids"
  attr :selectable, :boolean, default: false
  attr :row_class, :string, default: nil, doc: "extra class on each row <tr> (e.g. \"contact-row\")"
  attr :bulk_actions, :list, default: []
  attr :filter_placeholder, :string, default: "Filter…"
  attr :empty_text, :string, default: "Nothing here yet."
  attr :empty_icon, :string, default: nil
  attr :empty_body, :string, default: nil
  slot :head, required: true
  slot :row, required: true
  slot :bulk_bar
  slot :empty
  slot :empty_actions, doc: "forwarded to the default empty_state's :actions (the create CTA)"
  slot :empty_sample, doc: "forwarded to the default empty_state's :sample (load sample data)"

  def list_view(assigns) do
    assigns =
      assigns
      |> assign(:filter, assigns.filter || list_state_get(assigns.state, :filter, ""))
      |> assign(:selected, assigns.selected || list_state_get(assigns.state, :selected, MapSet.new()))
      |> assign(:prev?, list_prev?(assigns.state, assigns.page))
      |> assign(:row_class_attr, Enum.join(["list-row"] ++ List.wrap(assigns.row_class), " "))

    ~H"""
    <div class="list-view" id={@id}>
      <div class="list-toolbar" style="display:flex;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap">
        <form class="list-filter" phx-change="filter" phx-submit="filter" style="flex:0 0 auto">
          <input
            type="search"
            name="filter"
            value={@filter}
            placeholder={@filter_placeholder}
            phx-debounce="300"
            autocomplete="off"
            aria-label="Filter list"
          />
        </form>
        <div
          :if={@selectable and MapSet.size(@selected) > 0}
          class="bulk-bar"
          role="toolbar"
          aria-label="Bulk actions"
          style="display:flex;align-items:center;gap:8px"
        >
          <span class="bulk-count">{MapSet.size(@selected)} selected</span>
          <%= if @bulk_bar != [] do %>
            {render_slot(@bulk_bar, @selected)}
          <% else %>
            <.button :for={action <- @bulk_actions} phx-click="bulk" phx-value-action={bulk_action_name(action)}>
              {bulk_action_label(action)}
            </.button>
          <% end %>
        </div>
      </div>

      <%= cond do %>
        <% @loading -> %>
          <div class="card list-loading" style="padding:14px 16px">
            <.skeleton rows={5} avatar />
          </div>
        <% @page.items == [] and @empty != [] -> %>
          {render_slot(@empty)}
        <% @page.items == [] -> %>
          <.empty_state class="list-empty" title={@empty_text} body={@empty_body} icon={@empty_icon}>
            <:actions :if={@empty_actions != []}>{render_slot(@empty_actions)}</:actions>
            <:sample :if={@empty_sample != []}>{render_slot(@empty_sample)}</:sample>
          </.empty_state>
        <% true -> %>
        <.data_table>
          <:head>
            <th :if={@selectable} scope="col" class="list-select-col" style="width:28px">
              <input
                type="checkbox"
                phx-click="select_all"
                checked={list_all_selected?(@page.items, @selected)}
                aria-label="Select all rows on this page"
              />
            </th>
            {render_slot(@head)}
          </:head>
          <tr :for={item <- @page.items} class={@row_class_attr} id={"#{@id}-row-#{item.id}"}>
            <td :if={@selectable} class="list-select-cell">
              <input
                type="checkbox"
                phx-click="select"
                phx-value-id={item.id}
                checked={MapSet.member?(@selected, item.id)}
                aria-label="Select row"
              />
            </td>
            {render_slot(@row, item)}
          </tr>
        </.data_table>

        <div class="list-footer" style="display:flex;align-items:center;gap:10px;margin-top:10px">
          <.button phx-click="paginate" phx-value-dir="prev" disabled={not @prev?} aria-label="Previous page">
            ‹ Prev
          </.button>
          <.button phx-click="paginate" phx-value-dir="next" disabled={not @page.has_more} aria-label="Next page">
            Next ›
          </.button>
          <span class="list-page-size" style="color:var(--muted);font-size:12px">
            page size {@page.page_size}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  A sortable column header for `list_view/1`'s `:head` slot. Emits
  `phx-click="sort"` with `phx-value-field` (the `Samen.Web.ListLive` mixin matches
  it against the view's BOUNDED sortable list — client input never mints an atom).
  Carries `scope="col"` + `aria-sort` (AC-G1-9).
  """
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :any, default: nil, doc: "{field, :asc | :desc} — usually @list_state.sort"
  attr :width, :string, default: nil

  def sort_header(assigns) do
    {active, dir} =
      case assigns.sort do
        {field, dir} when field == assigns.field -> {true, dir}
        _ -> {false, nil}
      end

    assigns = assign(assigns, active: active, dir: dir)

    ~H"""
    <th
      scope="col"
      class={["sort-th", @active && "sorted"]}
      style={@width && "width:#{@width}"}
      aria-sort={sort_aria(@active, @dir)}
    >
      <button
        type="button"
        class="sort-btn"
        phx-click="sort"
        phx-value-field={Atom.to_string(@field)}
        style="background:none;border:0;padding:0;font:inherit;color:inherit;cursor:pointer;display:inline-flex;align-items:center;gap:4px"
      >
        {@label}
        <span :if={@active} class="sort-dir" aria-hidden="true">{if @dir == :asc, do: "▲", else: "▼"}</span>
      </button>
    </th>
    """
  end

  defp sort_aria(true, :asc), do: "ascending"
  defp sort_aria(true, :desc), do: "descending"
  defp sort_aria(_, _), do: nil

  # list_view helpers — STATE plumbing only; these never touch a field value.

  defp list_state_get(nil, _key, default), do: default
  defp list_state_get(state, key, default), do: Map.get(state, key) || default

  # Prev is available when the current page has a cursor (i.e. not the first page).
  defp list_prev?(%{cursor_stack: stack}, _page) when is_list(stack), do: stack != []
  defp list_prev?(_state, %{cursor: cursor}), do: cursor != nil
  defp list_prev?(_state, _page), do: false

  defp list_all_selected?([], _selected), do: false

  defp list_all_selected?(items, selected),
    do: Enum.all?(items, fn item -> MapSet.member?(selected, item.id) end)

  defp bulk_action_name(%{name: name}), do: name
  defp bulk_action_name(name) when is_binary(name), do: name

  defp bulk_action_label(%{label: label}), do: label
  defp bulk_action_label(%{name: name}), do: name
  defp bulk_action_label(name) when is_binary(name), do: name

  # ---------------------------------------------------------------------------
  # Empty state (ADR-016 §5 / WS-A design §3.1 — the G5 primitive)
  # ---------------------------------------------------------------------------

  @doc """
  The standard zero-rows empty state (ADR-016 §5, AC-G5-1 component half): an icon
  glyph, a `title`, an optional `body`, and two slots — `:actions` (the primary CTA,
  e.g. the "New …" button) and `:sample` (the optional "load sample data" affordance
  that A5's guarded `SampleData.load/2` will feed). `list_view/1` renders this as its
  default `:empty`, so every list that adopts the kit gets the consistent empty state
  at zero extra cost.

  Purely presentational — copy in, markup out. It renders no field values, so it has
  no masking surface.
  """
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :icon, :string, default: nil, doc: "a leading glyph (decorative, aria-hidden)"
  attr :class, :any, default: nil

  slot :actions, doc: "the primary call-to-action button(s)"
  slot :sample, doc: "the optional load-sample-data affordance (ADR-016 §5)"

  def empty_state(assigns) do
    assigns =
      assign(assigns, :class_attr, Enum.join(["card", "empty-state"] ++ List.wrap(assigns.class), " "))

    ~H"""
    <div
      class={@class_attr}
      style="padding:34px 24px;display:flex;flex-direction:column;align-items:center;gap:8px;text-align:center"
    >
      <div :if={@icon} class="empty-icon" aria-hidden="true" style="font-size:26px;line-height:1">{@icon}</div>
      <h3 class="empty-title" style="margin:0;font-size:15px;font-weight:600">{@title}</h3>
      <p :if={@body} class="empty-body" style="margin:0;color:var(--muted);font-size:13px;max-width:44ch">{@body}</p>
      <div :if={@actions != []} class="empty-actions" style="display:flex;align-items:center;gap:8px;margin-top:8px">
        {render_slot(@actions)}
      </div>
      <div :if={@sample != []} class="empty-sample" style="margin-top:4px;font-size:12px;color:var(--muted)">
        {render_slot(@sample)}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Skeleton (WS-E E6.2, ADR-030 — the loading-placeholder primitive)
  # ---------------------------------------------------------------------------

  @doc """
  A loading skeleton (WS-E E6.2): `rows` shimmer placeholder lines standing in for
  content that has not loaded yet. `avatar` prepends a round avatar placeholder per
  row (the list/table shape). Paired with the `samen-shimmer` keyframes in
  `samen_ui.css`; honours `prefers-reduced-motion`.

  PURELY PRESENTATIONAL — it renders NO data at all (abstract bars only), so it has
  no masking surface and cannot leak a value it never receives. This ships the
  primitive + wires it into `list_view/1`'s `loading` state; the fleet-wide
  `assign_async` conversion of every list is explicitly DEFERRED (design §6,
  decompose rule).
  """
  attr :rows, :integer, default: 5
  attr :avatar, :boolean, default: false
  attr :class, :any, default: nil

  def skeleton(assigns) do
    assigns =
      assigns
      |> assign(:count, max(assigns.rows, 1))
      |> assign(:class_attr, Enum.join(["skeleton" | List.wrap(assigns.class)], " "))

    ~H"""
    <div class={@class_attr} role="status" aria-busy="true" aria-live="polite">
      <span class="sr-only" style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)">Loading…</span>
      <div :for={_ <- 1..@count} class="skeleton-row" aria-hidden="true">
        <div :if={@avatar} class="skeleton-line avatar"></div>
        <div class="skeleton-line narrow"></div>
        <div class="skeleton-line"></div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Forms (ADR-016 §2 / WS-A design §1.1 — simple_form + form_field)
  # ---------------------------------------------------------------------------

  @doc """
  The kit form wrapper (ADR-016 §2): an `AshPhoenix.Form`-backed `<form>` (any
  `Phoenix.HTML.FormData` source works — `AshPhoenix.Form` is the framework
  convention; A3's CRUD wiring hands one in). The inner block receives the form via
  `:let={f}`; compose fields with `form_field/1` (which owns inline errors). The
  `:actions` slot renders the submit/cancel row.

  ## Masking (LOAD-BEARING — the write-form half of MC-1)

  `simple_form` is a dumb container: it never reads, echoes, or serializes a field
  VALUE itself — values render only through `form_field/1`, whose `%Samen.Masked{}`
  branch emits a read-only `••••` placeholder with NO `name` attribute, so a vaulted
  field on the operator/impersonation plane can never round-trip plaintext (or the
  vault token) through this form. The Ash-write-path rejection (Invariant L1) lands
  in A3; this component guarantees the RENDER half by construction.
  """
  attr :for, :any, required: true, doc: "an AshPhoenix.Form / %Phoenix.HTML.Form{} / FormData source"
  attr :id, :string, default: nil
  attr :as, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete method novalidate phx-submit phx-change phx-target phx-auto-recover)

  slot :inner_block, required: true
  slot :actions, doc: "the submit/cancel row (receives the form via :let)"

  def simple_form(assigns) do
    # Re-name the form only when `as` is SET — passing `as: nil` through would reset
    # the name a caller already baked in via `to_form(..., as: ...)`.
    assigns =
      case assigns.as do
        nil -> assigns
        as -> assign(assigns, :for, to_form(assigns.for, as: as))
      end

    ~H"""
    <.form :let={f} for={@for} id={@id} class="simple-form" {@rest}>
      {render_slot(@inner_block, f)}
      <div :if={@actions != []} class="form-actions" style="display:flex;align-items:center;gap:8px;margin-top:14px">
        {render_slot(@actions, f)}
      </div>
    </.form>
    """
  end

  @doc """
  One labelled form field (ADR-016 §2, AC-G1-9): label + input/select/textarea +
  inline errors. `field` is the `%Phoenix.HTML.FormField{}` from `simple_form/1`'s
  `:let={f}` (`f[:name]`). Errors come from `field.errors` (populated by
  `AshPhoenix.Form.validate/submit`) and render in a `field-errors` block wired to
  the input via `aria-describedby` + `aria-invalid` — the AC-G1-2 inline-error path.

  ## Masking (LOAD-BEARING — MC-1's render half)

  A field whose CURRENT VALUE is a `%Samen.Masked{}` (a vaulted attribute resolved on
  the operator/impersonation plane) renders a DISABLED, read-only input whose literal
  value is `••••` and which carries **no `name` attribute** — it cannot submit
  anything, so no operator-authored plaintext (and never the vault token) can enter
  the params through this field. The component never unwraps, stringifies, or
  inspects the `%Masked{}`; the requested `type` (textarea/select included) is
  ignored on the masked branch — there is no editable-masked variant by construction.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil

  attr :type, :string,
    default: "text",
    values: ~w(text email tel url password number date time datetime-local search hidden textarea select)

  attr :options, :list, default: [], doc: "select options (`options_for_select/2` shapes)"
  attr :prompt, :string, default: nil, doc: "select prompt option"
  attr :rest, :global, include: ~w(placeholder autocomplete rows cols min max step required disabled readonly phx-debounce)

  # MASKED branch (MC-1 render half): value is %Samen.Masked{} → a read-only ••••
  # placeholder with NO name attr (nothing can submit) and NO token in the DOM. The
  # match happens HERE, on the struct — the value itself is never rendered or unwrapped.
  def form_field(%{field: %Phoenix.HTML.FormField{value: %Samen.Masked{}}} = assigns) do
    ~H"""
    <div class="field field-masked" style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
      <label :if={@label} for={@field.id} class="field-label" style="font-size:12px;font-weight:600">{@label}</label>
      <input
        type="text"
        id={@field.id}
        value="••••"
        disabled
        readonly
        data-masked
        aria-disabled="true"
        title="Masked on this plane"
      />
    </div>
    """
  end

  def form_field(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = Enum.map(field.errors, &translate_form_error/1)

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:error_id, if(errors != [], do: "#{field.id}-errors"))

    ~H"""
    <div
      class={["field", @errors != [] && "field-invalid"]}
      style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px"
    >
      <label :if={@label} for={@field.id} class="field-label" style="font-size:12px;font-weight:600">{@label}</label>
      <%= case @type do %>
        <% "textarea" -> %>
          <textarea
            id={@field.id}
            name={@field.name}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          >{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
        <% "select" -> %>
          <select
            id={@field.id}
            name={@field.name}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          >
            <option :if={@prompt} value="">{@prompt}</option>
            {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
          </select>
        <% type -> %>
          <input
            type={type}
            id={@field.id}
            name={@field.name}
            value={Phoenix.HTML.Form.normalize_value(type, @field.value)}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          />
      <% end %>
      <div :if={@errors != []} class="field-errors" id={@error_id}>
        <p :for={msg <- @errors} class="field-error" style="margin:0;color:var(--bad, #b91c1c);font-size:12px">{msg}</p>
      </div>
    </div>
    """
  end

  # Interpolate `{msg, opts}` error tuples (the Phoenix/Ash error shape). This touches
  # ERROR MESSAGES only — framework copy + bounded vars — never a field value.
  defp translate_form_error({msg, opts}) when is_binary(msg) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp translate_form_error(msg) when is_binary(msg), do: msg

  # ---------------------------------------------------------------------------
  # Modal (ADR-016 §2 — role=dialog, focus trap, escape/click-away close)
  # ---------------------------------------------------------------------------

  @doc """
  An accessible modal / slide-over container (ADR-016 §2, AC-G1-9): `role="dialog"` +
  `aria-modal` + `aria-labelledby` (wired to the `title`), a FOCUS TRAP via
  `Phoenix.Component.focus_wrap/1`, and close on Escape (`phx-window-keydown` +
  `phx-key="escape"`), click-away (`phx-click-away`), or the ✕ button — each firing
  `on_cancel` (an event name string or `Phoenix.LiveView.JS`; the hosting LiveView
  owns it). Hosts create/edit `simple_form/1`s without a full-page nav.

  Render it conditionally from the LiveView (`<.modal :if={@show_modal} …>`); the
  content is the default inner block. Purely presentational — it renders no field
  values itself, so masking rides on what the caller puts inside (a `form_field/1`
  keeps its own masked branch).
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :on_cancel, :any, default: nil, doc: "event name (string) or JS command fired by escape/click-away/✕"

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal-overlay"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
      style="position:fixed;inset:0;z-index:60;display:flex;align-items:center;justify-content:center;background:rgba(15,16,24,.45);padding:20px"
    >
      <.focus_wrap
        id={"#{@id}-content"}
        class="card modal-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title && "#{@id}-title"}
        phx-click-away={@on_cancel}
        style="background:#fff;min-width:340px;max-width:560px;width:100%;max-height:calc(100vh - 40px);overflow:auto;padding:18px 20px"
      >
        <div class="modal-head" style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px">
          <h2 :if={@title} id={"#{@id}-title"} class="modal-title" style="margin:0;font-size:15px;font-weight:650">{@title}</h2>
          <button
            type="button"
            class="modal-close"
            phx-click={@on_cancel}
            aria-label="Close"
            style="background:none;border:0;cursor:pointer;font-size:14px;color:var(--muted);margin-left:auto"
          >
            ✕
          </button>
        </div>
        {render_slot(@inner_block)}
      </.focus_wrap>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Delete-confirm affordance (ADR-016 §2 — destructive actions are interlocked)
  # ---------------------------------------------------------------------------

  @doc """
  The delete-confirm affordance: a danger-styled button carrying LiveView's built-in
  `data-confirm` interlock — the client MUST confirm before the `phx-click` event
  (pass `phx-click`/`phx-value-id`/`phx-target` via `:rest`) reaches the server, so a
  destructive action is never one accidental click away. The label defaults to
  "Delete" (override via the inner block).

  Keep `message` to static framework copy — don't interpolate field values into it
  (a `%Masked{}` does not belong in an HTML attribute).
  """
  attr :message, :string, default: "Delete this record? This cannot be undone."
  attr :label, :string, default: "Delete"
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block

  def delete_confirm(assigns) do
    ~H"""
    <button
      type="button"
      class="btn danger"
      data-confirm={@message}
      style="color:var(--bad, #b91c1c);border-color:var(--bad, #b91c1c)"
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@label}
      <% end %>
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Pill (status badge)
  # ---------------------------------------------------------------------------

  @doc """
  A status pill. `variant` selects the color scheme
  (`ok | warn | bad | info | mut`). The label is the default inner block — it
  renders WHATEVER value it is handed, including a `%Samen.Masked{}` (→ `••••`).
  The kit adds no unmasking here.
  """
  attr :variant, :string, default: "mut", values: ~w(ok warn bad info mut)
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class={["pill", @variant]}>
      <span class="d"></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # Object-unfurl card (ADR-012 §4.4 — the crown jewel's renderer)
  # ---------------------------------------------------------------------------

  @doc """
  The **object-unfurl card** — renders a `%Samen.Web.ObjectRef.Card{}` produced by
  `Samen.Web.ObjectRef.resolve/3` (ADR-012 §4). Given a resolved card (or a resolver
  `{:error, reason}`), it renders a compact live preview of a catalogued object.

  ## Masking BY CONSTRUCTION (the crown-jewel invariant)

  Every value on the card is the resolver's ALREADY-RESOLVED field — a plaintext string on the
  tenant plane, a `%Masked{}` on the operator plane. This component renders each value
  verbatim via `{...}`, so a `%Masked{}` renders `••••` through `Phoenix.HTML.Safe` (the
  `Samen.Masked` impl). It has NO unmasking branch, never reveals through the kernel vault, and
  never pulls a mask apart to read its inner value. The SAME card, resolved for two viewers,
  therefore renders CLEAR for the owning tenant and `••••` for the operator with zero
  per-viewer code here.

  ## Error / not-available state (no leak)

  Passed `{:error, :not_found}` / `:unknown_key` / `:forbidden`, it renders an INERT
  "not available" chip — the same rendering for a nonexistent id and a cross-org id (no
  existence oracle, no PII). A resolver failure NEVER downgrades to plaintext.
  """
  attr :card, :any, required: true, doc: "a %Samen.Web.ObjectRef.Card{} or {:error, reason}"

  def object_card(%{card: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <span class="obj-card obj-card-na" data-obj-error={to_string(@reason)}>
      <span class="obj-na-icon">∅</span>
      <span class="obj-na-text">Object not available</span>
    </span>
    """
  end

  def object_card(%{card: %Samen.Web.ObjectRef.Card{}} = assigns) do
    ~H"""
    <span class="obj-card" data-obj-key={@card.key} data-obj-id={@card.id}>
      <span class="obj-card-avatar">{@card.icon || "•"}</span>
      <span class="obj-card-body">
        <span class="obj-card-kicker">{@card.subtitle || @card.key}</span>
        <span class="obj-card-title">
          <%= if @card.href do %>
            <a href={@card.href} class="obj-card-link">{@card.title}</a>
          <% else %>
            {@card.title}
          <% end %>
        </span>
        <span :if={@card.badges != []} class="obj-card-badges">
          <.pill :for={{variant, label} <- @card.badges} variant={pill_variant(variant)}>{label}</.pill>
        </span>
        <span :if={@card.fields != []} class="obj-card-fields">
          <span :for={{label, value} <- @card.fields} class="obj-card-field">
            <span class="obj-card-field-label">{label}</span>
            <span class="obj-card-field-value">{value}</span>
          </span>
        </span>
      </span>
    </span>
    """
  end

  def object_card(assigns) do
    ~H"""
    <span class="obj-card obj-card-na"><span class="obj-na-text">Object not available</span></span>
    """
  end

  # Card badge variants may arrive as atoms (from DefaultCard) or strings (from override
  # cards). Normalize to the `.pill` variant vocabulary; anything unknown → "mut".
  defp pill_variant(v) when v in ["ok", "warn", "bad", "info", "mut"], do: v
  defp pill_variant(v) when is_atom(v), do: pill_variant(Atom.to_string(v))
  defp pill_variant(_), do: "mut"

  # ---------------------------------------------------------------------------
  # Progress bar
  # ---------------------------------------------------------------------------

  @doc """
  A progress bar. `value` (0-100) sets the fill width; `label` is the right-aligned
  readout (a dollar amount, a health word, …). `color` is a CSS color for the fill
  (default the brand green). Renders `label` verbatim — a `%Masked{}` label shows
  `••••`.
  """
  attr :value, :integer, default: 0
  attr :label, :any, default: nil
  attr :color, :string, default: "var(--green)"

  def progress(assigns) do
    assigns = assign(assigns, :pct, clamp(assigns.value))

    ~H"""
    <div class="prog">
      <div class="track">
        <div class="fill" style={"width:#{@pct}%;background:#{@color}"}></div>
      </div>
      <span :if={@label != nil} class="pct">{@label}</span>
    </div>
    """
  end

  defp clamp(v) when is_integer(v), do: v |> max(0) |> min(100)
  defp clamp(_), do: 0

  # ---------------------------------------------------------------------------
  # Metric card
  # ---------------------------------------------------------------------------

  @doc """
  A metric card. `label` is the small key, `value` the large number. `delta` is an
  optional signed change; `delta_dir` (`up | down`) colors it. `sub` is optional
  sub-text under the value. `spark` is an optional list of 0-100 heights for the
  sparkline (the last bar is highlighted). An optional `:icon` slot leads the label.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :delta, :string, default: nil
  attr :delta_dir, :string, default: "up", values: ~w(up down)
  attr :sub, :string, default: nil
  attr :spark, :list, default: []
  slot :icon

  def metric(assigns) do
    ~H"""
    <div class="metric">
      <div class="k">
        <span :if={@icon != []} class="i">{render_slot(@icon)}</span>
        {@label}
      </div>
      <div class="v">
        <span class="num">{@value}</span>
        <span :if={@delta} class={["delta", @delta_dir]}>{@delta}</span>
      </div>
      <div :if={@sub} class="sub">{@sub}</div>
      <div :if={@spark != []} class="spark">
        <%= for {h, idx} <- Enum.with_index(@spark) do %>
          <i class={idx == length(@spark) - 1 && "hi"} style={"height:#{clamp(h)}%"}></i>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Banner: masked impersonation (mask-bar)
  # ---------------------------------------------------------------------------

  @doc """
  The masked-impersonation banner. The default inner block is the explanatory copy
  (use `<b>` for emphasis); `chip` is the right-aligned monospace status
  (e.g. session TTL + reason). Renders content verbatim.
  """
  attr :chip, :string, default: nil
  slot :inner_block, required: true

  def mask_bar(assigns) do
    ~H"""
    <div class="mask-bar">
      <div class="ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9">
          <rect x="4" y="10" width="16" height="10" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" />
        </svg>
      </div>
      <div class="tx">{render_slot(@inner_block)}</div>
      <div :if={@chip} class="chip">{@chip}</div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Banner: token-blind aggregate (tb-bar)
  # ---------------------------------------------------------------------------

  @doc """
  The token-blind aggregate banner. The default inner block is the copy; `chip` is
  the right-aligned monospace privacy summary (e.g. `no reveal path · k ≥ 5`).
  """
  attr :chip, :string, default: nil
  slot :inner_block, required: true

  def token_blind_bar(assigns) do
    ~H"""
    <div class="tb-bar">
      <div class="ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9">
          <path d="M4 19V9m6 10V5m6 14v-7" />
        </svg>
      </div>
      <div class="tx">{render_slot(@inner_block)}</div>
      <div :if={@chip} class="chip">{@chip}</div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Activity timeline (ADR-011 §6.2) — pure presentational, host-agnostic
  # ---------------------------------------------------------------------------

  @doc """
  The activity timeline (ADR-011 §6.2). A vertical rail of typed activity entries —
  each entry a per-type glyph (call · email · meeting · note · task), a `subject`
  title, a `status` pill, a `who / when` line, and the `body` as wrapped text.

  PURELY PRESENTATIONAL: it takes ALREADY-RESOLVED data (a list of plain maps) and
  renders it. It NEVER reads a resource, NEVER touches the vault, and NEVER knows
  about writes — the optional `:composer` slot lets a detail page drop a
  log-activity form ABOVE the rail without the component knowing anything about the
  write path. This makes it trivially unit-testable and inherited by every vertical
  (a future account timeline can reuse it verbatim).

  `entries` is a list of maps: `%{type, subject, body, status, at, who}` — `type` and
  `status` are the bounded activity enums (atoms), `at` a `DateTime | nil`, `subject`
  / `body` / `who` strings. A `%Samen.Masked{}` in any slot renders `••••` verbatim.
  """
  attr :entries, :list, required: true
  attr :empty, :string, default: "No activity yet."
  slot :composer

  def timeline(assigns) do
    ~H"""
    <div class="tl">
      <div :if={@composer != []} class="tl-composer">
        {render_slot(@composer)}
      </div>

      <div :if={@entries == []} class="tl-empty" style="padding:22px 20px;color:var(--muted)">
        {@empty}
      </div>

      <div :if={@entries != []} class="tl-rail">
        <div :for={e <- @entries} class="tl-entry" id={timeline_entry_id(e)}>
          <div class={"tl-glyph tl-#{timeline_type(e)}"} style="width:30px;height:30px;border-radius:50%;display:flex;align-items:center;justify-content:center;flex-shrink:0">
            {timeline_glyph(timeline_type(e))}
          </div>
          <div class="tl-body" style="flex:1;min-width:0">
            <div class="tl-head" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:4px">
              <span class="tl-type" style="font-size:11px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.03em">{timeline_type_label(timeline_type(e))}</span>
              <span class="tl-subject" style="font-weight:600;font-size:13px;color:#2a2b35">{Map.get(e, :subject) || "—"}</span>
              <.pill variant={timeline_status_variant(Map.get(e, :status))}>{timeline_status_label(Map.get(e, :status))}</.pill>
            </div>
            <div :if={timeline_present?(Map.get(e, :body))} class="tl-text" style="font-size:13px;color:#3a3b45;line-height:1.55;white-space:pre-wrap;word-break:break-word;margin:2px 0 6px">
              {Map.get(e, :body)}
            </div>
            <div class="tl-meta" style="font-size:11px;color:var(--muted)">
              <span :if={timeline_present?(Map.get(e, :who))}>{Map.get(e, :who)} · </span>{timeline_dt(Map.get(e, :at))}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Timeline helpers (bounded enums; presentational only) ---------------------

  defp timeline_entry_id(%{id: id}) when not is_nil(id), do: "tl-entry-#{id}"
  defp timeline_entry_id(_), do: "tl-entry"

  defp timeline_type(%{type: type}), do: type
  defp timeline_type(_), do: :note

  defp timeline_type_label(:call), do: "Call"
  defp timeline_type_label(:email), do: "Email"
  defp timeline_type_label(:meeting), do: "Meeting"
  defp timeline_type_label(:note), do: "Note"
  defp timeline_type_label(:task), do: "Task"
  defp timeline_type_label(other), do: to_string(other || "note")

  # Inline SVG glyphs matching the kit's stroke style (1.8 stroke, currentColor).
  defp timeline_glyph(:call) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6 19.8 19.8 0 0 1-3.1-8.7A2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2Z"/></svg>)
    )
  end

  defp timeline_glyph(:email) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/></svg>)
    )
  end

  defp timeline_glyph(:meeting) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/></svg>)
    )
  end

  defp timeline_glyph(:note) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 3h11l5 5v13H4z"/><path d="M9 12h7M9 16h5M9 8h3"/></svg>)
    )
  end

  defp timeline_glyph(:task) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 6 9 17l-5-5"/></svg>)
    )
  end

  defp timeline_glyph(_), do: timeline_glyph(:note)

  defp timeline_status_variant(:completed), do: "ok"
  defp timeline_status_variant(:pending), do: "warn"
  defp timeline_status_variant(:cancelled), do: "mut"
  defp timeline_status_variant(_), do: "mut"

  defp timeline_status_label(:completed), do: "completed"
  defp timeline_status_label(:pending), do: "pending"
  defp timeline_status_label(:cancelled), do: "cancelled"
  defp timeline_status_label(nil), do: "logged"
  defp timeline_status_label(other), do: to_string(other)

  defp timeline_present?(%Samen.Masked{}), do: true
  defp timeline_present?(v) when is_binary(v), do: String.trim(v) != ""
  defp timeline_present?(_), do: false

  defp timeline_dt(%DateTime{} = dt),
    do: "#{dt.year}-#{tl_pad(dt.month)}-#{tl_pad(dt.day)} #{tl_pad(dt.hour)}:#{tl_pad(dt.minute)} UTC"

  defp timeline_dt(_), do: "—"

  defp tl_pad(n), do: String.pad_leading(to_string(n), 2, "0")

  # ---------------------------------------------------------------------------
  # Lifecycle-stage pill (ADR-011 §8) — Tier-1 custom-field convention
  # ---------------------------------------------------------------------------

  @doc """
  A prospecting lifecycle-stage pill (ADR-011 §8). `stage` is the Tier-1
  `person.custom["lifecycle_stage"]` value (a string in the bounded set
  `lead → mql → sql → customer → churned`). A nil/unknown stage renders nothing —
  a contact without a stage shows no pill. Purely presentational; the bounded set is
  a framework convention a vertical can style via CSS.
  """
  attr :stage, :any, default: nil

  def lifecycle_pill(assigns) do
    ~H"""
    <.pill :if={lifecycle_known?(@stage)} variant={lifecycle_variant(@stage)}>{lifecycle_label(@stage)}</.pill>
    """
  end

  @doc "The bounded framework lifecycle stages (ADR-011 §8)."
  def lifecycle_stages, do: ~w(lead mql sql customer churned)

  defp lifecycle_known?(stage) when is_binary(stage), do: stage in lifecycle_stages()
  defp lifecycle_known?(_), do: false

  defp lifecycle_variant("lead"), do: "info"
  defp lifecycle_variant("mql"), do: "info"
  defp lifecycle_variant("sql"), do: "warn"
  defp lifecycle_variant("customer"), do: "ok"
  defp lifecycle_variant("churned"), do: "bad"
  defp lifecycle_variant(_), do: "mut"

  defp lifecycle_label("lead"), do: "Lead"
  defp lifecycle_label("mql"), do: "MQL"
  defp lifecycle_label("sql"), do: "SQL"
  defp lifecycle_label("customer"), do: "Customer"
  defp lifecycle_label("churned"), do: "Churned"
  defp lifecycle_label(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Social links (ADR-011 §9) — Tier-1 custom-field convention, non-PII
  # ---------------------------------------------------------------------------

  @doc """
  Social handles as icon-links (ADR-011 §9). `custom` is the person's Tier-1 bag;
  the recognized flat keys are `social_linkedin`, `social_twitter`, `social_github`
  (each a URL/handle STRING — the kernel custom bag has no `:map` type, so social
  handles are flat string fields, not a nested map). Unknown/blank keys render
  nothing. Non-PII business-directory data (a public profile URL) — rendered on both
  planes. Purely presentational; reads the bag it is handed, writes nothing.
  """
  attr :custom, :any, default: nil

  def social_links(assigns) do
    assigns = assign(assigns, :links, social_entries(assigns.custom))

    ~H"""
    <span :if={@links != []} class="social-links" style="display:inline-flex;align-items:center;gap:8px">
      <a
        :for={{network, url} <- @links}
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        class={"social-#{network}"}
        title={social_label(network)}
        style="display:inline-flex;color:var(--muted)"
      >
        {social_glyph(network)}
      </a>
    </span>
    """
  end

  @doc "The recognized social networks (bag key `social_<network>`)."
  def social_networks, do: ~w(linkedin twitter github)

  defp social_entries(custom) when is_map(custom) do
    for network <- social_networks(),
        url = social_url(Map.get(custom, "social_#{network}")),
        url != nil,
        do: {network, url}
  end

  defp social_entries(_), do: []

  defp social_url(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp social_url(_), do: nil

  defp social_label("linkedin"), do: "LinkedIn"
  defp social_label("twitter"), do: "Twitter / X"
  defp social_label("github"), do: "GitHub"
  defp social_label(other), do: other

  defp social_glyph("linkedin") do
    Phoenix.HTML.raw(
      ~s(<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 11v5M8 8v.01M12 16v-3a2 2 0 0 1 4 0v3M12 16v-5"/></svg>)
    )
  end

  defp social_glyph("twitter") do
    Phoenix.HTML.raw(
      ~s(<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 4l16 16M20 4 4 20"/></svg>)
    )
  end

  defp social_glyph("github") do
    Phoenix.HTML.raw(
      ~s(<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.9a3.4 3.4 0 0 0-1-2.6c3-.3 6-1.5 6-6.6a5.1 5.1 0 0 0-1.4-3.5 4.8 4.8 0 0 0-.1-3.5s-1.1-.3-3.5 1.3a12 12 0 0 0-6 0C6.6 1.6 5.5 1.9 5.5 1.9a4.8 4.8 0 0 0-.1 3.5A5.1 5.1 0 0 0 4 8.9c0 5.1 3 6.3 6 6.6a3.4 3.4 0 0 0-1 2.6V22"/></svg>)
    )
  end

  defp social_glyph(_), do: Phoenix.HTML.raw("")
end
