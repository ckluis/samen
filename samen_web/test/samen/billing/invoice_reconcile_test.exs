defmodule Samen.Web.Billing.InvoiceReconcileTest do
  @moduledoc """
  T22/B4+B6 — the REAL Ash-resource write path for invoice-mirror reconciliation.

  `samen_core`'s `Samen.Billing.Invoice` + `Samen.Billing.AshInvoiceMirror` are
  resource-module-agnostic (no host, no vendor). This test proves them against REAL
  Ash resources + a real Postgres DB — `samen_web`'s own `Samen.WebTest.Billing`
  mounted test domain (zero new abbrevs; the tax/hosted-link columns this task
  added are already migrated for this test host,
  `priv/repo/migrations/20260722120000_add_invoice_tax_and_hosted_links.exs`) —
  satisfying the task's explicit requirement that the invoice mirror lands on the
  EXISTING billing Invoice resource, not on `Samen.Billing.FakeInvoiceMirror` (the
  hermetic proof for routing/idempotency lives in
  `samen_core/test/billing_invoice_test.exs` and
  `samen_stripe/test/invoice_mirror_test.exs`; THIS file is the one place
  done-criterion 1 is proven against a real Invoice row).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Billing.{AshInvoiceMirror, Invoice, ProviderEvent}
  alias Samen.WebTest.Billing.{Customer, Subscription}

  defmodule TestProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double serving an injected invoice snapshot."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(_config), do: true
    @impl true
    def fetch_object(:invoice, id, %{snapshot: snap}), do: {:ok, Map.put(snap, :provider_invoice_id, id)}
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}
    @impl true
    def create_checkout_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def create_portal_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_i, _o, _c), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_i, _ch, _c), do: {:error, :not_implemented}
    @impl true
    def report_usage(_b, _c), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_r, _h, _c), do: {:error, :not_implemented}
    @impl true
    def redact_payload(p), do: p
  end

  @ref_config %{
    invoice: Samen.WebTest.Billing.Invoice,
    subscription: Subscription,
    customer: Customer,
    invoice_ref_attr: :provider_invoice_ref,
    subscription_ref_attr: :provider_subscription_ref,
    customer_ref_attr: :provider_customer_ref
  }

  defp seed_customer(org_id, provider_customer_id) do
    Customer
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, provider_customer_ref: provider_customer_id, status: :active}, authorize?: false)
    |> Ash.create!()
  end

  defp seed_subscription(org_id, customer, provider_subscription_id) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, customer_id: customer.id, provider_subscription_ref: provider_subscription_id, status: :active},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp invoice_event(kind, invoice_id, customer_ref, subscription_ref) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_#{kind}_#{System.unique_integer([:positive])}",
      kind: kind,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: %{object_id: invoice_id, customer_id: customer_ref, subscription_id: subscription_ref},
      payload: %{}
    }
  end

  defp reconcile_opts(snapshot) do
    [
      provider: TestProvider,
      provider_config: %{snapshot: snapshot},
      invoice_mirror: AshInvoiceMirror,
      invoice_mirror_ref: @ref_config
    ]
  end

  defp snap(overrides \\ %{}) do
    Map.merge(
      %{
        status: :open,
        amount_due_cents: 32_130,
        amount_paid_cents: 0,
        currency: "usd",
        tax_amount_cents: 2_130,
        tax_lines: [%{"amount_cents" => 2_130, "display_name" => "CA Sales Tax"}],
        hosted_invoice_url: "https://provider.example.test/invoices/real",
        hosted_receipt_url: nil,
        line_items: [%{"description" => "Pro plan", "amount_cents" => 30_000, "quantity" => 1}]
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — a real Invoice row, tax + hosted link mirrored
  # ---------------------------------------------------------------------------

  test "invoice.finalized creates a REAL Invoice row with tax + hosted link mirrored" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id, "cus_real_inv_1")
    subscription = seed_subscription(org_id, customer, "sub_real_inv_1")
    invoice_id = "in_real_#{System.unique_integer([:positive])}"

    event = invoice_event(:invoice_finalized, invoice_id, "cus_real_inv_1", "sub_real_inv_1")

    assert {:ok, :applied, applied} = Invoice.reconcile(event, reconcile_opts(snap()))

    invoice =
      Samen.WebTest.Billing.Invoice
      |> Ash.get!(applied.invoice_id, authorize?: false)
      |> Ash.load!([:org_id], authorize?: false)

    assert invoice.org_id == org_id
    assert invoice.customer_id == customer.id
    assert invoice.subscription_id == subscription.id
    assert invoice.provider_invoice_ref == invoice_id
    assert invoice.status == :open
    assert invoice.amount_due_cents == 32_130
    assert invoice.tax_amount_cents == 2_130
    assert invoice.tax_lines == [%{"amount_cents" => 2_130, "display_name" => "CA Sales Tax"}]
    assert invoice.hosted_invoice_url == "https://provider.example.test/invoices/real"
  end

  test "fail-honest tax: no tax data on the snapshot mirrors nil/[], never a fabricated 0" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id, "cus_no_tax_1")
    _subscription = seed_subscription(org_id, customer, "sub_no_tax_1")
    invoice_id = "in_no_tax_#{System.unique_integer([:positive])}"

    event = invoice_event(:invoice_finalized, invoice_id, "cus_no_tax_1", "sub_no_tax_1")
    snapshot = snap(%{tax_amount_cents: nil, tax_lines: []})

    assert {:ok, :applied, applied} = Invoice.reconcile(event, reconcile_opts(snapshot))

    invoice = Ash.get!(Samen.WebTest.Billing.Invoice, applied.invoice_id, authorize?: false)
    assert invoice.tax_amount_cents == nil
    assert invoice.tax_lines == []
  end

  test "an unresolvable customer refuses (fail-honest), never invents a row" do
    org_id = Ash.UUID.generate()
    _customer = seed_customer(org_id, "cus_other")
    invoice_id = "in_unresolvable_#{System.unique_integer([:positive])}"

    event = invoice_event(:invoice_finalized, invoice_id, "cus_never_seen", nil)

    assert {:error, :customer_not_found} = Invoice.reconcile(event, reconcile_opts(snap()))
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — updates re-mirror the SAME row idempotently
  # ---------------------------------------------------------------------------

  test "invoice.paid re-mirrors the SAME real Invoice row (idempotent upsert)" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id, "cus_real_inv_2")
    _subscription = seed_subscription(org_id, customer, "sub_real_inv_2")
    invoice_id = "in_real_2_#{System.unique_integer([:positive])}"

    event1 = invoice_event(:invoice_finalized, invoice_id, "cus_real_inv_2", "sub_real_inv_2")
    assert {:ok, :applied, %{created: true, invoice_id: row_id}} = Invoice.reconcile(event1, reconcile_opts(snap()))

    event2 = invoice_event(:invoice_paid, invoice_id, "cus_real_inv_2", "sub_real_inv_2")
    paid_snap = snap(%{status: :paid, amount_paid_cents: 32_130, hosted_receipt_url: "https://provider.example.test/receipts/real"})

    assert {:ok, :applied, %{created: false, invoice_id: ^row_id}} = Invoice.reconcile(event2, reconcile_opts(paid_snap))

    matches =
      Samen.WebTest.Billing.Invoice
      |> Ash.Query.ensure_selected([:org_id, :provider_invoice_ref])
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.provider_invoice_ref == invoice_id))

    assert length(matches) == 1

    invoice = Ash.get!(Samen.WebTest.Billing.Invoice, row_id, authorize?: false)
    assert invoice.status == :paid
    assert invoice.amount_paid_cents == 32_130
    assert invoice.hosted_receipt_url == "https://provider.example.test/receipts/real"
  end

  test "the SAME event replayed twice is a no-op (single real row, single change)" do
    org_id = Ash.UUID.generate()
    customer = seed_customer(org_id, "cus_real_inv_3")
    _subscription = seed_subscription(org_id, customer, "sub_real_inv_3")
    invoice_id = "in_real_3_#{System.unique_integer([:positive])}"

    event = invoice_event(:invoice_finalized, invoice_id, "cus_real_inv_3", "sub_real_inv_3")

    assert {:ok, :applied, _} = Invoice.reconcile(event, reconcile_opts(snap()))
    assert {:ok, :duplicate} = Invoice.reconcile(event, reconcile_opts(snap()))

    matches =
      Samen.WebTest.Billing.Invoice
      |> Ash.Query.ensure_selected([:org_id, :provider_invoice_ref])
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.provider_invoice_ref == invoice_id))

    assert length(matches) == 1
  end
end
