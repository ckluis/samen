defmodule Samen.WebTest.Repo.Migrations.SupportScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37f) — mirrors `demo/priv/repo/migrations/
  20260729270000_support_scope_archivable.exs` for samen_web's test-support `ws*`-
  abbrev Support mount (`Samen.WebTest.Support`): `ticket`, `conversation`,
  `message`, `agent`, `sla`, `macro` flip `archivable true`. `csat` stays
  excluded (L — ledger). No `unique_index` exists on any of `wsk_ticket` /
  `wsc_conversation` / `wsm_message` / `wsg_agent` / `wsl_sla` / `wsn_macro`
  (confirmed by inspecting `20260708130000_mount_billing_support_scopes`) —
  nothing to convert to partial form.
  """
  use Samen.Migration

  def change do
    alter table(:wsk_ticket) do
      add(:wsk_archived_at, :utc_datetime_usec)
    end

    alter table(:wsc_conversation) do
      add(:wsc_archived_at, :utc_datetime_usec)
    end

    alter table(:wsm_message) do
      add(:wsm_archived_at, :utc_datetime_usec)
    end

    alter table(:wsg_agent) do
      add(:wsg_archived_at, :utc_datetime_usec)
    end

    alter table(:wsl_sla) do
      add(:wsl_archived_at, :utc_datetime_usec)
    end

    alter table(:wsn_macro) do
      add(:wsn_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samen.WebTest.Support.Ticket], only: [:archived_at])
    catalog_sync([Samen.WebTest.Support.Conversation], only: [:archived_at])
    catalog_sync([Samen.WebTest.Support.Message], only: [:archived_at])
    catalog_sync([Samen.WebTest.Support.Agent], only: [:archived_at])
    catalog_sync([Samen.WebTest.Support.Sla], only: [:archived_at])
    catalog_sync([Samen.WebTest.Support.Macro], only: [:archived_at])
  end
end
