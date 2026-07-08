defmodule Samen.Web.Operator.PlatformBillingLive do
  @moduledoc """
  Framework OPERATOR / Platform billing page (ADR-010 §4b) — the PLATFORM billing its tenants.
  Each row is a tenant's subscription TO the SaaS (plan/MRR/status, customer PII CLEAR), the
  invoices the SaaS issues tenants, dunning/past-due, and the total platform MRR.

  ## Reconciliation (ADR-010 §4b.1)

  The total platform MRR here is `sum(monthly Price for active subscriptions)` over the operator
  org — the SAME MRR logic the ADR-009 `Billing.Reads` uses, scoped to the operator org. It is
  the subject-level, exact view; the token-blind `AggregateLive` is the same number with small
  cohorts suppressed. A reconciliation test pins the two equal on the unsuppressed seed.

  Reads the operator org's OWN Billing rows on the TENANT plane, so the SaaS's own customers
  (the tenant orgs) render in the clear. NEVER unwraps a `%Masked{}`; NO plaintext branch.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)

    case operator_org_id do
      nil ->
        assign(socket, no_org: true, billing: empty_billing())

      _org_id ->
        scope = Operator.scope(mount)
        assign(socket, no_org: false, billing: Reads.platform_billing(mount, scope))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-billing">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:billing} />
        </:sidebar>

        <.topbar title="Platform billing" crumbs={["Operator plane", "Platform billing"]} />

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved.
            </div>
          </div>
        <% else %>
          <div class="metrics">
            <.metric label="Platform MRR" value={dollars(@billing.mrr_cents)} sub="active subscriptions">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Active subs" value={@billing.active_subs} sub="tenants on a plan">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Past due" value={dollars(@billing.past_due_cents)} sub={"#{length(@billing.dunning)} invoices"}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="subscriptions">
              <div class="gtitle">
                <h3>Tenant subscriptions</h3>
                <span class="n">{length(@billing.subscriptions)}</span>
                <span class="lane">· each is a tenant's subscription TO the SaaS · customer in the clear</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:30%">Customer (tenant)</th>
                  <th style="width:26%">Billing email</th>
                  <th style="width:16%">Plan</th>
                  <th style="width:14%">Status</th>
                  <th style="width:14%">MRR</th>
                </:head>
                <tr :for={s <- @billing.subscriptions} class="subscription-row" id={"subscription-#{s.id}"}>
                  <td class="s-customer" style="font-weight:500;color:#3a3b45">
                    {customer_name(s.__customer__)}
                  </td>
                  <td class="s-email" style="font-size:12px;color:var(--muted)">
                    {customer_email(s.__customer__)}
                  </td>
                  <td class="s-plan" style="color:var(--muted)">{plan_label(s.__plan__)}</td>
                  <td class="s-status">
                    <.pill variant={status_variant(s.status)}>{s.status}</.pill>
                  </td>
                  <td class="s-mrr" style="color:var(--muted)">{dollars(s.__mrr_cents__)}</td>
                </tr>
              </.data_table>
            </div>

            <div id="invoices" style="margin-top:18px">
              <div class="gtitle">
                <h3>Invoices &amp; dunning</h3>
                <span class="n">{length(@billing.invoices)}</span>
                <span class="lane">· invoices the SaaS issues tenants · past-due flagged</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:34%">Customer (tenant)</th>
                  <th style="width:18%">Amount due</th>
                  <th style="width:18%">Due date</th>
                  <th style="width:15%">Status</th>
                  <th style="width:15%">Dunning</th>
                </:head>
                <tr :for={inv <- @billing.invoices} class="invoice-row" id={"invoice-#{inv.id}"}>
                  <td class="i-customer" style="font-weight:500;color:#3a3b45">
                    {customer_name(inv.__customer__)}
                  </td>
                  <td class="i-amount" style="color:var(--muted)">{dollars(inv.amount_due_cents)}</td>
                  <td class="i-due" style="color:var(--muted);font-size:12px">{due_date(inv.due_date)}</td>
                  <td class="i-status">
                    <.pill variant={invoice_variant(inv.status)}>{inv.status}</.pill>
                  </td>
                  <td class="i-dunning">
                    <.pill :if={past_due_member?(@billing.dunning, inv.id)} variant="bad">past due</.pill>
                    <span :if={not past_due_member?(@billing.dunning, inv.id)} style="color:var(--muted)">—</span>
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

  defp empty_billing,
    do: %{subscriptions: [], invoices: [], dunning: [], mrr_cents: 0, past_due_cents: 0, active_subs: 0}

  defp customer_name(nil), do: "—"
  defp customer_name(%{billing_name: name}), do: render_name(name)
  defp customer_name(_), do: "—"

  defp customer_email(nil), do: "—"
  defp customer_email(%{billing_email: email}), do: render_email(email)
  defp customer_email(_), do: "—"

  defp plan_label(nil), do: "—"
  defp plan_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp plan_label(%{name: name}), do: name
  defp plan_label(_), do: "—"

  defp due_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp due_date(_), do: "—"

  defp past_due_member?(dunning, inv_id), do: Enum.any?(dunning, &(&1.id == inv_id))

  defp status_variant(:active), do: "ok"
  defp status_variant(:past_due), do: "bad"
  defp status_variant(:trialing), do: "info"
  defp status_variant(_), do: "mut"

  defp invoice_variant(:paid), do: "ok"
  defp invoice_variant(:open), do: "warn"
  defp invoice_variant(:draft), do: "mut"
  defp invoice_variant(_), do: "mut"
end
