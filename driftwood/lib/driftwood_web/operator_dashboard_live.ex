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

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-aggregate">
      <h1>Operator Console — Cross-tenant Aggregate (token-blind, NO PII)</h1>

      <h2>Load volume by lane (across all brokerages)</h2>
      <p id="load-volume-total">
        Total loads: {@load_volume.total_loads} — total gross: {dollars(@load_volume.total_gross_cents)}
      </p>
      <table id="load-volume">
        <thead><tr><th>Lane</th><th>Tenants</th><th>Loads</th><th>Gross</th></tr></thead>
        <tbody>
          <%= for r <- @load_volume.by_lane do %>
            <tr class="lane-row">
              <td class="lv-lane">{r.lane}</td>
              <td class="lv-tenants">{r.tenant_count}</td>
              <td class="lv-loads">{cell(r.load_count)}</td>
              <td class="lv-gross">{money_cell(r.gross_cents)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <h2>MRR by tier (across all brokerages)</h2>
      <p id="mrr-total">Total MRR: {dollars(@mrr.total_cents)}</p>
      <table id="mrr-by-tier">
        <thead><tr><th>Tier</th><th>Tenants</th><th>MRR</th></tr></thead>
        <tbody>
          <%= for r <- @mrr.by_tier do %>
            <tr class="tier-row">
              <td class="mrr-tier">{r.tier}</td>
              <td class="mrr-tenants">{r.tenant_count}</td>
              <td class="mrr-cents">{money_cell(r.mrr_cents)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
