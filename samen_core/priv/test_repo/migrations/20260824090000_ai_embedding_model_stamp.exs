defmodule SamenCore.TestRepo.Migrations.AiEmbeddingModelStamp do
  @moduledoc """
  T186 (OSS-SCAN, source: AlexClaw Apache-2.0 + BeamWeaver Apache-2.0, mode: adapt): stamp
  each `aie_embedding` row with the model identifier that produced it, so drift on model
  upgrade is DETECTABLE and an incremental re-embed can target ONLY the stale rows instead of
  a full-table re-embed on every provider change.

  ## Why nullable, never backfilled (the fail-honest posture)

  A row embedded before this migration carries no record of which model produced its vector
  (that provenance was never captured — there is nothing honest to backfill it WITH). Rather
  than guess/assume "current" for pre-existing rows (the exact silent-staleness bug this item
  exists to close), `aie_model` is added NULLABLE and left NULL for every existing row.
  `Samen.AI.Embeddings.stale_rows/2` treats `aie_model IS NULL` as stale by construction — an
  unstamped row is NEVER silently assumed current. New writes (`embed_field/6` →
  `store_vector/8`) stamp every row going forward, so the unstamped population only shrinks
  (via the incremental re-embed job) and never grows.

  Mirrors the T152 `aie_snippet` follow-on migration exactly: same table, same additive
  nullable-column shape, same precedent (`20260806120000_ai_embedding_snippet.exs`).
  """
  use Ecto.Migration

  def up do
    alter table(:aie_embedding) do
      add(:aie_model, :text)
    end
  end

  def down do
    alter table(:aie_embedding) do
      remove(:aie_model)
    end
  end
end
