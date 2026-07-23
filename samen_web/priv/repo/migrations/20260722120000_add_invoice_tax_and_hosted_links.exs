defmodule Samen.WebTest.Repo.Migrations.AddInvoiceTaxAndHostedLinks do
  @moduledoc """
  ADR-038 §3.5 (B4/B6, T22) — the Invoice mirror gains tax fields + the provider's
  hosted invoice/receipt links. Plain additive columns (no backfill; existing rows
  read `nil`/`[]`, which is the CORRECT fail-honest "not yet mirrored" state, never a
  fabricated zero — ADR-014 shape applied to tax). Mirrors the `samen_core` blueprint
  change (`samen_core/lib/samen/scopes/billing/blueprint.ex`'s `define_invoice/7`) onto
  BOTH of samen_web's test-support Invoice mounts — the tenant `wbi`
  `Samen.WebTest.Billing.Invoice` and the operator `wpi`
  `Samen.WebTest.Operator.Invoice` — alongside the sibling demo/driftwood/pawchart
  migrations.
  """
  use Ecto.Migration

  def up do
    alter table(:wbi_invoice) do
      add(:wbi_tax_amount_cents, :integer)
      add(:wbi_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:wbi_hosted_invoice_url, :text)
      add(:wbi_hosted_receipt_url, :text)
      add(:wbi_last_event_id, :text)
    end

    alter table(:wpi_invoice) do
      add(:wpi_tax_amount_cents, :integer)
      add(:wpi_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:wpi_hosted_invoice_url, :text)
      add(:wpi_hosted_receipt_url, :text)
      add(:wpi_last_event_id, :text)
    end
  end

  def down do
    alter table(:wbi_invoice) do
      remove(:wbi_tax_amount_cents)
      remove(:wbi_tax_lines)
      remove(:wbi_hosted_invoice_url)
      remove(:wbi_hosted_receipt_url)
      remove(:wbi_last_event_id)
    end

    alter table(:wpi_invoice) do
      remove(:wpi_tax_amount_cents)
      remove(:wpi_tax_lines)
      remove(:wpi_hosted_invoice_url)
      remove(:wpi_hosted_receipt_url)
      remove(:wpi_last_event_id)
    end
  end
end
