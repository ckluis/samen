defmodule SamenStripe.InvoiceMirrorTest do
  @moduledoc """
  B4+B6 invoice mirror — the T22 done-criteria, proven end-to-end and hermetically
  (ADR-038 §3.4/§3.5; keyless lane 0, §7.1).

  The FULL real path runs with no network and no Stripe credential:

      signed Stripe webhook body
        → SamenStripe.Provider.verify_and_parse_event/3   (real Stripe t=,v1= scheme)
        → Samen.Billing.ProviderEvent (normalized, PII-redacted)
        → Samen.Billing.Invoice.reconcile/2                (vendor-generic invoice mirror)
        → SamenStripe.Provider.fetch_object/3              (authoritative re-fetch — §3.4(1))
             served by a CASSETTE transport (config[:transport], §7.2)
        → Samen.Billing.FakeInvoiceMirror                  (the in-memory mirror port)

  Done-criteria:
    1. an invoice fixture (with tax lines) mirrors amount/tax/status EXACTLY; a
       SECOND event for the SAME invoice (`invoice.paid` after `invoice.finalized`)
       re-mirrors the SAME row IDEMPOTENTLY (one row, updated in place) — and the
       exact same event replayed is a no-op.
    2. fail-honest tax (ADR-014 shape applied to tax, done-criterion 3): an invoice
       with no tax configured mirrors `tax_amount_cents: nil` / `tax_lines: []` —
       NEVER a fabricated `0`.
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{FakeInvoiceMirror, Invoice, ProviderEvent}
  alias Samen.Webhook.Signer
  alias SamenStripe.Provider

  @secret "whsec_test_5f3a9c2b1d4e6f8a0c2e4b6d8f0a1c3e"
  @secret_key "sk_test_invoice_mirror"

  @invoice_id "in_tax_finalized"
  @cus_id "cus_invoice_tax"
  @sub_id "sub_invoice_tax"

  @t1_unix 1_782_518_400
  @t2_unix 1_783_000_000

  # --- cassette + event helpers ----------------------------------------------

  defp fixture(name) do
    Path.join([__DIR__, "fixtures", name])
    |> File.read!()
    |> Jason.decode!()
  end

  defp cassette(fixture_name) do
    body = fixture(fixture_name)
    fn %{method: :get} -> {:ok, %{status: 200, body: body}} end
  end

  defp config(fixture_name) do
    %{secret_key: @secret_key, transport: cassette(fixture_name)}
  end

  # Build + sign + parse a real Stripe invoice webhook, returning the normalized
  # ProviderEvent (exercising the real signature-verify + parse path). The webhook
  # object IS the invoice — `id`/`customer`/`subscription` are recovered from it
  # exactly as `SamenStripe.Provider.extract_refs/1` does for a live delivery.
  defp event(stripe_type, invoice_id, customer_id, subscription_id, created_unix) do
    body =
      Jason.encode!(%{
        "id" => "evt_#{stripe_type}_#{invoice_id}_#{created_unix}",
        "type" => stripe_type,
        "created" => created_unix,
        "data" => %{
          "object" => %{
            "id" => invoice_id,
            "object" => "invoice",
            "customer" => customer_id,
            "subscription" => subscription_id
          }
        }
      })

    ts = System.system_time(:second)
    sig = Signer.sign(body, ts, @secret)
    headers = [{"stripe-signature", sig}]

    {:ok, %ProviderEvent{} = ev} =
      Provider.verify_and_parse_event(body, headers, %{
        secret_key: @secret_key,
        webhook_secret: @secret
      })

    ev
  end

  defp opts(fixture_name, ref) do
    [
      invoice_mirror: FakeInvoiceMirror,
      invoice_mirror_ref: ref,
      provider: Provider,
      provider_config: config(fixture_name)
    ]
  end

  defp deliver(ref, stripe_type, invoice_id, customer_id, subscription_id, created_unix, fixture_name) do
    Invoice.reconcile(event(stripe_type, invoice_id, customer_id, subscription_id, created_unix), opts(fixture_name, ref))
  end

  # ---------------------------------------------------------------------------
  # 1. amount/tax/status mirrored exactly; idempotent re-mirror across kinds
  # ---------------------------------------------------------------------------

  describe "done-criterion 1 — invoice mirrors amount/tax/status exactly" do
    test "invoice.finalized mirrors amount/tax/status/hosted link from the fixture verbatim" do
      ref = FakeInvoiceMirror.new()

      assert {:ok, :applied, _} =
               deliver(ref, "invoice.finalized", @invoice_id, @cus_id, @sub_id, @t1_unix, "invoice_finalized_with_tax.json")

      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.status == :open
      assert inv.amount_due_cents == 32_130
      assert inv.amount_paid_cents == 0
      assert inv.currency == "usd"
      # Tax mirrored EXACTLY from the fixture — never computed here.
      assert inv.tax_amount_cents == 2_130
      assert [tax_line] = inv.tax_lines
      assert tax_line["amount_cents"] == 2_130
      assert tax_line["display_name"] == "CA Sales Tax"
      assert tax_line["percentage"] == 7.25
      assert tax_line["jurisdiction"] == "California"
      # Hosted invoice link present; no receipt yet (unpaid — fixture's charge is nil).
      assert inv.hosted_invoice_url == "https://invoice.stripe.com/i/acct_test/in_tax_finalized"
      assert inv.hosted_receipt_url == nil
    end

    test "invoice.paid re-mirrors the SAME row (idempotent upsert, not a duplicate)" do
      ref = FakeInvoiceMirror.new()

      deliver(ref, "invoice.finalized", @invoice_id, @cus_id, @sub_id, @t1_unix, "invoice_finalized_with_tax.json")

      assert {:ok, :applied, applied} =
               deliver(ref, "invoice.paid", @invoice_id, @cus_id, @sub_id, @t2_unix, "invoice_paid_with_tax.json")

      # Updated in place (NOT a fresh create) — the upsert converged onto the
      # SAME row the `invoice.finalized` delivery already created.
      assert applied.created == false
      assert FakeInvoiceMirror.change_count(ref) == 2

      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.status == :paid
      assert inv.amount_paid_cents == 32_130
      assert inv.paid_at == DateTime.from_unix!(1_782_600_000)
      # The receipt link only appears once a charge exists (the paid fixture's
      # expanded charge) — hosted invoice link is unchanged/still present.
      assert inv.hosted_receipt_url == "https://pay.stripe.com/receipts/acct_test/ch_invoice_tax"
      assert inv.hosted_invoice_url == "https://invoice.stripe.com/i/acct_test/in_tax_finalized"
      # Tax stays mirrored exactly (same fixture tax figures on the paid invoice).
      assert inv.tax_amount_cents == 2_130
    end

    test "the exact same event replayed twice is a no-op (single change)" do
      ref = FakeInvoiceMirror.new()
      ev = event("invoice.finalized", @invoice_id, @cus_id, @sub_id, @t1_unix)
      o = opts("invoice_finalized_with_tax.json", ref)

      assert {:ok, :applied, _} = Invoice.reconcile(ev, o)
      assert {:ok, :duplicate} = Invoice.reconcile(ev, o)

      assert FakeInvoiceMirror.change_count(ref) == 1
    end

    test "delivered out of order (paid then finalized) still converges — only ONE row" do
      ref = FakeInvoiceMirror.new()

      deliver(ref, "invoice.paid", @invoice_id, @cus_id, @sub_id, @t2_unix, "invoice_paid_with_tax.json")
      deliver(ref, "invoice.finalized", @invoice_id, @cus_id, @sub_id, @t1_unix, "invoice_finalized_with_tax.json")

      assert FakeInvoiceMirror.change_count(ref) == 2
      # Both events fetch (and thus mirror) whatever is CURRENTLY authoritative for
      # THAT delivery's cassette — no watermark clobber hazard, no duplicate row.
      inv = FakeInvoiceMirror.get_invoice(ref, @invoice_id)
      assert inv.provider_invoice_id == @invoice_id
    end
  end

  # ---------------------------------------------------------------------------
  # 2. fail-honest tax — unconfigured tax renders honestly absent
  # ---------------------------------------------------------------------------

  describe "done-criterion 2 — fail-honest tax (ADR-014 shape applied to tax)" do
    test "an invoice with no tax configured mirrors nil/[] — NEVER a fabricated 0" do
      ref = FakeInvoiceMirror.new()
      invoice_id = "in_no_tax_finalized"

      assert {:ok, :applied, _} =
               deliver(ref, "invoice.finalized", invoice_id, "cus_invoice_no_tax", "sub_invoice_no_tax", @t1_unix, "invoice_finalized_no_tax.json")

      inv = FakeInvoiceMirror.get_invoice(ref, invoice_id)
      assert inv.tax_amount_cents == nil
      assert inv.tax_lines == []
      # The rest of the invoice mirrors normally — tax absence is the ONLY honest gap.
      assert inv.status == :open
      assert inv.amount_due_cents == 30_000
    end
  end

  # ---------------------------------------------------------------------------
  # normalization + fail-honest spot checks (the adapter side of the seam)
  # ---------------------------------------------------------------------------

  describe "adapter fetch_object(:invoice, …) normalization" do
    test "maps Stripe invoice fields to the vendor-neutral snapshot" do
      {:ok, snap} = Provider.fetch_object(:invoice, @invoice_id, config("invoice_finalized_with_tax.json"))

      assert snap.provider_invoice_id == @invoice_id
      assert snap.provider_customer_id == @cus_id
      assert snap.provider_subscription_id == @sub_id
      assert snap.status == :open
      assert snap.amount_due_cents == 32_130
      assert snap.tax_amount_cents == 2_130
      assert [%{"description" => "Pro plan — Jul 2026", "amount_cents" => 30_000}] = snap.line_items
    end

    test "unconfigured fetch refuses (fail-honest), configured 404 is :not_found" do
      assert {:error, :not_configured} = Provider.fetch_object(:invoice, @invoice_id, %{})

      cfg = %{secret_key: @secret_key, transport: fn _ -> {:ok, %{status: 404, body: %{}}} end}
      assert {:error, :not_found} = Provider.fetch_object(:invoice, "in_missing", cfg)
    end
  end

  # ---------------------------------------------------------------------------
  # routing — non-invoice kinds are ignored (WebhookDispatch's job to route)
  # ---------------------------------------------------------------------------

  test "a non-invoice kind is a safe no-op (Samen.Billing.Invoice only handles invoice kinds)" do
    ev = %ProviderEvent{provider: :stripe, event_id: "evt_x", kind: :subscription_created, occurred_at: DateTime.utc_now(), provider_refs: %{}, payload: %{}}
    assert {:ok, :ignored} = Invoice.reconcile(ev, opts("invoice_finalized_with_tax.json", FakeInvoiceMirror.new()))
  end
end
