defmodule Demo.Repo.Migrations.AddOrgOnboardedAt do
  @moduledoc """
  ADR-035 §5 A8 (T08) — mirrors
  `samen_web/priv/repo/migrations/20260722020000_add_org_onboarded_at.exs`
  exactly, adapted to demo's `ido_org` abbrev. The onboarding-wizard
  COMPLETION marker (Tier-0 org setting; nil until
  `Samen.Web.Onboarding.complete!/3` lands it — the "never re-trap"
  contract). Plain additive column, no `catalog_sync` needed (the
  `add_org_max_concurrent_sessions` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:ido_org) do
      add(:ido_onboarded_at, :utc_datetime)
    end
  end

  def down do
    alter table(:ido_org) do
      remove(:ido_onboarded_at)
    end
  end
end
