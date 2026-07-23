defmodule Driftwood.Repo.Migrations.AddInvoiceTaxAndHostedLinks do
  @moduledoc """
  ADR-038 §3.5 (B4/B6, T22) — the Invoice mirror gains tax fields + the provider's
  hosted invoice/receipt links. Plain additive columns (no backfill; existing rows
  read `nil`/`[]`, which is the CORRECT fail-honest "not yet mirrored" state, never a
  fabricated zero — ADR-014 shape applied to tax). Mirrors the `samen_core` blueprint
  change (`samen_core/lib/samen/scopes/billing/blueprint.ex`'s `define_invoice/7`) onto
  BOTH of Driftwood's Invoice mounts — the tenant `fbi` Billing.Invoice and the
  operator `dpi` Operator.Invoice — alongside the sibling demo/pawchart/samen_web
  migrations.
  """
  use Ecto.Migration

  def up do
    alter table(:fbi_invoice) do
      add(:fbi_tax_amount_cents, :integer)
      add(:fbi_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:fbi_hosted_invoice_url, :text)
      add(:fbi_hosted_receipt_url, :text)
      add(:fbi_last_event_id, :text)
    end

    alter table(:dpi_invoice) do
      add(:dpi_tax_amount_cents, :integer)
      add(:dpi_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:dpi_hosted_invoice_url, :text)
      add(:dpi_hosted_receipt_url, :text)
      add(:dpi_last_event_id, :text)
    end
  end

  def down do
    alter table(:fbi_invoice) do
      remove(:fbi_tax_amount_cents)
      remove(:fbi_tax_lines)
      remove(:fbi_hosted_invoice_url)
      remove(:fbi_hosted_receipt_url)
      remove(:fbi_last_event_id)
    end

    alter table(:dpi_invoice) do
      remove(:dpi_tax_amount_cents)
      remove(:dpi_tax_lines)
      remove(:dpi_hosted_invoice_url)
      remove(:dpi_hosted_receipt_url)
      remove(:dpi_last_event_id)
    end
  end
end
