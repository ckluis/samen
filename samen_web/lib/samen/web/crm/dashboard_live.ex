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

  ## T76/I3 — conversion, win-rate, activity leaderboard

  Three more G8 tiles, ALL built on the same `Samen.Web.CRM.Reads.crm_dashboard/3` call (no
  extra round trip): `:rates` (`pipeline_rates/2` — win-rate on a CLOSED-deals basis, conversion
  on an ALL-CREATED basis; see that function's doc for why the two denominators intentionally
  differ) rendered as two more `metric/1` tiles, and `:leaderboard`
  (`activity_leaderboard/3` — org members ranked by CRM-anchored activity volume) rendered via
  `data_table/1`. Both rates are `nil` (rendered "—") rather than a fabricated `0%` when their
  denominator is zero (honest-empty), and BOTH tiles disclose their raw denominator alongside
  the percentage (fix round 1, LOW-3 — symmetric disclosure). The leaderboard's `owner_id` is a
  plain, structurally non-vaulted uuid (`Task.owner_id` — see `activity_leaderboard/3`'s doc);
  this tile renders it directly and never calls `Samen.Api.PiiResolution` — there is no vault
  field on this path. `activity_leaderboard/3` ranks BEFORE capping (fix round 1, MED-1) — this
  tile renders the `:capped`/`:hidden_owners`/`:hidden_count` disclosure whenever it binds,
  mirroring `Samen.UI.Map`'s `geo-map-capped` idiom (a visible `data-capped="true"` paragraph,
  not a silently-truncated table).
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
    stats: %{companies: 0, contacts: 0, open_opps: 0, pipeline_value: nil},
    # T76/I3 — honest-empty defaults: nil rates (never a fabricated 0%), an empty leaderboard.
    rates: %{win_rate: nil, conversion_rate: nil, won: 0, lost: 0, open: 0, on_hold: 0},
    leaderboard: %{rows: [], capped: false, shown: 0, hidden_owners: 0, hidden_count: 0}
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

            <%!-- T76/I3 — win-rate (closed-deals basis) + conversion-rate (all-created basis).
                 See Samen.Web.CRM.Reads.pipeline_rates/2 for the two denominators; a nil rate
                 (no closed/no created deals yet) renders "—", never a fabricated 0%. Fix round
                 1 LOW-3: both tiles disclose their raw denominator, symmetrically. --%>
            <:tile title="Win rate">
              <.metric label="Win rate" value={pct(@dash.rates.win_rate)} sub={"#{@dash.rates.won} won / #{@dash.rates.won + @dash.rates.lost} closed"} />
            </:tile>
            <:tile title="Conversion rate">
              <.metric label="Conversion" value={pct(@dash.rates.conversion_rate)} sub={"#{@dash.rates.won} won / #{@dash.rates.won + @dash.rates.lost + @dash.rates.open + @dash.rates.on_hold} created"} />
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

            <%!-- T76/I3 — activity leaderboard: org members ranked by CRM-anchored activity
                 volume (Samen.Web.CRM.Reads.activity_leaderboard/3). owner_id is a plain,
                 structurally non-vaulted uuid (see that function's doc) — rendered directly,
                 never resolved through the vault. Fix round 1 MED-1: ranked BEFORE capped, so
                 the true top performer always appears; the cap — when it binds — is DISCLOSED
                 (mirrors Samen.UI.Map's geo-map-capped idiom), never silently swallowed. --%>
            <:tile title="Activity leaderboard" span={2}>
              <div id="dash-leaderboard">
                <%= if @dash.leaderboard.rows == [] do %>
                  <p class="chart-empty">No activity yet</p>
                <% else %>
                  <.data_table>
                    <:head>
                      <th>Rank</th>
                      <th>Owner</th>
                      <th>Activities</th>
                    </:head>
                    <tr :for={row <- @dash.leaderboard.rows} id={"lb-row-#{row.rank}"} data-owner-id={row.owner_id}>
                      <td>{row.rank}</td>
                      <td class="ov-name">{owner_label(row.owner_id)}</td>
                      <td>{row.count}</td>
                    </tr>
                  </.data_table>
                  <p :if={@dash.leaderboard.capped} class="chart-empty" data-capped="true">
                    Showing the top {@dash.leaderboard.shown} members —
                    {hidden_owners_text(@dash.leaderboard.hidden_owners)} more member(s),
                    {@dash.leaderboard.hidden_count} more activities not shown.
                  </p>
                <% end %>
              </div>
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

  # T76/I3 — a rate is a fraction 0.0..1.0 or nil (honest-empty: no closed/created deals
  # yet). nil renders "—", never a fabricated "0.0%".
  defp pct(nil), do: "—"
  defp pct(rate) when is_float(rate) or is_integer(rate),
    do: "#{:erlang.float_to_binary(rate * 100 / 1, decimals: 1)}%"

  defp pct(_), do: "—"

  # T76/I3 — the leaderboard's owner label. `owner_id` is a plain, non-vaulted uuid (see
  # `Samen.Web.CRM.Reads.activity_leaderboard/3`'s doc) — there is no name to resolve, so
  # this renders a short, stable, non-secret id chip. NEVER calls PiiResolution/reveal.
  defp owner_label(nil), do: "—"
  defp owner_label(owner_id) when is_binary(owner_id), do: "Member " <> String.slice(owner_id, 0, 8)
  defp owner_label(other), do: to_string(other)

  # T76/I3 fix round 1 (MED-1) — `hidden_owners` is EXACT when the discovery pool was NOT
  # capped (the common case), `nil` (honest-unknown, mirrors geo_markers!/3's capped_count
  # idiom) when it WAS. Never renders a fabricated number either way.
  defp hidden_owners_text(nil), do: "some"
  defp hidden_owners_text(n) when is_integer(n), do: to_string(n)
end
