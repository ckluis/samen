defmodule DriftwoodWeb.BillingPlansLive do
  @moduledoc """
  Billing / Plans page — Tier-0 billing plans + prices config rows, rendered as
  cards via the inherited Billing domain.

  Reads `Driftwood.Billing.Plan` and `Driftwood.Billing.Price` through
  `Driftwood.BillingReads.plans_with_prices/1`. Plans and prices are NON-PII
  config rows (admin-gated writes; no vault-routed fields). No PiiResolution step
  is needed for this page.

  Renders each plan as a card with:
    * Plan name / label (e.g. "Starter", "Growth", "Scale")
    * Price / interval (from the associated Price rows)
    * Enabled status pill
    * Feature entitlements from Plan.features (bounded map)

  ## Non-PII guarantee

  Plan and Price have no PII fields. This page introduces NO PII path.
  org_id is passed as a query param for the LOCAL dogfood; org-scope policy
  ensures a broker sees ONLY their own org's plans.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Driftwood.BillingReads

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
    assign(socket,
      no_org: true,
      org_id: nil,
      plans: []
    )
  end

  def load(socket, org_id) do
    scope = billing_scope(org_id)

    assign(socket,
      no_org: false,
      org_id: org_id,
      plans: BillingReads.plans_with_prices(scope)
    )
  end

  # A tenant-member scope — plane: :tenant (plans are non-PII; no PII path here).
  @doc false
  def billing_scope(org_id) do
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
    <div id="billing-plans">
      <.app_shell>
        <:sidebar>
          {billing_sidebar(assigns)}
        </:sidebar>

        <.topbar title="Plans" crumbs={["Blue Ridge Logistics", "Billing", "Plans"]}>
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

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
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
                      <div
                        class="av"
                        style={"width:28px;height:28px;border-radius:6px;background:#{plan_bg(plan.name)};color:#{plan_fg(plan.name)};font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"}
                      >
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

  defp primary_price([]), do: "—"

  defp primary_price([price | _]) do
    dollars(price.unit_amount_cents)
  end

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
    features
    |> Map.keys()
    |> Enum.map(&humanize_feature/1)
    |> Enum.sort()
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

  defp dollars(cents) when is_integer(cents) do
    "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end

  defp dollars(_), do: "$0.00"

  # Shared Billing sidebar — active on the plans page.
  defp billing_sidebar(assigns) do
    ~H"""
    <.sidebar
      title="Blue Ridge Logistics"
      subtitle="Billing"
      logo="B"
      logo_style="background:linear-gradient(150deg,#5B21B6,#7C3AED)"
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search customers, invoices…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={:billing_plans} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#EDE9FE;color:#5B21B6">RM</div>
          <div class="m"><b>Rosa Medina</b><span>dispatcher</span></div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
