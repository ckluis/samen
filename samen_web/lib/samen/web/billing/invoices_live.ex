defmodule Samen.Web.Billing.InvoicesLive do
  @moduledoc """
  Framework Billing / Invoices page — the inherited Billing domain rendered as real UI,
  host-agnostic (ADR-009).

  Reads the host's `<namespace>.Invoice` via `Samen.Web.Billing.Reads.invoices/2`. The
  invoice carries NO PII; the customer's `billing_name` (PII) is resolved through
  PiiResolution (tenant CLEAR / operator ••••). Renders whatever the resolver returned.
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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, invoices: [], outstanding_cents: 0)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    invs = Reads.invoices(mount, scope)

    outstanding =
      Enum.reduce(invs, 0, fn inv, acc ->
        if inv.status in [:open, :draft], do: acc + (inv.amount_due_cents || 0), else: acc
      end)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, invoices: invs, outstanding_cents: outstanding)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-invoices">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_invoices} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Invoices" crumbs={crumbs(@samen_mount, @org_id, "Invoices")}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New invoice
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing invoices org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Total outstanding" value={dollars(@outstanding_cents)} sub="open invoices">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 14l2 2 4-4" /><rect x="3" y="3" width="18" height="18" rx="2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Invoices" value={length(@invoices)}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 12h6M9 16h6M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Paid" value={Enum.count(@invoices, &(&1.status == :paid))}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M9 12l2 2 4-4" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Overdue" value={Enum.count(@invoices, &overdue?/1)}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 8v4M12 16h.01" /><circle cx="12" cy="12" r="9" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="invoices">
              <div class="gtitle">
                <h3>Invoices</h3>
                <span class="n">{length(@invoices)}</span>
                <span class="lane">· customer name via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:14%">Number</th>
                  <th style="width:26%">Customer</th>
                  <th style="width:16%">Amount</th>
                  <th style="width:16%">Status</th>
                  <th style="width:16%">Due date</th>
                  <th style="width:12%">Paid</th>
                </:head>
                <tr :for={{inv, idx} <- Enum.with_index(@invoices)} class="invoice-row" id={"invoice-#{inv.id}"}>
                  <td class="inv-number" style="font-size:12px;color:var(--muted);font-family:monospace">
                    INV-{String.pad_leading(to_string(idx + 1001), 4, "0")}
                  </td>
                  <td class="inv-customer" style="font-weight:500;color:#3a3b45">
                    {render_billing_name(inv.__customer__)}
                  </td>
                  <td class="inv-amount" style="font-weight:500;color:#3a3b45">
                    {dollars(inv.amount_due_cents || 0)}
                  </td>
                  <td class="inv-status">
                    <.pill variant={invoice_status_variant(inv)}>{invoice_status_label(inv)}</.pill>
                  </td>
                  <td class="inv-due" style="color:var(--muted);font-size:12px">
                    {format_date(inv.due_date)}
                  </td>
                  <td class="inv-paid" style="color:var(--muted);font-size:12px">
                    {if inv.status == :paid, do: dollars(inv.amount_paid_cents || 0), else: "—"}
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

  @doc false
  def overdue?(%{status: :open, due_date: %DateTime{} = due}),
    do: DateTime.compare(due, DateTime.utc_now()) == :lt

  def overdue?(_), do: false

  defp invoice_status_label(inv), do: if(overdue?(inv), do: "overdue", else: to_string(inv.status))

  defp invoice_status_variant(inv) do
    cond do
      inv.status == :paid -> "ok"
      overdue?(inv) -> "bad"
      inv.status == :open -> "info"
      true -> "mut"
    end
  end

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  defp format_date(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")
end
