defmodule Driftwood.Repo.Migrations.AddChatMessageAttachments do
  @moduledoc """
  T61 / C7 — chat attachments. Adds the `dcm_attachments` `{:array, :text}` column to the
  `dcm_message` table (driftwood's `dcm` Chat-Message abbrev, `Driftwood.Chat.ChatMessage`),
  mirroring the `dcm_refs` array shape. Holds the opaque `storage_key`s minted by
  `Samen.Files.upload/3` (the chokepoint) and stored via `Samen.Scopes.Chat.Attachments` —
  never a raw `storage_key` write. Driftwood is the first client of the framework chat
  attachments capability at ≈0 authored LOC (the column is the only per-host artifact).
  """
  use Ecto.Migration

  def up do
    alter table(:dcm_message) do
      add(:dcm_attachments, {:array, :text}, default: [])
    end
  end

  def down do
    alter table(:dcm_message) do
      remove(:dcm_attachments)
    end
  end
end
