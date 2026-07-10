defmodule Samen.Web.BillingInvoicesCrudTest do
  @moduledoc """
  A3 WIRING (billing-support batch) — `Samen.Web.Billing.InvoicesLive` on the A2 kit
  contract. The invoice itself is non-PII; the joined customer `billing_name` is the
  read-side PII (plane masking asserted in `billing_render_test.exs`, which exercises
  this SAME `list_view` render path):

    * **CRUD (AC-G1-1/2)** — "New invoice" opens the modal + `simple_form` (customer
      select, amount, status); an INVALID submit (garbage `customer_id`) renders
      inline errors and persists NOTHING; a VALID submit persists + refreshes; each
      row carries `delete_confirm/1` and delete destroys through Ash (admin-gated via
      `Reads.write_scope/2`).
    * **Bounded read (AC-G1-5)** — `invoices_page/3` passes `bounded!/4` non-vacuously;
      keyset pagination walks a 55-row org at the default page size on the REAL page.
    * **Operator posture (belt)** — no write affordance in the operator DOM; the
      masked customer column stays masked.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.InvoicesLive
  alias Samen.Web.Billing.Reads
  alias Samen.Web.ListLive
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:billing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> InvoicesLive.load(org_id)
  end

  defp html(socket), do: render_html(InvoicesLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = InvoicesLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp invoice_count(org_id) do
    Samen.WebTest.Billing.Invoice
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp seed_customer(org_id) do
    Samen.WebTest.Billing.Customer
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, billing_name: "Fixture Freightways", billing_email: "fixture@example.test", status: :active},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_invoices(org_id, customer_id, n) do
    for i <- 1..n do
      Samen.WebTest.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer_id,
          status: :open,
          amount_due_cents: i * 100,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), i * 86_400, :second)
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  # ---------------------------------------------------------------------------
  # Create — green + red (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New invoice opens the modal; a VALID submit persists and refreshes the bounded list" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id)
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-invoice")
    assert rendered =~ ~s(phx-click="new_invoice")

    socket = event(socket, "new_invoice", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-invoice-form")
    assert rendered =~ ~s(name="form[customer_id]")
    # The customer select's option label is the tenant-plane-resolved billing name.
    assert rendered =~ "Fixture Freightways"

    socket =
      event(socket, "save_new", %{
        "form" => %{"customer_id" => customer.id, "amount_due_cents" => "12500", "status" => "open", "currency" => "USD"}
      })

    refute socket.assigns.show_new
    assert invoice_count(org_id) == 1
    assert html(socket) =~ "$125.00"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (garbage customer_id) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_invoice", %{})

    socket =
      event(socket, "save_new", %{"form" => %{"customer_id" => "not-a-uuid", "amount_due_cents" => "100"}})

    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert invoice_count(org_id) == 0
  end

  # ---------------------------------------------------------------------------
  # Delete — the interlocked row action
  # ---------------------------------------------------------------------------

  test "each row carries the delete_confirm interlock; delete destroys through Ash and refreshes" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id)
    [invoice] = seed_invoices(org_id, customer.id, 1)

    socket = mount_socket(org_id)
    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-value-id="#{invoice.id}")

    socket = event(socket, "delete", %{"id" => invoice.id})
    assert socket.assigns.page.items == []
    assert invoice_count(org_id) == 0
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Bounded read + pagination (AC-G1-5 / RP-G1-5 per-surface)
  # ---------------------------------------------------------------------------

  test "a 55-invoice org NEVER loads the full set; keyset next/prev walk the pages" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id)
    seed_invoices(org_id, customer.id, 55)
    mount = build_mount(:billing)
    scope = Mount.scope(mount, org_id)

    assert :ok == WebReads.bounded!(&Reads.invoices_page/3, mount, scope, page_size: 10)

    socket = mount_socket(org_id)
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert length(socket.assigns.page.items) == 5
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
  end

  # ---------------------------------------------------------------------------
  # Operator posture (belt) — masked list, no write affordance
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no create/delete affordance; the customer column renders masked" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    assert rendered =~ "invoice-row"
    assert rendered =~ "••••"
    refute rendered =~ Seeds.customer_name()
    refute rendered =~ ~s(phx-click="new_invoice")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
    refute rendered =~ "vt_"
  end
end
