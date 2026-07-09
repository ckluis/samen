defmodule Samen.Web.Billing.OverviewLive do
  @moduledoc """
  Framework Billing / Customers + Subscriptions dashboard — the inherited Billing domain
  rendered as real UI, host-agnostic (ADR-009).

  Reads the host's `<namespace>.Customer` + `<namespace>.Subscription` via
  `Samen.Web.Billing.Reads`. The customer's `billing_name` / `billing_email` are PII:

    * TENANT plane — CLEAR (the org reads its own customers).
    * OPERATOR plane — `%Masked{}` → •••• via `Phoenix.HTML.Safe`.

  Metric cards (MRR, active subs, outstanding, collected) are non-PII aggregates.
  NEVER calls the vault; renders whatever the resolver returned.
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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, subscriptions: [], metrics: nil)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      subscriptions: Reads.subscriptions(mount, scope),
      metrics: Reads.metrics(mount, scope)
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_overview} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Billing" crumbs={crumbs(@samen_mount, @org_id, "Overview")}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New customer
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing org: {@org_id}</span>

          <div class="metrics">
            <.metric label="MRR" value={dollars((@metrics && @metrics.mrr_cents) || 0)} sub="monthly recurring">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Active subscriptions" value={(@metrics && @metrics.active_subs) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /><path d="M8 15h4M8 12h8" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Outstanding" value={dollars((@metrics && @metrics.outstanding_cents) || 0)} sub="open invoices">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 14l2 2 4-4" /><rect x="3" y="3" width="18" height="18" rx="2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Collected this month" value={dollars((@metrics && @metrics.collected_cents) || 0)}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M9 12l2 2 4-4" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="subscriptions">
              <div class="gtitle">
                <h3>Customers &amp; Subscriptions</h3>
                <span class="n">{length(@subscriptions)}</span>
                <span class="lane">· billing_name / billing_email via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:28%">Customer</th>
                  <th style="width:18%">Plan</th>
                  <th style="width:18%">MRR</th>
                  <th style="width:18%">Status</th>
                  <th style="width:18%">Period end</th>
                </:head>
                <tr :for={sub <- @subscriptions} class="subscription-row" id={"sub-#{sub.id}"}>
                  <td class="sub-customer">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div class="av" style="width:28px;height:28px;border-radius:6px;background:#EDE9FE;color:#5B21B6;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                        {customer_initials(sub.__customer__)}
                      </div>
                      <div>
                        <div class="sub-name" style="font-weight:500;color:#3a3b45">
                          {render_billing_name(sub.__customer__)}
                        </div>
                        <div class="sub-email" style="font-size:11px;color:var(--muted)">
                          {render_billing_email(sub.__customer__)}
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class="sub-plan">
                    <.pill variant={plan_variant(plan_name(sub.__plan__))}>{plan_label(sub.__plan__)}</.pill>
                  </td>
                  <td class="sub-mrr" style="font-weight:500;color:#3a3b45">
                    {plan_mrr(sub.__plan__)}
                  </td>
                  <td class="sub-status">
                    <.pill variant={sub_status_variant(sub.status)}>{sub.status}</.pill>
                  </td>
                  <td class="sub-period" style="color:var(--muted);font-size:12px">
                    {format_date(sub.current_period_end)}
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

  # -- helpers (MASKING INVARIANT) -------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Billing", leaf]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

  defp render_billing_name(nil), do: "—"
  defp render_billing_name(%{billing_name: %Samen.Masked{} = m}), do: m
  defp render_billing_name(%{billing_name: name}) when is_binary(name), do: name
  defp render_billing_name(_), do: "—"

  defp render_billing_email(nil), do: ""
  defp render_billing_email(%{billing_email: %Samen.Masked{} = m}), do: m
  defp render_billing_email(%{billing_email: email}) when is_binary(email), do: email
  defp render_billing_email(_), do: ""

  defp customer_initials(nil), do: "?"
  defp customer_initials(%{billing_name: %Samen.Masked{}}), do: "··"

  defp customer_initials(%{billing_name: name}) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp customer_initials(_), do: "?"

  defp plan_name(nil), do: "unknown"
  defp plan_name(%{name: name}), do: name || "unknown"
  defp plan_name(_), do: "unknown"

  defp plan_label(nil), do: "—"
  defp plan_label(%{label: label}) when is_binary(label), do: label
  defp plan_label(%{name: name}) when is_binary(name), do: String.capitalize(name)
  defp plan_label(_), do: "—"

  defp plan_mrr(nil), do: "—"

  defp plan_mrr(%{name: name}) do
    case name do
      "starter" -> "$99/mo"
      "growth" -> "$299/mo"
      "scale" -> "$799/mo"
      _ -> "—"
    end
  end

  defp plan_mrr(_), do: "—"

  defp plan_variant("starter"), do: "mut"
  defp plan_variant("growth"), do: "info"
  defp plan_variant("scale"), do: "ok"
  defp plan_variant(_), do: "mut"

  defp sub_status_variant(:active), do: "ok"
  defp sub_status_variant(:trialing), do: "info"
  defp sub_status_variant(:past_due), do: "warn"
  defp sub_status_variant(:inactive), do: "mut"
  defp sub_status_variant(:cancelled), do: "bad"
  defp sub_status_variant(:unpaid), do: "bad"
  defp sub_status_variant(_), do: "mut"

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  defp format_date(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")
end
