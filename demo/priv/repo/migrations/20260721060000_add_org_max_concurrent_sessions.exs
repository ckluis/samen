defmodule Demo.Repo.Migrations.AddOrgMaxConcurrentSessions do
  @moduledoc """
  ADR-035 §4.3/§5 A4 (T04, spec-questions c3) — the OPTIONAL org-level
  concurrent-session cap on the demo host's Identity mount (`ido_org`).
  Nullable (`nil` = unlimited, the c3 default); plain bounded integer, no
  PII. Mirrors the `add_api_key_expiry_fields` add-column precedent (a plain
  additive column on an already-cataloged table — no `catalog_sync` needed).
  """
  use Ecto.Migration

  def up do
    alter table(:ido_org) do
      add(:ido_max_concurrent_sessions, :integer)
    end
  end

  def down do
    alter table(:ido_org) do
      remove(:ido_max_concurrent_sessions)
    end
  end
end
