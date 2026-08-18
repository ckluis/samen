defmodule Samen.Web.BillingInvoiceTaxLinksTest do
  @moduledoc """
  T22/B4+B6 — the tenant billing page renders hosted invoice/receipt links + the
  fail-honest tax figure; the operator plane sees amounts only, NEVER the hosted
  links or customer PII (INV-2 — token-blind operator view; ADR-038 §3.5 "hosted
  links surfaced tenant-side").
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Billing.{Customer, Invoice}

  defp seed_invoice(org_id, attrs) do
    customer =
      Customer
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, billing_name: "Tax Links Fixture Co", billing_email: "taxlinks@example.test", status: :active},
        authorize?: false
      )
      |> Ash.create!()

    Invoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          customer_id: customer.id,
          status: :open,
          amount_due_cents: 32_130,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second)
        },
        attrs
      ),
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # Tenant plane — hosted links + tax render
  # ---------------------------------------------------------------------------

  test "TENANT plane: hosted invoice + receipt links render when the mirror carries them" do
    org_id = Ash.UUID.generate()

    seed_invoice(org_id, %{
      tax_amount_cents: 2_130,
      hosted_invoice_url: "https://invoice.example.test/i/in_tax_links_1",
      hosted_receipt_url: "https://pay.example.test/receipts/ch_tax_links_1"
    })

    mount = build_mount(:billing, plane: :tenant)
    html = render_live(Samen.Web.Billing.InvoicesLive, mount, [org_id])

    assert html =~ "invoice-row"
    assert html =~ ~s(href="https://invoice.example.test/i/in_tax_links_1")
    assert html =~ "View invoice"
    assert html =~ ~s(href="https://pay.example.test/receipts/ch_tax_links_1")
    assert html =~ "Receipt"
    # Tax figure ($21.30) renders — mirrored verbatim from the fixture.
    assert html =~ "21.30"
  end

  test "TENANT plane: fail-honest tax — nil tax renders an honest absence, never a fabricated $0.00" do
    org_id = Ash.UUID.generate()

    seed_invoice(org_id, %{tax_amount_cents: nil, hosted_invoice_url: nil, hosted_receipt_url: nil})

    mount = build_mount(:billing, plane: :tenant)
    html = render_live(Samen.Web.Billing.InvoicesLive, mount, [org_id])

    assert html =~ "invoice-row"
    assert html =~ ~s(class="inv-tax")
    # The Tax cell renders the honest em-dash, never "$0.00" — extract the
    # tax cell specifically so this assertion cannot be satisfied by some
    # OTHER dollar figure on the page (amount/paid columns legitimately show $).
    [_, tax_cell_and_rest] = String.split(html, ~s(class="inv-tax"), parts: 2)
    tax_cell = tax_cell_and_rest |> String.split("</td>", parts: 2) |> hd()
    assert tax_cell =~ "—"
    refute tax_cell =~ "$0.00"
    refute tax_cell =~ "0.00"
    # No hosted links offered when the mirror carries none.
    refute html =~ "View invoice"
    refute html =~ "Receipt"
  end

  # ---------------------------------------------------------------------------
  # Operator plane — INV-2: amounts only, NEVER the hosted links, NEVER customer PII
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: hosted links are ABSENT (tenant-side only, ADR-038 §3.5); tax amount alone is fine" do
    org_id = Ash.UUID.generate()

    seed_invoice(org_id, %{
      tax_amount_cents: 2_130,
      hosted_invoice_url: "https://invoice.example.test/i/in_tax_links_operator",
      hosted_receipt_url: "https://pay.example.test/receipts/ch_tax_links_operator"
    })

    mount = build_mount(:billing, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.Billing.InvoicesLive, mount, [org_id])

    assert html =~ "invoice-row"
    # INV-2: NEVER the hosted invoice/receipt link on the operator plane — not the
    # href, not the "View invoice"/"Receipt" affordance, not the raw provider URL
    # anywhere in the DOM (the operator's write/link column is gated off entirely
    # by `writable?/1`, the same plane predicate the delete action uses).
    refute html =~ "https://invoice.example.test"
    refute html =~ "https://pay.example.test"
    refute html =~ "View invoice"
    refute html =~ "Receipt"
    refute html =~ "inv-links"
    # INV-2: customer PII stays masked, no vault token leak.
    assert html =~ "••••"
    refute html =~ "Tax Links Fixture Co"
    refute html =~ "taxlinks@example.test"
    refute html =~ "vt_"
  end
end
