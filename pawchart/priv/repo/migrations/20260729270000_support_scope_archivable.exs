defmodule PawChart.Repo.Migrations.SupportScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37f) — mirrors `demo/priv/repo/migrations/
  20260729270000_support_scope_archivable.exs` for PawChart's `vs*`-abbrev
  Support mount (`PawChart.Support`): `ticket`, `conversation`, `message`,
  `agent`, `sla`, `macro` flip `archivable true`. `csat` stays excluded (L —
  ledger). No `unique_index` exists on any of `vsa_ticket` / `vsb_conversation`
  / `vsc_message` / `vsd_agent` / `vse_sla` / `vsf_macro` (confirmed by
  inspecting `20260708200000_pawchart_crm_support_scopes`) — nothing to convert
  to partial form.
  """
  use Samen.Migration

  def change do
    alter table(:vsa_ticket) do
      add(:vsa_archived_at, :utc_datetime_usec)
    end

    alter table(:vsb_conversation) do
      add(:vsb_archived_at, :utc_datetime_usec)
    end

    alter table(:vsc_message) do
      add(:vsc_archived_at, :utc_datetime_usec)
    end

    alter table(:vsd_agent) do
      add(:vsd_archived_at, :utc_datetime_usec)
    end

    alter table(:vse_sla) do
      add(:vse_archived_at, :utc_datetime_usec)
    end

    alter table(:vsf_macro) do
      add(:vsf_archived_at, :utc_datetime_usec)
    end

    catalog_sync([PawChart.Support.Ticket], only: [:archived_at])
    catalog_sync([PawChart.Support.Conversation], only: [:archived_at])
    catalog_sync([PawChart.Support.Message], only: [:archived_at])
    catalog_sync([PawChart.Support.Agent], only: [:archived_at])
    catalog_sync([PawChart.Support.Sla], only: [:archived_at])
    catalog_sync([PawChart.Support.Macro], only: [:archived_at])
  end
end
