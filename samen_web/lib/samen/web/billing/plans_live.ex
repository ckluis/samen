defmodule Samen.Web.Billing.PlansLive do
  @moduledoc """
  Framework Billing / Plans page — Tier-0 billing plans + prices config rows, host-agnostic
  (ADR-009). Reads the host's `<namespace>.Plan` + `<namespace>.Price` via
  `Samen.Web.Billing.Reads.plans_with_prices/2`. Plans/prices are non-PII config rows; this
  page introduces NO PII path.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Reads

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, plans: [])
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, plans: Reads.plans_with_prices(mount, scope))
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-plans">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_plans} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Plans" crumbs={crumbs(@samen_mount, @org_id, "Plans")}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New plan
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing plans org: {@org_id}</span>

          <div class="wrap">
            <div id="plans">
              <div class="gtitle">
                <h3>Billing Plans</h3>
                <span class="n">{length(@plans)}</span>
                <span class="lane">· Tier-0 config rows · admin-gated writes · no PII</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:20%">Plan</th>
                  <th style="width:18%">Price</th>
                  <th style="width:14%">Interval</th>
                  <th style="width:14%">Status</th>
                  <th style="width:34%">Entitlements</th>
                </:head>
                <tr :for={%{plan: plan, prices: prices} <- @plans} class="plan-row" id={"plan-#{plan.id}"}>
                  <td class="plan-name">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div class="av" style={"width:28px;height:28px;border-radius:6px;background:#{plan_bg(plan.name)};color:#{plan_fg(plan.name)};font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"}>
                        {String.slice(plan.label || plan.name || "?", 0, 1) |> String.upcase()}
                      </div>
                      <div>
                        <div style="font-weight:600;color:#3a3b45">{plan.label || plan.name}</div>
                        <div style="font-size:11px;color:var(--muted)">{plan.description || plan.name}</div>
                      </div>
                    </div>
                  </td>
                  <td class="plan-price" style="font-weight:500;color:#3a3b45">
                    {primary_price(prices)}
                  </td>
                  <td class="plan-interval" style="color:var(--muted)">
                    {primary_interval(prices)}
                  </td>
                  <td class="plan-status">
                    <.pill variant={if plan.enabled, do: "ok", else: "mut"}>
                      {if plan.enabled, do: "active", else: "disabled"}
                    </.pill>
                  </td>
                  <td class="plan-features">
                    <div style="display:flex;flex-wrap:wrap;gap:4px">
                      <span :for={feat <- plan_features(plan)} style="display:inline-block;font-size:11px;padding:2px 7px;background:#F3F4F6;border-radius:4px;color:#374151">
                        {feat}
                      </span>
                    </div>
                  </td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Billing", leaf]

  defp primary_price([]), do: "—"
  defp primary_price([price | _]), do: dollars(price.unit_amount_cents)

  defp primary_interval([]), do: "—"

  defp primary_interval([price | _]) do
    case price.interval do
      :monthly -> "monthly"
      :annual -> "annual"
      :weekly -> "weekly"
      :daily -> "daily"
      :one_time -> "one-time"
      other -> to_string(other)
    end
  end

  defp plan_features(%{features: features}) when is_map(features) and map_size(features) > 0 do
    features |> Map.keys() |> Enum.map(&humanize_feature/1) |> Enum.sort()
  end

  defp plan_features(_), do: ["basic"]

  defp humanize_feature(key) when is_binary(key), do: String.replace(key, "_", " ")
  defp humanize_feature(key) when is_atom(key), do: key |> to_string() |> String.replace("_", " ")
  defp humanize_feature(other), do: to_string(other)

  defp plan_bg("starter"), do: "#F0FDF4"
  defp plan_bg("growth"), do: "#EFF6FF"
  defp plan_bg("scale"), do: "#F5F3FF"
  defp plan_bg(_), do: "#F3F4F6"

  defp plan_fg("starter"), do: "#16A34A"
  defp plan_fg("growth"), do: "#2563EB"
  defp plan_fg("scale"), do: "#7C3AED"
  defp plan_fg(_), do: "#6B7280"

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
