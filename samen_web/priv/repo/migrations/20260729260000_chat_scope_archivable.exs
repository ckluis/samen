defmodule Samen.WebTest.Repo.Migrations.ChatScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Chat scope's adoption sub-item, on the samen_web test
  host mount (abbrevs `wct`/`wcp`/`wcm`/`wcd`): `thread` flips `archivable true`
  (samen_web/lib/samen/scopes/chat/blueprint.ex) and is the cascade PARENT of
  `thread ▸cascade participant ▸cascade message` (§5.4). `participant`/`message` are
  ALSO `archivable true` (substrate only — the cascade needs something to
  set/match/restore; policy-locked against actor-driven independent archive/restore,
  see the blueprint moduledoc). `disclosure_setting` stays excluded (a live per-org
  config row — delete is delete).

  §5.3: no `unique_index` on `wct_thread` / `wcp_participant` / `wcm_message` today
  (confirmed by inspecting `20260708160000_mount_chat_scope` — zero `unique_index`
  calls), so there is nothing to convert to partial form.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these three `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:wct_thread) do
      add(:wct_archived_at, :utc_datetime_usec)
    end

    alter table(:wcp_participant) do
      add(:wcp_archived_at, :utc_datetime_usec)
    end

    alter table(:wcm_message) do
      add(:wcm_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samen.WebTest.Chat.ChatThread], only: [:archived_at])
    catalog_sync([Samen.WebTest.Chat.ChatParticipant], only: [:archived_at])
    catalog_sync([Samen.WebTest.Chat.ChatMessage], only: [:archived_at])
  end
end
