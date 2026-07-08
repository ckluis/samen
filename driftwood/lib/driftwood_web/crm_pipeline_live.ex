defmodule DriftwoodWeb.CrmPipelineLive do
  @moduledoc """
  CRM / Pipeline page — opportunities grouped by pipeline stage.

  Reads `Driftwood.Crm.Opportunity` + `Driftwood.Crm.Pipeline` (Tier-0 config
  rows) through `Driftwood.CrmReads.pipeline/1` on the TENANT plane. Opportunities
  are non-PII — no vault-routed fields — so no PiiResolution step is needed.

  The page renders a data_table per pipeline stage (Quoted → Booked → Dispatched →
  In-Transit → Delivered → Invoiced) containing the opportunities in that stage,
  with columns: opportunity name, value, status, and company reference. Only stages
  that have at least one opportunity are rendered.

  Org-scoped: both Pipeline and Opportunity policy gates enforce `OrgScope`.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Driftwood.CrmReads

  @impl true
  def mount(params, _session, socket) do
    org_id = Map.get(params, "org")
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id), org_id)}
  end

  @doc false
  def load(socket, nil) do
    assign(socket, no_org: true, org_id: nil, stages: [], total_value_cents: 0, total_opps: 0)
  end

  def load(socket, org_id) do
    scope = crm_scope(org_id)
    stages = CrmReads.pipeline(scope)

    total_value_cents =
      stages
      |> Enum.flat_map(& &1.opportunities)
      |> Enum.reduce(0, fn opp, acc -> acc + (opp.value_cents || 0) end)

    total_opps =
      stages
      |> Enum.map(& &1.opportunities)
      |> Enum.map(&length/1)
      |> Enum.sum()

    assign(socket,
      no_org: false,
      org_id: org_id,
      stages: stages,
      total_value_cents: total_value_cents,
      total_opps: total_opps
    )
  end

  # A tenant-member scope for CRM pipeline reads.
  @doc false
  def crm_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "broker:#{org_id}",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-pipeline">
      <.app_shell>
        <:sidebar>
          {crm_sidebar(assigns)}
        </:sidebar>

        <.topbar title="Pipeline" crumbs={["Blue Ridge Logistics", "CRM", "Pipeline"]}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New opportunity
            </.button>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Pipeline stages" value={length(@stages)}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M5 3v18M12 6v15M19 9v12" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Opportunities" value={@total_opps}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Pipeline value" value={dollars(@total_value_cents)} sub="all stages">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="pipeline">
              <%= if @stages == [] do %>
                <div class="card" style="padding:22px 20px;color:var(--muted)">
                  No pipeline stages with opportunities yet. Run seeds to populate.
                </div>
              <% else %>
                <%= for %{stage: stage, opportunities: opps} <- @stages do %>
                  <div class="gtitle" id={"stage-#{stage.name}"}>
                    <h3>{stage.label || stage.name}</h3>
                    <span class="n">{length(opps)}</span>
                    <.pill variant={stage_variant(stage.stage_type)}>{stage.stage_type}</.pill>
                    <span class="lane">· {dollars(stage_value(opps))}</span>
                  </div>
                  <.data_table>
                    <:head>
                      <th style="width:40%">Opportunity</th>
                      <th style="width:18%">Value</th>
                      <th style="width:16%">Status</th>
                      <th style="width:14%">Close date</th>
                      <th style="width:12%">Currency</th>
                    </:head>
                    <tr :for={opp <- opps} class="opp-row" id={"opp-#{opp.id}"}>
                      <td class="opp-name">
                        <span class="mono" style="color:#454652;font-weight:500">{opp.name}</span>
                      </td>
                      <td class="opp-value mono num">{dollars(opp.value_cents)}</td>
                      <td class="opp-status">
                        <.pill variant={status_variant(opp.status)}>{opp.status}</.pill>
                      </td>
                      <td class="opp-close" style="color:var(--muted);font-size:12px">
                        {opp.close_date || "—"}
                      </td>
                      <td class="opp-currency" style="color:var(--muted);font-size:12px">
                        {opp.currency || "USD"}
                      </td>
                    </tr>
                  </.data_table>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp stage_value(opps), do: Enum.reduce(opps, 0, &(&1.value_cents + &2))

  defp stage_variant(:open), do: "info"
  defp stage_variant(:qualified), do: "warn"
  defp stage_variant(:proposal), do: "info"
  defp stage_variant(:won), do: "ok"
  defp stage_variant(:lost), do: "bad"
  defp stage_variant(_), do: "mut"

  defp status_variant(:open), do: "info"
  defp status_variant(:won), do: "ok"
  defp status_variant(:lost), do: "bad"
  defp status_variant(:on_hold), do: "warn"
  defp status_variant(s) when is_binary(s), do: status_variant(String.to_atom(s))
  defp status_variant(_), do: "mut"

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp dollars(_), do: "$0.00"

  # Shared CRM sidebar — active on the pipeline page.
  defp crm_sidebar(assigns) do
    ~H"""
    <.sidebar
      title="Blue Ridge Logistics"
      subtitle="CRM"
      logo="B"
      logo_style="background:linear-gradient(150deg,#0E7C5A,#17A06E)"
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search companies, contacts…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={:crm_pipeline} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D6E9DF;color:#1E7A45">RM</div>
          <div class="m"><b>Rosa Medina</b><span>dispatcher</span></div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
