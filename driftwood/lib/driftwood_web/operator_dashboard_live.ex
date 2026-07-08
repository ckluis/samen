defmodule DriftwoodWeb.OperatorDashboardLive do
  @moduledoc """
  The OPERATOR aggregate plane (T5.3 clause (b); T4.2 mounted over Driftwood) — the
  token-blind cross-tenant dashboard. It reads ONLY through `Driftwood.OperatorDashboard`
  (which reads ONLY through the token-blind aggregate domain with the singleton aggregate
  actor). It shows cross-tenant LOAD VOLUME by lane + brokerage MRR by tier, with NO PII —
  there is no tenant-plane read here, no impersonation session, no reveal.

  This is the mutually-exclusive path from masked impersonation: an operator either opens a
  single-tenant masked session (PII ••••) OR reads this cross-tenant aggregate (no subject
  at all). k-anonymity-suppressed cells render `⊘`.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Driftwood.OperatorDashboard

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    {:ok, lv} = OperatorDashboard.load_volume()
    {:ok, mrr} = OperatorDashboard.mrr()
    assign(socket, load_volume: lv, mrr: mrr)
  end

  defp dollars(cents) when is_integer(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp dollars(_), do: "$0.00"

  defp cell(%Samen.Aggregate.Suppressed{}), do: "⊘"
  defp cell(nil), do: "⊘"
  defp cell(n) when is_integer(n), do: Integer.to_string(n)

  defp money_cell(%Samen.Aggregate.Suppressed{}), do: "⊘"
  defp money_cell(nil), do: "⊘"
  defp money_cell(n) when is_integer(n), do: "$#{:erlang.float_to_binary(n / 100, decimals: 2)}"

  # Number of tenant cohorts suppressed below the k-anonymity floor (lanes + tiers).
  defp suppressed_count(lv, mrr) do
    length(Map.get(lv, :suppressed_lanes, [])) + length(Map.get(mrr, :suppressed_tiers, []))
  end

  # Distinct tenant count for the "Active tenants" metric: the max cohort size across
  # tiers (each tenant sits in exactly one tier, so summing tier tenant_counts gives the
  # portfolio size; suppressed cohorts are skipped to avoid re-leaking a small cohort).
  defp active_tenants(mrr) do
    Enum.reduce(mrr.by_tier, 0, fn r, acc ->
      if match?(%Samen.Aggregate.Suppressed{}, r.tenant_count), do: acc, else: acc + (r.tenant_count || 0)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-aggregate">
      <.app_shell>
        <:sidebar>
          <.sidebar title="Driftwood Ops" subtitle="Operator control plane">
            <:search>
              <div class="search">
                <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
                </svg>
                Search tenants, drivers…
                <span class="kbd">⌘K</span>
              </div>
            </:search>

            <.nav_group label="Operator plane">
              <.nav_item label="Tenants" href="/operator/aggregate" count={active_tenants(@mrr)}>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
                </:icon>
              </.nav_item>
              <.nav_item label="Impersonation" href="/operator/impersonate">
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3a9 9 0 1 0 9 9" /><path d="M12 7v5l3 2" /></svg>
                </:icon>
              </.nav_item>
              <.nav_item label="Aggregate · MRR" href="/operator/aggregate" active>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9m6 10V5m6 14v-7" /></svg>
                </:icon>
              </.nav_item>
            </.nav_group>

            <:footer>
              <div class="foot">
                <div class="av">CK</div>
                <div class="m"><b>C. Kluis</b><span>operator · admin role</span></div>
              </div>
            </:footer>
          </.sidebar>
        </:sidebar>

        <.topbar title="Portfolio" crumbs={["Operator plane", "Aggregate", "Portfolio"]}>
          <:actions>
            <.button>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v12m0 0l-4-4m4 4l4-4M4 21h16" /></svg>
              </:icon>
              Export
            </.button>
          </:actions>
        </.topbar>

        <.token_blind_bar chip="no reveal path · k ≥ 5 · l-diversity">
          <b>Token-blind aggregate plane.</b>
          This actor has <b>no pii_ column</b> in its domain by construction — it reads a
          vault-excluded projection. Cohorts below the k-anonymity floor are suppressed.
        </.token_blind_bar>

        <div class="metrics">
          <.metric label="Portfolio MRR" value={dollars(@mrr.total_cents)} spark={[40, 52, 48, 63, 58, 71, 80]}>
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
            </:icon>
          </.metric>
          <.metric label="Active tenants" value={active_tenants(@mrr)} sub="org-level cohorts">
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /></svg>
            </:icon>
          </.metric>
          <.metric label="Loads / total" value={@load_volume.total_loads} spark={[30, 44, 52, 49, 66, 70, 84]}>
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 7h13l5 5v5H3z" /></svg>
            </:icon>
          </.metric>
          <.metric label="Total gross" value={dollars(@load_volume.total_gross_cents)} sub="across all lanes">
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 6L9 17l-5-5" /></svg>
            </:icon>
          </.metric>
        </div>

        <div class="wrap">
          <div class="gtitle">
            <h3>MRR by tier</h3><span class="n">{length(@mrr.by_tier)}</span>
            <span class="lane">· org-level aggregates only — no personal data</span>
          </div>
          <p id="mrr-total" style="display:none">Total MRR: {dollars(@mrr.total_cents)}</p>
          <div id="mrr-by-tier">
            <.data_table>
              <:head>
                <th style="width:40%">Plan tier</th>
                <th style="width:30%">Tenants</th>
                <th style="width:30%">MRR</th>
              </:head>
              <tr :for={r <- @mrr.by_tier} class="tier-row">
                <td class="mrr-tier">
                  <div class="drv">
                    <div class="av" style="background:#DFE6F6"></div>
                    <span class="nm" style="color:#3a3b45">{r.tier}</span>
                  </div>
                </td>
                <td class="mrr-tenants num">{r.tenant_count}</td>
                <td class="mrr-cents mono num" style="font-size:13.5px">{money_cell(r.mrr_cents)}</td>
              </tr>
              <tr :if={suppressed_count(@load_volume, @mrr) > 0}>
                <td colspan="3">
                  <div class="supp">
                    <svg class="lk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
                    {suppressed_count(@load_volume, @mrr)} cohorts below the k-anonymity floor — suppressed from these aggregates to prevent re-identification.
                  </div>
                </td>
              </tr>
            </.data_table>
          </div>

          <div class="gtitle">
            <h3>Load volume by lane</h3><span class="n">{length(@load_volume.by_lane)}</span>
            <span class="lane">· across all brokerages</span>
          </div>
          <p id="load-volume-total" style="display:none">
            Total loads: {@load_volume.total_loads} — total gross: {dollars(@load_volume.total_gross_cents)}
          </p>
          <div id="load-volume">
            <.data_table>
              <:head>
                <th style="width:34%">Lane</th>
                <th style="width:22%">Tenants</th>
                <th style="width:22%">Loads</th>
                <th style="width:22%">Gross</th>
              </:head>
              <tr :for={r <- @load_volume.by_lane} class="lane-row">
                <td class="lv-lane"><span class="mono">{r.lane}</span></td>
                <td class="lv-tenants num">{r.tenant_count}</td>
                <td class="lv-loads num">{cell(r.load_count)}</td>
                <td class="lv-gross mono num">{money_cell(r.gross_cents)}</td>
              </tr>
            </.data_table>
          </div>
        </div>
      </.app_shell>
    </div>
    """
  end
end
