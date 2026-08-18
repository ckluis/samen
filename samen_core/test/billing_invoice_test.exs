defmodule Samen.Billing.InvoiceTest do
  @moduledoc """
  Core-side, VENDOR-FREE proof of the B4+B6 invoice-mirror logic (T22; ADR-038
  §3.4/§3.5).

  Mirrors `samen_stripe/test/invoice_mirror_test.exs`'s done-criteria but with a
  test-local provider double (no Stripe, no `samen_stripe`) so `samen_core` proves
  invoice-mirror routing/idempotency + the fail-honest tax contract on its OWN —
  the INV-4 posture (core green with every adapter absent).
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{FakeInvoiceMirror, Invoice, ProviderEvent}

  defmodule LocalProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double: serves a canned invoice snapshot."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(config), do: Map.get(config, :configured, true) == true

    @impl true
    def fetch_object(:invoice, _id, %{snapshot: snap}), do: {:ok, snap}
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

  @invoice_id "in_1"
  @cus_id "cus_1"
  @sub_id "sub_1"

  defp snap(overrides \\ %{}) do
    Map.merge(
      %{
        provider_customer_id: @cus_id,
        provider_subscription_id: @sub_id,
        status: :open,
        amount_due_cents: 10_000,
        amount_paid_cents: 0,
        currency: "usd",
        tax_amount_cents: nil,
        tax_lines: [],
        hosted_invoice_url: "https://provider.example.test/invoices/#{@invoice_id}",
        hosted_receipt_url: nil,
        line_items: [%{"description" => "Pro plan", "amount_cents" => 10_000, "quantity" => 1}]
      },
      overrides
    )
  end

  defp event(kind, refs) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_#{kind}_#{System.unique_integer([:positive])}",
      kind: kind,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: refs,
      payload: %{}
    }
  end

  defp opts(mirror_ref, snapshot \\ nil) do
    [
      provider: LocalProvider,
      provider_config: %{snapshot: snapshot || snap()},
      invoice_mirror: FakeInvoiceMirror,
      invoice_mirror_ref: mirror_ref
    ]
  end

  defp invoice_refs(overrides \\ %{}) do
    Map.merge(%{object_id: @invoice_id, customer_id: @cus_id, subscription_id: @sub_id}, overrides)
  end

  # ---------------------------------------------------------------------------
  # done-criterion 1 — amount/tax/status mirrored; idempotent upsert
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — :invoice_finalized mirrors the authoritative snapshot" do
    test "mirrors amount/status/hosted link via the mirror port" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :applied, applied} =
               Invoice.reconcile(event(:invoice_finalized, invoice_refs()), opts(ref))

      assert applied.created == true

      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.status == :open
      assert inv.amount_due_cents == 10_000
      assert inv.hosted_invoice_url == "https://provider.example.test/invoices/in_1"
    end

    test "tax fields mirror EXACTLY when the provider computed tax" do
      ref = FakeInvoiceMirror.new()
      snap = snap(%{tax_amount_cents: 875, tax_lines: [%{"amount_cents" => 875, "display_name" => "VAT"}]})

      assert {:ok, :applied, _} = Invoice.reconcile(event(:invoice_finalized, invoice_refs()), opts(ref, snap))

      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.tax_amount_cents == 875
      assert inv.tax_lines == [%{"amount_cents" => 875, "display_name" => "VAT"}]
    end

    test "no invoice ref (object_id absent) is ignored, never errors" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :ignored} = Invoice.reconcile(event(:invoice_finalized, %{}), opts(ref))
      assert FakeInvoiceMirror.change_count(ref) == 0
    end

    test "a transient fetch failure surfaces {:error, _} for the worker to retry/DLQ" do
      ref = FakeInvoiceMirror.new()
      failing_opts = opts(ref) |> Keyword.put(:provider_config, %{})

      assert {:error, :not_found} = Invoice.reconcile(event(:invoice_finalized, invoice_refs()), failing_opts)
      assert FakeInvoiceMirror.change_count(ref) == 0
    end
  end

  describe "reconcile/2 — :invoice_paid re-mirrors the SAME row idempotently (done-criterion 1)" do
    test "finalized then paid updates the SAME row, not a duplicate" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :applied, %{created: true}} =
               Invoice.reconcile(event(:invoice_finalized, invoice_refs()), opts(ref, snap()))

      paid_snap = snap(%{status: :paid, amount_paid_cents: 10_000, hosted_receipt_url: "https://provider.example.test/receipts/r1"})

      assert {:ok, :applied, %{created: false}} =
               Invoice.reconcile(event(:invoice_paid, invoice_refs()), opts(ref, paid_snap))

      assert FakeInvoiceMirror.change_count(ref) == 2

      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.status == :paid
      assert inv.amount_paid_cents == 10_000
      assert inv.hosted_receipt_url == "https://provider.example.test/receipts/r1"
    end
  end

  describe "reconcile/2 — done-criterion: the SAME event replayed twice is a no-op" do
    test "exact replay short-circuits before a second fetch/upsert" do
      ref = FakeInvoiceMirror.new()
      ev = event(:invoice_finalized, invoice_refs())

      assert {:ok, :applied, _} = Invoice.reconcile(ev, opts(ref))
      assert {:ok, :duplicate} = Invoice.reconcile(ev, opts(ref))

      assert FakeInvoiceMirror.change_count(ref) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # fail-honest tax (ADR-014 shape applied to tax, done-criterion 3)
  # ---------------------------------------------------------------------------

  describe "fail-honest tax — unconfigured tax is nil/[], never a fabricated 0" do
    test "a snapshot with no tax data mirrors nil/[] verbatim" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :applied, _} =
               Invoice.reconcile(event(:invoice_finalized, invoice_refs()), opts(ref, snap()))

      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.tax_amount_cents == nil
      assert inv.tax_lines == []
    end
  end

  # ---------------------------------------------------------------------------
  # routing — every other kind is a defensive no-op (WebhookDispatch's job to route)
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — any non-invoice kind is a defensive no-op" do
    test "a subscription-lifecycle kind reaching Invoice.reconcile/2 is ignored" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :ignored} = Invoice.reconcile(event(:subscription_updated, invoice_refs()), opts(ref))
      assert FakeInvoiceMirror.change_count(ref) == 0
    end

    test "the dunning-owned :invoice_payment_failed kind is ignored HERE (T24's exclusive trigger)" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :ignored} = Invoice.reconcile(event(:invoice_payment_failed, invoice_refs()), opts(ref))
      assert FakeInvoiceMirror.change_count(ref) == 0
    end
  end
end
