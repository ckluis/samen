defmodule PawChart.Repo.Migrations.AddSendProviderMessageId do
  @moduledoc """
  ADR-038 §4.1 (T28/C2 — the outbound send-lifecycle chokepoint). Mirrors
  `samen_core/priv/test_repo/migrations/20260722110000_send_provider_message_id.exs`,
  adapted to PawChart's `vmn` Marketing-Send abbrev. Adds the provider's own
  message id (returned on `{:ok, receipt}` from `Samen.Delivery.Provider.deliver/2`)
  as a real column on `PawChart.Marketing.Send` — the token-blind join key T30's
  deliverability-webhook reconciliation matches events against. Plain additive
  nullable column, no `catalog_sync` needed (the `add_org_onboarded_at` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:vmn_send) do
      add(:vmn_provider_message_id, :text)
    end
  end

  def down do
    alter table(:vmn_send) do
      remove(:vmn_provider_message_id)
    end
  end
end
