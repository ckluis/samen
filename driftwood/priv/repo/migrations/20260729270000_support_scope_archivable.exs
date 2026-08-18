defmodule Driftwood.Repo.Migrations.SupportScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37f) — mirrors `demo/priv/repo/migrations/
  20260729270000_support_scope_archivable.exs` for Driftwood's `fs*`-abbrev
  Support mount (`Driftwood.Support`): `ticket`, `conversation`, `message`,
  `agent`, `sla`, `macro` flip `archivable true`. `csat` stays excluded (L —
  ledger). No `unique_index` exists on any of `fsk_ticket` / `fsc_conversation`
  / `fsm_message` / `fsa_agent` / `fsl_sla` / `fsn_macro` (confirmed by
  inspecting `20260708110000_mount_billing_support_scopes`) — nothing to
  convert to partial form.
  """
  use Samen.Migration

  def change do
    alter table(:fsk_ticket) do
      add(:fsk_archived_at, :utc_datetime_usec)
    end

    alter table(:fsc_conversation) do
      add(:fsc_archived_at, :utc_datetime_usec)
    end

    alter table(:fsm_message) do
      add(:fsm_archived_at, :utc_datetime_usec)
    end

    alter table(:fsa_agent) do
      add(:fsa_archived_at, :utc_datetime_usec)
    end

    alter table(:fsl_sla) do
      add(:fsl_archived_at, :utc_datetime_usec)
    end

    alter table(:fsn_macro) do
      add(:fsn_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Support.Ticket], only: [:archived_at])
    catalog_sync([Driftwood.Support.Conversation], only: [:archived_at])
    catalog_sync([Driftwood.Support.Message], only: [:archived_at])
    catalog_sync([Driftwood.Support.Agent], only: [:archived_at])
    catalog_sync([Driftwood.Support.Sla], only: [:archived_at])
    catalog_sync([Driftwood.Support.Macro], only: [:archived_at])
  end
end
