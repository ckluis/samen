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
  slot :extra

  def module_nav(assigns) do
    ~H"""
    {render_slot(@extra)}

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
