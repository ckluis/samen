defmodule Samen.UI.Nav do
  @moduledoc """
  Navigation primitives of the `Samen.UI` kit: `sidebar/1`, `nav_group/1`,
  `nav_item/1`, the inherited `module_nav/1`, `topbar/1`, and the `tabs/1` + `tab/1`
  bar. Split out of the `Samen.UI` god-module (behaviour-identical); `module_nav/1`
  composes `nav_group/1`/`nav_item/1` as SIBLINGS in this same module. `Samen.UI`
  re-exports each via `defdelegate`.
  """
  use Phoenix.Component

  alias Samen.Web.Mount

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
      :crm_dashboard | :crm_mailbox | :crm_sequences | :billing_overview | :billing_invoices |
      :billing_dunning | :billing_plans | :support_tickets | :settings | :automation` (or `nil`).
    * `crm_path` / `billing_path` / `support_path` — the mount path prefix per module
      (default `/crm`, `/billing`, `/support`). A host that mounted CRM at `/customers`
      passes `crm_path: "/customers"`.
    * `settings_path` / `automation_path` — the mount path prefix for the Settings (PP-8) /
      Automation (PP-9) surfaces (default `/settings`, `/automation`) — both real shipped
      framework surfaces that otherwise have NO nav entry anywhere (they were total nav
      islands, hand-typed-URL-only).

  The `:extra` slot renders BEFORE the inherited groups — a host puts its vertical-specific
  nav groups (e.g. freight "Operations") there. The inherited nav is the framework's; the
  20% nav is the vertical's. See `host_nav_extra/1` for a DATA-driven way to populate this
  slot identically from every framework sidebar (PP-10).
  """
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :crm_path, :string, default: "/crm"
  attr :billing_path, :string, default: "/billing"
  attr :support_path, :string, default: "/support"
  attr :marketing_path, :string, default: "/marketing"
  attr :notifications_path, :string, default: "/notifications"
  attr :settings_path, :string, default: "/settings"
  attr :automation_path, :string, default: "/automation"

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
      <.nav_item label="Dashboard" href={"#{@crm_path}/dashboard?org=#{@org_id}"} active={@active == :crm_dashboard}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V10M12 19V5M20 19v-7" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Mailbox" href={"#{@crm_path}/mailbox?org=#{@org_id}"} active={@active == :crm_mailbox}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 7l9 6 9-6" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Sequences" href={"#{@crm_path}/sequences?org=#{@org_id}"} active={@active == :crm_sequences}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h13M4 12h13M4 18h9" /><circle cx="20" cy="6" r="1.6" /><circle cx="20" cy="12" r="1.6" /></svg>
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
      <.nav_item label="Knowledge base" href={"#{@support_path}/kb?org=#{@org_id}"} active={@active == :support_kb}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" /><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" /></svg>
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

    <.nav_group label="Workspace">
      <.nav_item label="Settings" href={"#{@settings_path}?org=#{@org_id}"} active={@active == :settings}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.55V21a2 2 0 1 1-4 0v-.09A1.7 1.7 0 0 0 9 19.4a1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.55-1H3a2 2 0 1 1 0-4h.09A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.55V3a2 2 0 1 1 4 0v.09a1.7 1.7 0 0 0 1 1.55 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.7 1.7 0 0 0 19.4 9a1.7 1.7 0 0 0 1.55 1H21a2 2 0 1 1 0 4h-.09a1.7 1.7 0 0 0-1.55 1z" /></svg>
        </:icon>
      </.nav_item>
      <.nav_item label="Automation" href={"#{@automation_path}?org=#{@org_id}"} active={@active == :automation}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M13 2 3 14h7l-1 8 10-12h-7l1-8Z" /></svg>
        </:icon>
      </.nav_item>
    </.nav_group>
    """
  end

  # ---------------------------------------------------------------------------
  # Host nav extra (PP-10) — data-driven vertical nav, rendered identically from
  # every framework sidebar
  # ---------------------------------------------------------------------------

  @doc """
  PP-10 (Batch 3 NAV-REACHABILITY) — renders a HOST's own vertical-specific nav group
  (e.g. driftwood's freight "Operations") from DATA, so it appears consistently on every
  framework-mounted tenant sidebar, not only the host's own bespoke page (`BrokerLive`
  previously rendered "Operations" itself via `module_nav`'s `:extra` slot, but nothing
  else did — the group vanished the instant a tenant left `/broker`).

  A host opts in via the `:host_nav_extra` mount label — `{mod, fun, args}`, called as
  `apply(mod, fun, args ++ [org_id])` — the SAME "host supplies DATA, framework renders
  it" pattern as `:object_cards` (`Samen.Web.ObjectRef.Registry`) / `:aggregate_loader`
  (ADR-009): a session-safe MFA, never a closure. Expected return shape:

      %{label: "Operations", items: [%{label: "Dispatch board", href: "/broker?org=..."}]}

  Absent the label, an erroring resolver, or a malformed return → renders nothing
  (fail-safe, mirrors `ObjectRef.Registry.card_for/4`'s rescue-to-default posture — a host
  nav bug never breaks the inherited sidebar). Place inside `module_nav/1`'s `:extra` slot:

      <.module_nav org_id={@org_id} active={@active}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>
  """
  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil

  def host_nav_extra(assigns) do
    assigns = assign(assigns, :group, host_nav_extra_data(assigns.mount, assigns.org_id))

    ~H"""
    <.nav_group :if={@group} label={@group.label}>
      <.nav_item :for={item <- @group.items} label={item.label} href={item.href} />
    </.nav_group>
    """
  end

  defp host_nav_extra_data(mount, org_id) do
    case Mount.label(mount, :host_nav_extra, nil) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        case apply(mod, fun, args ++ [org_id]) do
          %{label: label, items: items} = group when is_binary(label) and is_list(items) -> group
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
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
