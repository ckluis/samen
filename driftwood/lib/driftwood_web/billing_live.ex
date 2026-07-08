defmodule DriftwoodWeb.BillingLive do
  @moduledoc """
  Billing / Customers + Subscriptions dashboard — the inherited Billing domain
  rendered as real UI.

  Reads `Driftwood.Billing.Customer` and `Driftwood.Billing.Subscription` through
  `Driftwood.BillingReads` on the TENANT plane:

    * TENANT plane (`plane: :tenant`): the org reads its OWN customers'
      `billing_name` / `billing_email` in CLEAR (tenant-as-owner rule;
      §external-surface :707). Subscriptions reference customers by opaque UUID.
    * OPERATOR / impersonation plane (`plane: :operator`): `billing_name` and
      `billing_email` render `%Masked{}` → •••• through Phoenix.HTML.Safe.

  Metric cards show MRR, active subscriptions, outstanding, and collected
  this month — all non-PII aggregates (no PII in the counts/sums).

  ## MASKING INVARIANT

  This LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a
  vault token out of a `%Masked{}`, and NEVER introduces a "show plaintext"
  code path. Plaintext only reaches a cell if `BillingReads.customers/1` already
  resolved it through the shared PiiResolution chokepoint.
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
      subscriptions: [],
      metrics: nil
    )
  end

  def load(socket, org_id) do
    scope = billing_scope(org_id)

    assign(socket,
      no_org: false,
      org_id: org_id,
      subscriptions: BillingReads.subscriptions(scope),
      metrics: BillingReads.metrics(scope)
    )
  end

  # A tenant-member scope for billing reads: plane: :tenant so the org reads its OWN
  # customers' PII in CLEAR through PiiResolution.
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

  # An OPERATOR impersonation scope — used in tests to assert masking.
  @doc false
  def operator_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "operator:impersonation",
        org_id: org_id,
        role: :member,
        kind: :operator,
        plane: :operator,
        impersonation: %{session_id: "test-session"}
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing">
      <.app_shell>
        <:sidebar>
          {billing_sidebar(assigns)}
        </:sidebar>

        <.topbar title="Billing" crumbs={["Blue Ridge Logistics", "Billing", "Overview"]}>
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

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
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
                <span class="lane">· billing_name / billing_email via PiiResolution · your org in the clear</span>
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
                      <div
                        class="av"
                        style="width:28px;height:28px;border-radius:6px;background:#EDE9FE;color:#5B21B6;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"
                      >
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
  #
  # These helpers render ALREADY-RESOLVED values from PiiResolution. They NEVER
  # unwrap a %Masked{} or call the vault. A %Masked{} is returned AS-IS so it
  # renders •••• through Phoenix.HTML.Safe.

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
    # Use a static price map derived from seeds for display.
    # In a real app this would join to the Price resource.
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

  defp dollars(cents) when is_integer(cents) do
    "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end

  defp dollars(_), do: "$0.00"

  defp format_date(nil), do: "—"

  defp format_date(%DateTime{} = dt) do
    "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  end

  defp format_date(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  # Shared Billing sidebar.
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

      <.module_nav org_id={@org_id} active={:billing_overview} />

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
