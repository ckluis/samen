defmodule PawChart.Repo.Migrations.AddInvoiceTaxAndHostedLinks do
  @moduledoc """
  ADR-038 §3.5 (B4/B6, T22) — the Invoice mirror gains tax fields + the provider's
  hosted invoice/receipt links. Plain additive columns (no backfill; existing rows
  read `nil`/`[]`, which is the CORRECT fail-honest "not yet mirrored" state, never a
  fabricated zero — ADR-014 shape applied to tax). Mirrors the `samen_core` blueprint
  change (`samen_core/lib/samen/scopes/billing/blueprint.ex`'s `define_invoice/7`) onto
  PawChart's `pbi` Billing.Invoice abbrev, alongside the sibling demo/driftwood/
  samen_web migrations.
  """
  use Ecto.Migration

  def up do
    alter table(:pbi_invoice) do
      add(:pbi_tax_amount_cents, :integer)
      add(:pbi_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:pbi_hosted_invoice_url, :text)
      add(:pbi_hosted_receipt_url, :text)
      add(:pbi_last_event_id, :text)
    end
  end

  def down do
    alter table(:pbi_invoice) do
      remove(:pbi_tax_amount_cents)
      remove(:pbi_tax_lines)
      remove(:pbi_hosted_invoice_url)
      remove(:pbi_hosted_receipt_url)
      remove(:pbi_last_event_id)
    end
  end
end
