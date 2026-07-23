defmodule SamenCore.TestRepo.Migrations.SendProviderMessageId do
  @moduledoc """
  ADR-038 §4.1 (T28/C2): adds `sxn_provider_message_id` to the `sxn_send` fixture
  table (`SamenCore.Support.SuppressionFixture.Send`) so the chokepoint's
  "provider message id stored on the delivery record" claim is kernel-testable
  against a REAL Postgres row. Plain additive column — no `catalog_sync` needed
  (the `add_org_onboarded_at` precedent: an additive nullable column needs no
  catalog re-sync).
  """
  use Ecto.Migration

  def up do
    alter table(:sxn_send) do
      add(:sxn_provider_message_id, :text)
    end
  end

  def down do
    alter table(:sxn_send) do
      remove(:sxn_provider_message_id)
    end
  end
end
