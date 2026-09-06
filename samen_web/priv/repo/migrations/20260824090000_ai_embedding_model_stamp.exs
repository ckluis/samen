defmodule Samen.WebTest.Repo.Migrations.AiEmbeddingModelStamp do
  @moduledoc """
  T186 (OSS-SCAN, source: AlexClaw Apache-2.0 + BeamWeaver Apache-2.0, mode: adapt): mirrors
  `samen_core`'s `priv/test_repo/migrations/20260824090000_ai_embedding_model_stamp.exs` into
  the samen_web host DB (T78 mounted its own `aie_embedding` copy) so both DBs stay schema
  parity. Nullable, never backfilled — see the samen_core migration's moduledoc for the
  fail-honest argument (an unstamped row is stale by construction, never assumed current).
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
