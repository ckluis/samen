defmodule Driftwood.Repo.Migrations.ChatScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Chat scope's adoption sub-item, on the Driftwood mount
  (abbrevs `dct`/`dcp`/`dcm`/`dcd`): `thread` flips `archivable true`
  (samen_web/lib/samen/scopes/chat/blueprint.ex) and is the cascade PARENT of
  `thread ▸cascade participant ▸cascade message` (§5.4). `participant`/`message` are
  ALSO `archivable true` (substrate only — the cascade needs something to
  set/match/restore; policy-locked against actor-driven independent archive/restore,
  see the blueprint moduledoc). `disclosure_setting` stays excluded (a live per-org
  config row — delete is delete).

  §5.3: no `unique_index` on `dct_thread` / `dcp_participant` / `dcm_message` today
  (confirmed by inspecting `20260708170000_mount_chat_scope` — zero `unique_index`
  calls), so there is nothing to convert to partial form.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these three `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:dct_thread) do
      add(:dct_archived_at, :utc_datetime_usec)
    end

    alter table(:dcp_participant) do
      add(:dcp_archived_at, :utc_datetime_usec)
    end

    alter table(:dcm_message) do
      add(:dcm_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Chat.ChatThread], only: [:archived_at])
    catalog_sync([Driftwood.Chat.ChatParticipant], only: [:archived_at])
    catalog_sync([Driftwood.Chat.ChatMessage], only: [:archived_at])
  end
end
