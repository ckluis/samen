defmodule Samen.Web.CRM.DashboardLive do
  @moduledoc """
  Framework CRM / Dashboard page — the tenant-plane analytics dashboard (G8, T56) and the FIRST
  client of the generic chart/dashboard kit (`Samen.Web.Reads.aggregate_by!/3` +
  `time_series!/3` → `Samen.UI.dashboard/1` + `bar_chart/1` / `pie_chart/1` / `line_chart/1`).

  ## Framework-first (T56)

  This LiveView is THIN wiring over the framework primitives — it re-implements neither
  aggregation nor charting:

    * READ — `Samen.Web.CRM.Reads.crm_dashboard/2` builds three `%Samen.Web.Series{}` (pipeline
      value by stage, opportunities by status, opportunities closing over time) via the generic
      aggregate primitives: every slice a DB aggregate (`Ash.count!`/`Ash.sum!`), org-scoped by
      construction, bounded to a capped slice/bucket set — no rows ever leave Postgres.
    * RENDER — `Samen.UI.dashboard/1` lays out the tiles; `metric/1` renders the stat cards;
      `bar_chart/1` / `pie_chart/1` / `line_chart/1` render each `%Series{}` as server-computed
      inline SVG with an accessible table fallback. Any domain reuses these at ≈0 authored LOC.

  ## Masking / aggregate-leak posture

  Opportunities are NON-PII: the aggregated facets (`:pipeline_id`, `:status`, `:close_date`)
  and the summed measure (`:value`) are all non-vaulted, so no chart label/axis/tooltip and no
  summed number can expose a secret. This is VERIFIED refutably in the tests (anchored against
  the vaulted `Person.full_name`), and the primitives REFUSE a vault-routed dimension
  (`MaskedGroupKeyError`) or a vault-routed SUM/AVG measure (`MaskedMeasureError`) by
  construction — that unconditional refusal, not any option, is the disclosure guarantee.

  ## No-JS floor

  The dashboard grid, every stat tile, and every chart's SVG geometry + data table are all in
  the server-rendered DOM — legible with JS off, no external charting CDN.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CRM.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Series

  @empty %{
    value_by_stage: %Series{points: [], measure: {:sum, :value}, dimension: :pipeline_id},
    by_status: %Series{points: [], measure: :count, dimension: :status},
    closing_over_time: %Series{points: [], measure: :count, dimension: :bucket},
    stats: %{companies: 0, contacts: 0, open_opps: 0, pipeline_value: nil}
  }

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, dash: @empty)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    dash = safe_dashboard(mount, scope)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, dash: dash)
  end

  defp safe_dashboard(mount, scope), do: Reads.crm_dashboard(mount, scope)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-dashboard">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_dashboard} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Dashboard" crumbs={crumbs(@samen_mount, @org_id, "Dashboard")} />
        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <.dashboard id="crm-dash-grid">
            <:tile title="Companies">
              <.metric label="Companies" value={@dash.stats.companies} />
            </:tile>
            <:tile title="Contacts">
              <.metric label="Contacts" value={@dash.stats.contacts} />
            </:tile>
            <:tile title="Open opportunities">
              <.metric label="Open" value={@dash.stats.open_opps} />
            </:tile>
            <:tile title="Pipeline value">
              <.metric label="Value" value={dollars(@dash.stats.pipeline_value)} sub="open pipeline" />
            </:tile>

            <:tile title="Pipeline value by stage" span={2}>
              <.bar_chart id="dash-value-by-stage" series={@dash.value_by_stage} format={&money_cents/1} />
            </:tile>

            <:tile title="Opportunities by status">
              <.pie_chart id="dash-by-status" series={@dash.by_status} />
            </:tile>

            <:tile title="Closing over time" span={2}>
              <.line_chart id="dash-closing-over-time" series={@dash.closing_over_time} />
            </:tile>
          </.dashboard>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", leaf]

  # A value-by-stage slice's `value` is a Money sum in cents → dollars.
  defp money_cents(%Series.Point{value: cents}) when is_integer(cents), do: dollars_cents(cents)
  defp money_cents(%Series.Point{value: v}), do: to_string(v)

  defp dollars(%Money{} = money), do: dollars_cents(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents), do: dollars_cents(cents)
  defp dollars(_), do: "$0"

  defp dollars_cents(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars_cents(_), do: "$0.00"
end
