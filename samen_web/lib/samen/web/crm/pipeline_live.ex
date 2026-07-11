defmodule Samen.Web.CRM.PipelineLive do
  @moduledoc """
  Framework CRM / Pipeline page — opportunities grouped by pipeline stage (ADR-009).

  Reads the host's `<namespace>.Opportunity` + `<namespace>.Pipeline` via
  `Samen.Web.CRM.Reads.pipeline/2`. Opportunities are non-PII. Renders a data_table per
  stage with columns: opportunity name, value, status, close date. Org-scoped by policy.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.CRM.Reads

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, stages: [], total_value_cents: 0, total_opps: 0)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    stages = Reads.pipeline(mount, scope)

    total_value_cents =
      stages
      |> Enum.flat_map(& &1.opportunities)
      |> Enum.reduce(0, fn opp, acc -> acc + (opp.value_cents || 0) end)

    total_opps =
      stages |> Enum.map(& &1.opportunities) |> Enum.map(&length/1) |> Enum.sum()

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      stages: stages,
      total_value_cents: total_value_cents,
      total_opps: total_opps
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-pipeline">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_pipeline} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Pipeline" crumbs={crumbs(@samen_mount, @org_id, "Pipeline")}>
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

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
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
                <.empty_state
                  class="pipeline-empty"
                  icon="◇"
                  title="No pipeline stages with opportunities yet."
                  body="Stages appear here once your pipeline has opportunities in flight."
                />
              <% else %>
                <%= for %{stage: stage, opportunities: opps} <- @stages do %>
                  <div class="gtitle" id={"stage-#{stage.name}"}>
                    <h3>{stage.label || stage.name}</h3>
                    <span class="n">{length(opps)}</span>
                    <.pill variant={stage_variant(Map.get(stage, :stage_type))}>{Map.get(stage, :stage_type)}</.pill>
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
                        {Map.get(opp, :currency) || "USD"}
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

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", leaf]

  defp stage_value(opps), do: Enum.reduce(opps, 0, &((&1.value_cents || 0) + &2))

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
end
