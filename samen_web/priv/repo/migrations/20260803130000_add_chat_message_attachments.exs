defmodule Samen.WebTest.Repo.Migrations.AddChatMessageAttachments do
  @moduledoc """
  T61 / C7 — chat attachments. Adds the `wcm_attachments` `{:array, :text}` column to the
  `wcm_message` table (samen_web's test-mount `wcm` Chat-Message abbrev,
  `Samen.WebTest.Chat.ChatMessage`), mirroring the `wcm_refs` array shape. Holds the
  opaque `storage_key`s minted by `Samen.Files.upload/3` (the chokepoint) and stored via
  `Samen.Scopes.Chat.Attachments` — never a raw `storage_key` write. Plain additive
  column with a `[]` default; no `catalog_sync` (non-PII opaque pointers, like `refs`).
  """
  use Ecto.Migration

  def up do
    alter table(:wcm_message) do
      add(:wcm_attachments, {:array, :text}, default: [])
    end
  end

  def down do
    alter table(:wcm_message) do
      remove(:wcm_attachments)
    end
  end
end
