defmodule DriftwoodWeb.UIKit do
  @moduledoc """
  The Samen product-UI kit — reusable HEEx function components that render the
  approved mockup design (ADR-008).

  These components pair with the `samen_ui.css` static asset
  (`priv/static/assets/samen_ui.css`, served at `/assets/samen_ui.css`): the CSS
  owns the tokens + component classes, the components own the markup that consumes
  them. A vertical that serves the stylesheet and calls these components inherits
  the identical look.

  ## Home / extractability (ADR-008)

  The kit lives in `driftwood_web` for now, namespaced so it does NOT touch
  `samen_core`'s kernel (which stays free of `phoenix_live_view` /
  `phoenix_component`, keeping its 842-test suite + verifier gate untouched).
  It is written to be extracted verbatim into a shared `samen_ui` path-dep lib
  once a second vertical (demo / pawchart) adopts it — Rule-of-Three. Nothing here
  imports a Driftwood domain module; the components take assigns only.

  ## Masking invariant (LOAD-BEARING)

  The kit introduces NO way to render plaintext PII that bypasses masking. A cell
  or pill simply renders whatever value it is handed via `{@value}` / its inner
  block. If handed a `%Samen.Masked{}`, HEEx renders it through the existing
  `Phoenix.HTML.Safe` protocol impl on `Samen.Masked`, which emits `••••`. The kit
  never calls `Samen.Vault.reveal/3`, never pattern-matches a token out of a
  `%Masked{}`, and never has a "show plaintext" branch. Plaintext only reaches a
  cell if the CALLER already resolved it through `Samen.Api.PiiResolution` /
  `Samen.Reveal` (the single vault chokepoint) — exactly as the existing
  broker/impersonation LiveViews do today. The kit is a dumb renderer of already
  plane-resolved values.

  ## Component index

    * `app_shell/1`      — the sidebar + main two-pane grid (slots: `:sidebar`, inner)
    * `sidebar/1`        — the sidebar container (workspace header + nav + footer slots)
    * `nav_group/1`      — a labelled group of nav items (`:label` + inner `nav_item`s)
    * `nav_item/1`       — one sidebar link (icon slot, `:active`, optional `:count`/`:dot`)
    * `topbar/1`         — breadcrumb + title + actions slot
    * `button/1`         — a `.btn` (default / `variant="primary"`)
    * `tabs/1` + `tab/1` — the underline tab bar
    * `data_table/1`     — `<table>` with a `:head` slot + inner rows
    * `pill/1`           — a status pill (`variant` in ok|warn|bad|info|mut)
    * `progress/1`       — the `.prog` bar (`value` 0-100, `label`, `color`)
    * `metric/1`         — a metric card (`:label`, `:value`, optional delta/sub/spark)
    * `mask_bar/1`       — the masked-impersonation banner
    * `token_blind_bar/1`— the token-blind aggregate banner
  """
  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # App shell
  # ---------------------------------------------------------------------------

  @doc """
  The two-pane app shell: a `:sidebar` slot on the left, the default inner block
  (the `<main>`) on the right. Mirrors `.app > .side + .main` from the mockups.
  """
  slot :sidebar, required: true
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="app">
      {render_slot(@sidebar)}
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
        <div class="col">⌄</div>
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
  The shared Driftwood module navigation — the single source of truth for the
  "freight 20% + inherited 80%" story in the sidebar. Renders four `nav_group/1`s:

    * **Operations** — the freight vertical (the 20% Driftwood builds).
    * **CRM** / **Billing** / **Support** — the inherited universal scopes (the 80%
      Driftwood inherits from the Samen foundry), each rendered as first-class UI.

  Every page that has a sidebar renders THIS component, so all three inherited
  modules are reachable from every module (including the `/broker` tenant console)
  without typing URLs. The `active` attr highlights the current page; pass one of
  `:dashboard | :loads | :roster | :settlements | :crm_companies | :crm_contacts |
  :crm_pipeline | :billing_overview | :billing_invoices | :billing_plans |
  :support_tickets` (or `nil` for no active item, e.g. a ticket detail page).

  `org_id` is threaded into every `href` so navigation preserves the dogfood
  `?org=` selector.
  """
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil

  def module_nav(assigns) do
    ~H"""
    <.nav_group label="Operations">
      <.nav_item label="Dispatch board" href={"/broker?panel=dashboard&org=#{@org_id}"} active={@active == :dashboard}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="8" height="8" rx="1.5" /><rect x="13" y="3" width="8" height="8" rx="1.5" /><rect x="3" y="13" width="8" height="8" rx="1.5" /><rect x="13" y="13" width="8" height="8" rx="1.5" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Loads" href={"/broker?panel=loads&org=#{@org_id}"} active={@active == :loads}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 7h13l5 5v5H3z" /><circle cx="7.5" cy="17.5" r="1.5" /><circle cx="17.5" cy="17.5" r="1.5" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Drivers" href={"/broker?panel=roster&org=#{@org_id}"} active={@active == :roster}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Settlements" href={"/broker?panel=settlements&org=#{@org_id}"} active={@active == :settlements}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="CRM">
      <.nav_item label="Companies" href={"/crm/companies?org=#{@org_id}"} active={@active == :crm_companies}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Contacts" href={"/crm/contacts?org=#{@org_id}"} active={@active == :crm_contacts}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Pipeline" href={"/crm/pipeline?org=#{@org_id}"} active={@active == :crm_pipeline}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 3v18M12 6v15M19 9v12" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="Billing">
      <.nav_item label="Customers" href={"/billing?org=#{@org_id}"} active={@active == :billing_overview}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Invoices" href={"/billing/invoices?org=#{@org_id}"} active={@active == :billing_invoices}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M6 2h9l5 5v15H6z" /><path d="M9 12h7M9 16h7M9 8h3" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Plans" href={"/billing/plans?org=#{@org_id}"} active={@active == :billing_plans}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 10h18" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>

    <.nav_group label="Support">
      <.nav_item label="Tickets" href={"/support?org=#{@org_id}"} active={@active == :support_tickets}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>
    """
  end

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
  """
  slot :head, required: true
  slot :inner_block, required: true

  def data_table(assigns) do
    ~H"""
    <div class="card">
      <table>
        <thead>
          <tr>{render_slot(@head)}</tr>
        </thead>
        <tbody>
          {render_slot(@inner_block)}
        </tbody>
      </table>
    </div>
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
end
