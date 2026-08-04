defmodule Samen.UI.Nav do
  @moduledoc """
  Navigation primitives of the `Samen.UI` kit: `sidebar/1`, `nav_group/1`,
  `nav_item/1`, the inherited `module_nav/1`, `topbar/1`, and the `tabs/1` + `tab/1`
  bar. Split out of the `Samen.UI` god-module (behaviour-identical); `module_nav/1`
  composes `nav_group/1`/`nav_item/1` as SIBLINGS in this same module. `Samen.UI`
  re-exports each via `defdelegate`.
  """
  use Phoenix.Component

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
    * `active`   — one of `:crm_companies | :crm_contacts | :crm_pipeline | :crm_calendar |
      :billing_overview | :billing_invoices | :billing_dunning | :billing_plans |
      :support_tickets` (or `nil`).
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
      <.nav_item label="Calendar" href={"#{@crm_path}/calendar?org=#{@org_id}"} active={@active == :crm_calendar}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="17" rx="2" /><path d="M3 9h18M8 2v4M16 2v4" /></svg>
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
      <.nav_item label="Dunning" href={"#{@billing_path}/dunning?org=#{@org_id}"} active={@active == :billing_dunning}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>
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
end
