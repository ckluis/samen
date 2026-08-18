defmodule Samen.WebTest.Repo.Migrations.AddOrgOnboardedAt do
  @moduledoc """
  ADR-035 §5 A8 (T08) — the onboarding-wizard COMPLETION marker on the
  samen_web test host's operator Identity mount (`woo_org`). Nullable
  `utc_datetime`; nil until `Samen.Web.Onboarding.complete!/3` lands it —
  the Tier-0 org setting that makes the wizard never re-trap (its own
  moduledoc). Mirrors the `add_org_max_concurrent_sessions` add-column
  precedent: a plain additive column on an already-cataloged table, no
  `catalog_sync` needed.
  """
  use Ecto.Migration

  def up do
    alter table(:woo_org) do
      add(:woo_onboarded_at, :utc_datetime)
    end
  end

  def down do
    alter table(:woo_org) do
      remove(:woo_onboarded_at)
    end
  end
end
