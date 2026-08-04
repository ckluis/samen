defmodule Samen.Web.CRM.CalendarLive do
  @moduledoc """
  Framework CRM / Calendar page — opportunities positioned by their `:close_date` on a month
  grid, the G2 CALENDAR view and the FIRST client of the generic
  `Samen.Web.Reads.calendar_by_day!/3` (T52/WS-G) rendered through `Samen.UI.calendar/1`.

  ## Framework-first (T52)

  This LiveView is THIN wiring over two framework primitives — it re-implements neither
  windowing/bucketing nor grid rendering:

    * READ — `Samen.Web.CRM.Reads.opportunity_calendar/3` builds a day-keyed
      `%Samen.Web.Board{}` via `calendar_by_day!/3`: Opportunities WINDOWED to the displayed
      month and bucketed by `:close_date` into ORDERED, per-day-BOUNDED columns, org-scoped by
      construction (unconditional OrgScope, inherited from `group_by!/3` — the T50 boundary).
    * RENDER — `Samen.UI.calendar/1` lays that `%Board{}` out as a month grid; this module
      supplies only the CRM-specific `:event` (opportunity name/value/status) and computes the
      month + prev/next navigation params. Any other domain reuses `calendar/1` with its own
      event slot at ≈0 LOC.

  ## No-JS navigation floor (ADR-042/T113)

  Month navigation is `?month=YYYY-MM` on this same route: prev/next render as real `<a href>`
  links, so a JS-off client changes months by ordinary GET (`handle_params/3` re-reads the
  window). The grid, each day's events, and each per-day count are all server-rendered — the
  calendar is not JS-only. A hostile/garbage `?month=` is parsed fail-safe to the current
  month (`Samen.UI.Calendar.parse_month/2`), never a crash.

  ## Masking

  Opportunities are NON-PII (no vault field on an event) and the date facet `:close_date` is
  non-vaulted (`calendar_by_day!/3` would REFUSE a vaulted date field via
  `Samen.Web.Reads.MaskedGroupKeyError`), so no event field masks and no per-plane masking
  proof is required for this surface. Reads still ride Ash/OrgScope.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.UI.Calendar
  alias Samen.Web.Board
  alias Samen.Web.CRM.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    month = Calendar.parse_month(Map.get(params, "month"), Date.utc_today())
    {:ok, load(assign(socket, org_id: org_id, month: month), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    month = Calendar.parse_month(Map.get(params, "month"), socket.assigns[:month] || Date.utc_today())
    {:noreply, load(assign(socket, org_id: org_id, month: month, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, org_id, month \\ nil)

  def load(socket, nil, month) do
    month = month || socket.assigns[:month] || Date.utc_today()

    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      month: Calendar.first_of_month(month),
      board: %Board{groups: [], group_field: :close_date},
      total_opps: 0
    )
    |> assign_nav_hrefs(nil)
  end

  def load(socket, org_id, month) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    month = Calendar.first_of_month(month || socket.assigns[:month] || Date.utc_today())

    %{board: board} = Reads.opportunity_calendar(mount, scope, month)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      month: month,
      board: board,
      total_opps: total_opps(board)
    )
    |> assign_nav_hrefs(org_id)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  # The no-JS prev/next month links — real `?org=&month=YYYY-MM` GETs on this same route.
  defp assign_nav_hrefs(socket, org_id) do
    month = socket.assigns.month

    assign(socket,
      prev_href: month_href(org_id, Calendar.prev_month(month)),
      next_href: month_href(org_id, Calendar.next_month(month))
    )
  end

  defp month_href(org_id, %Date{} = month) do
    org = if org_id, do: "org=#{org_id}&", else: ""
    "?#{org}month=#{month_param(month)}"
  end

  defp month_param(%Date{year: y, month: m}), do: "#{y}-#{String.pad_leading(to_string(m), 2, "0")}"

  defp total_opps(%Board{groups: groups}),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + (g.count || length(g.rows)) end)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-calendar">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_calendar} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Calendar" crumbs={crumbs(@samen_mount, @org_id, "Calendar")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Opportunities this month" value={@total_opps} sub="by close date">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="17" rx="2" /><path d="M3 9h18M8 2v4M16 2v4" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <.calendar
              id="crm-cal"
              board={@board}
              month={@month}
              prev_href={@prev_href}
              next_href={@next_href}
              empty_cell_text=""
            >
              <:event :let={opp}>
                <div class="opp-ev" id={"opp-#{opp.id}"}>
                  <span class="mono opp-ev-name">{opp.name}</span>
                  <span class="opp-ev-meta">
                    <span class="mono num">{dollars(opp.value)}</span>
                    <.pill variant={status_variant(opp.status)}>{opp.status}</.pill>
                  </span>
                </div>
              </:event>
            </.calendar>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", leaf]

  defp status_variant(:open), do: "info"
  defp status_variant(:won), do: "ok"
  defp status_variant(:lost), do: "bad"
  defp status_variant(:on_hold), do: "warn"
  defp status_variant(s) when is_binary(s), do: status_variant(String.to_atom(s))
  defp status_variant(_), do: "mut"

  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
