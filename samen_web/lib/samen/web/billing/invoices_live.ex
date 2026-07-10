defmodule Samen.Web.Billing.InvoicesLive do
  @moduledoc """
  Framework Billing / Invoices page — the inherited Billing domain rendered as real UI,
  host-agnostic (ADR-009).

  The invoice carries NO PII; the joined customer's `billing_name` (PII) is resolved
  through PiiResolution (tenant CLEAR / operator ••••). Renders whatever the resolver
  returned.

  ## A3 retrofit — ListLive + sanctioned CRUD

  The list rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.invoices_page/3` buys sort/filter/keyset-pagination/empty-state as kit
  defaults (no unbounded `read!`). Metric cards are DB aggregates
  (`Reads.invoice_metrics/2`). The write side (AC-G1-1/2): "New invoice" opens a
  `modal/1` hosting an `AshPhoenix.Form`-backed `simple_form/1` create (`customer_id`
  is required — the inline-error path is real); each row carries a `delete_confirm/1`.
  Write affordances are offered on the tenant plane only
  (`Samen.Web.Billing.Live.writable?/1`); enforcement stays in the kernel — Invoice
  writes are ADMIN-gated, so writes go through `Reads.write_scope/2` (same-org,
  PLANE-PRESERVING role elevation).

  The customer select's option labels are the PLANE-RESOLVED billing names (tenant
  clear); the modal is never offered on the operator plane, and the write path itself
  is closed by the kernel regardless.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Reads

  use Samen.Web.ListLive,
    resource: Invoice,
    reads: &Samen.Web.Billing.Reads.invoices_page/3,
    sortable: [:status, :due_date, :amount_due_cents],
    filter_fields: [:currency],
    default_sort: {:due_date, :asc}

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, metrics: nil, customer_options: [])
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      metrics: Reads.invoice_metrics(mount, scope),
      customer_options: customer_options(mount, scope)
    )
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_invoice_form(mount, org_id))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_invoice", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    {:noreply, assign(socket, show_new: true, new_form: new_invoice_form(mount, org_id))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. Invoices are non-PII; the
  # kernel's OrgScope + admin role gate + SameOrgFk still apply — no LiveView policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _invoice} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # FAIL-HONEST delete: an invoice with linked records is refused by the DB (FK)
  # and the refusal is SURFACED on the page.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.delete_invoice(mount, Reads.write_scope(mount, org_id), id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket, delete_error: "Could not delete this invoice — it still has linked records.")}
    end
  end

  defp new_invoice_form(mount, org_id) do
    Mount.resource(mount, Invoice)
    |> AshPhoenix.Form.for_create(:create, scope: Reads.write_scope(mount, org_id))
    |> to_form()
  end

  # Option labels are ALREADY-RESOLVED billing names (tenant plane: clear). A
  # %Masked{} customer (operator plane — where this select is never offered) falls
  # back to the opaque id-derived label rather than stringifying the mask.
  defp customer_options(mount, scope) do
    Reads.customers(mount, scope)
    |> Enum.map(fn c -> {customer_label(c), c.id} end)
  end

  defp customer_label(%{billing_name: name}) when is_binary(name), do: name
  defp customer_label(%{id: id}), do: "Customer #{String.slice(id, 0, 8)}"

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

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
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_invoice" id="new-invoice">
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

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="metrics">
            <.metric label="Total outstanding" value={dollars((@metrics && @metrics.outstanding_cents) || 0)} sub="open invoices">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 14l2 2 4-4" /><rect x="3" y="3" width="18" height="18" rx="2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Invoices" value={(@metrics && @metrics.count) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 12h6M9 16h6M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Paid" value={(@metrics && @metrics.paid) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M9 12l2 2 4-4" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Overdue" value={(@metrics && @metrics.overdue) || 0}>
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
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· customer name via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="invoices-list"
                page={@page}
                state={@list_state}
                row_class="invoice-row"
                filter_placeholder="Filter invoices…"
                empty_text="No invoices yet."
              >
                <:head>
                  <th scope="col" style="width:12%">Number</th>
                  <th scope="col" style="width:24%">Customer</th>
                  <.sort_header field={:amount_due_cents} label="Amount" sort={@list_state.sort} width="14%" />
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="14%" />
                  <.sort_header field={:due_date} label="Due date" sort={@list_state.sort} width="14%" />
                  <th scope="col" style="width:12%">Paid</th>
                  <th :if={writable?(@samen_mount)} scope="col" style="width:10%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={inv}>
                  <td class="inv-number" style="font-size:12px;color:var(--muted);font-family:monospace">
                    INV-{String.slice(inv.id, 0, 8)}
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
                  <td :if={writable?(@samen_mount)} class="inv-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={inv.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-invoice-modal" title="New invoice" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-invoice-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:customer_id]} label="Customer" type="select" prompt="Choose a customer" options={@customer_options} />
              <.form_field field={f[:amount_due_cents]} label="Amount due (cents)" type="number" />
              <.form_field field={f[:status]} label="Status" type="select" options={[{"draft", "draft"}, {"open", "open"}]} />
              <.form_field field={f[:currency]} label="Currency" />
              <:actions>
                <.button variant="primary" type="submit">Save invoice</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
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
