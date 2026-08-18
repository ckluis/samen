defmodule Samen.WebTest.Repo.Migrations.AiEmbeddings do
  @moduledoc """
  The D3 semantic-search substrate (ADR-043 §7, T67) — the samen_web test host's FIRST
  materialization of the `aie_embedding` vector store, needed by T78 (spec §I5)'s KB
  composer-suggestion + deflection tests. Mirrors `samen_core`'s
  `priv/test_repo/migrations/20260804010000_ai_embeddings.exs` +
  `20260806120000_ai_embedding_snippet.exs` (T152's `aie_snippet` column folded in from
  the start, since this mount is brand new — no separate follow-on migration needed).

  ## pgvector is REQUIRED (M3 OVERRIDE), never optional-by-detection

  `CREATE EXTENSION IF NOT EXISTS vector` — semantic search is always-on, no degraded mode.
  A missing extension fails setup with Postgres's own actionable error (install pgvector),
  never a faked fallback (CLAUDE.md prerequisite: `brew install pgvector`).

  ## `aie_embedding` — org-scoped vector rows (plain Ecto, the `Samen.AuditEvent` idiom)

  A DERIVED index table (not a tenant-facing Ash resource). `aie_embedding vector(64)` MUST
  match `Samen.AI.Embedder.Deterministic.dim/0` (the keyless :test-only embedder T78's KB
  suggestion/deflection tests exercise). `aie_snippet` (T152) is the self-describing Hit
  excerpt — masking-safe by construction (an embedded field is non-PII by construction, see
  the samen_core migration's moduledoc for the full argument).
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create table(:aie_embedding, primary_key: false) do
      add(:aie_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aie_org_id, :uuid, null: false)
      add(:aie_source_resource, :text, null: false)
      add(:aie_source_id, :text, null: false)
      add(:aie_field, :text, null: false)
      # vector(64) — MUST match Samen.AI.Embedder.Deterministic.dim/0.
      add(:aie_embedding, :vector, null: false, size: 64)
      add(:aie_snippet, :text)
      add(:aie_inserted_at, :utc_datetime_usec, null: false)
      add(:aie_updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:aie_embedding, [:aie_org_id, :aie_source_resource, :aie_source_id, :aie_field],
        name: :aie_embedding_source_uidx
      )
    )

    create(index(:aie_embedding, [:aie_org_id]))

    execute(
      "CREATE INDEX aie_embedding_hnsw_idx ON aie_embedding USING hnsw (aie_embedding vector_l2_ops)",
      "DROP INDEX IF EXISTS aie_embedding_hnsw_idx"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS aie_embedding_hnsw_idx")
    drop(table(:aie_embedding))
  end
end
