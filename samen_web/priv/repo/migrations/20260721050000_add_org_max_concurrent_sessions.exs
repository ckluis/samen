defmodule Samen.WebTest.Repo.Migrations.AddOrgMaxConcurrentSessions do
  @moduledoc """
  ADR-035 §4.3/§5 A4 (T04, spec-questions c3) — the OPTIONAL org-level
  concurrent-session cap on the samen_web test host's operator Identity mount
  (`woo_org`). Nullable (`nil` = unlimited, the c3 default); plain bounded
  integer, no PII. Mirrors the `add_api_key_expiry_fields` add-column
  precedent (a plain additive column on an already-cataloged table — no
  `catalog_sync` needed, same posture that migration's own moduledoc notes).
  """
  use Ecto.Migration

  def up do
    alter table(:woo_org) do
      add(:woo_max_concurrent_sessions, :integer)
    end
  end

  def down do
    alter table(:woo_org) do
      remove(:woo_max_concurrent_sessions)
    end
  end
end
