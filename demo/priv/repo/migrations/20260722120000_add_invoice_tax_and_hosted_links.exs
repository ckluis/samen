defmodule Demo.Repo.Migrations.AddInvoiceTaxAndHostedLinks do
  @moduledoc """
  ADR-038 §3.5 (B4/B6, T22) — the Invoice mirror gains tax fields + the provider's
  hosted invoice/receipt links. Plain additive columns (no backfill; existing rows
  read `nil`/`[]`, which is the CORRECT fail-honest "not yet mirrored" state, never a
  fabricated zero — ADR-014 shape applied to tax). Mirrors the `samen_core` blueprint
  change (`samen_core/lib/samen/scopes/billing/blueprint.ex`'s `define_invoice/7`) onto
  Demo's `bin` Billing.Invoice abbrev, alongside the sibling driftwood/pawchart/
  samen_web migrations.
  """
  use Ecto.Migration

  def up do
    alter table(:bin_invoice) do
      add(:bin_tax_amount_cents, :integer)
      add(:bin_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:bin_hosted_invoice_url, :text)
      add(:bin_hosted_receipt_url, :text)
      add(:bin_last_event_id, :text)
    end
  end

  def down do
    alter table(:bin_invoice) do
      remove(:bin_tax_amount_cents)
      remove(:bin_tax_lines)
      remove(:bin_hosted_invoice_url)
      remove(:bin_hosted_receipt_url)
      remove(:bin_last_event_id)
    end
  end
end
