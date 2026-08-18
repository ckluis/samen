defmodule Demo.Repo.Migrations.SupportScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37f) — the Support scope's adoption sub-item: `ticket`,
  `conversation`, `message`, `agent`, `sla`, `macro` flip `archivable true`
  (samen_core/lib/samen/scopes/support/blueprint.ex). `csat` stays excluded (L —
  ledger) — no column added for it.

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT, T124 microsecond fix)
  injects one abbrev-prefixed `<abbrev>_archived_at :utc_datetime_usec` column
  per adopting resource (NULL = live). §5.3: no `unique_index` exists on any of
  `stk_ticket` / `scv_conversation` / `smg_message` / `sag_agent` / `ssl_sla` /
  `smc_macro` today (confirmed by inspecting `20260706050000_add_support_scope`
  — the whole migration has zero `unique_index` calls), so there is nothing to
  convert to partial form — the ADR's "the sweep may turn up nothing" case, same
  finding as T37a/b/c/d/e's scopes.

  `ticket ▸cascade conversation ▸cascade message` (§5.4, the ADR's own canonical
  worked composition-cascade example): archiving a ticket cascades to archive its
  conversations AND their messages at the same instant
  (`Samen.Scopes.Support.CascadeArchive`); restoring a ticket restores exactly
  the same-instant-archived members (`Samen.Scopes.Support.CascadeRestore`). As
  of T125 (ADR-040 §5.4/§5.9 reconciled, posture A), conversation/message are
  ALSO independently-archivable — an authorized actor may `:archive`/`:restore`
  either directly, in addition to the ticket's cascade sweeping every still-live
  member (matching CMS's `block`; see `Samen.Scopes.Support.Blueprint`).

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these six `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:stk_ticket) do
      add(:stk_archived_at, :utc_datetime_usec)
    end

    alter table(:scv_conversation) do
      add(:scv_archived_at, :utc_datetime_usec)
    end

    alter table(:smg_message) do
      add(:smg_archived_at, :utc_datetime_usec)
    end

    alter table(:sag_agent) do
      add(:sag_archived_at, :utc_datetime_usec)
    end

    alter table(:ssl_sla) do
      add(:ssl_archived_at, :utc_datetime_usec)
    end

    alter table(:smc_macro) do
      add(:smc_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Demo.SupportScope.Ticket], only: [:archived_at])
    catalog_sync([Demo.SupportScope.Conversation], only: [:archived_at])
    catalog_sync([Demo.SupportScope.Message], only: [:archived_at])
    catalog_sync([Demo.SupportScope.Agent], only: [:archived_at])
    catalog_sync([Demo.SupportScope.Sla], only: [:archived_at])
    catalog_sync([Demo.SupportScope.Macro], only: [:archived_at])
  end
end
