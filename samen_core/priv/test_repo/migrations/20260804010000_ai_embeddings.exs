defmodule SamenCore.TestRepo.Migrations.AiEmbeddings do
  @moduledoc """
  The D3 semantic-search substrate (ADR-043 §7, T67): the pgvector extension + the org-scoped
  `aie_embedding` vector store.

  ## pgvector is REQUIRED (M3 OVERRIDE), never optional-by-detection

  `CREATE EXTENSION IF NOT EXISTS vector` runs here — semantic search is always-on, no degraded
  mode, no silent fallback. A missing extension fails setup with Postgres's own actionable
  error naming the `vector.control` file (an ENVIRONMENT error — install pgvector — never a
  fake fallback). The `pgvector` hex package (postgrex-class, §7.1) is a documented follow-on;
  T67 speaks to the column via `::vector` text casts, so the extension itself is the only hard
  prerequisite.

  ## `aie_embedding` — org-scoped vector rows (plain Ecto, the `rvq_*`/`aud_event` idiom)

  A DERIVED index table (not a tenant-facing Ash resource — the `Samen.Reveal.RevealGrant` /
  `Samen.AuditEvent` kernel-infrastructure precedent), self-qualifying `aie_*` columns:

    * `aie_org_id`         — the owning org (NOT NULL). Every `Samen.AI.Embeddings` read/write
      filters on it — the hard org-isolation invariant (§7.3): org B's vectors are never
      returned, never even ranked, for org A.
    * `aie_source_resource`/`aie_source_id`/`aie_field` — what was embedded (the resource
      module, the source row id, the declared embeddable field). NEVER the source TEXT: a
      vector is one-way, but we still persist no plaintext beside it.
    * `aie_embedding vector(64)` — the vector. `64` MUST equal
      `Samen.AI.Embedder.Deterministic.dim/0` (kept in one place there; drift would fail the
      insert cast).

  The unique index on `(org_id, source_resource, source_id, field)` makes re-embedding a row
  idempotent (embed-on-write upserts the vector). The HNSW index (`vector_l2_ops`) is the
  ash_ai pgvector shape ADR-043 §7.1 adopts, built via a raw `custom_statement`.
  """
  use Ecto.Migration

  def up do
    # M3: pgvector REQUIRED. Fails loudly (naming vector.control) if the extension is not
    # installed on the server — an environment error, never a faked vector path.
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create table(:aie_embedding, primary_key: false) do
      add(:aie_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aie_org_id, :uuid, null: false)
      add(:aie_source_resource, :text, null: false)
      add(:aie_source_id, :text, null: false)
      add(:aie_field, :text, null: false)
      # vector(64) — MUST match Samen.AI.Embedder.Deterministic.dim/0.
      add(:aie_embedding, :vector, null: false, size: 64)
      add(:aie_inserted_at, :utc_datetime_usec, null: false)
      add(:aie_updated_at, :utc_datetime_usec, null: false)
    end

    # One vector per (org, source resource, source row, field) — embed-on-write upserts.
    create(
      unique_index(:aie_embedding, [:aie_org_id, :aie_source_resource, :aie_source_id, :aie_field],
        name: :aie_embedding_source_uidx
      )
    )

    # Org-scan locality: every query is org-scoped first (§7.3).
    create(index(:aie_embedding, [:aie_org_id]))

    # HNSW approximate-NN index (ADR-043 §7.1 — the adopted ash_ai pgvector shape), via a raw
    # custom statement. L2 ops match the `<->` distance the plane orders by.
    execute(
      "CREATE INDEX aie_embedding_hnsw_idx ON aie_embedding USING hnsw (aie_embedding vector_l2_ops)",
      "DROP INDEX IF EXISTS aie_embedding_hnsw_idx"
    )

    # The T67 positive-control fixture table (SamenCore.Support.EmbeddingsDomain.Article) — a
    # non-PII source of embeddable `emb_body` text. Self-qualifying `emb_*` columns.
    create table(:emb_article, primary_key: false) do
      add(:emb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:emb_org_id, :uuid, null: false)
      add(:emb_title, :text)
      add(:emb_body, :text)
      add(:emb_inserted_at, :utc_datetime_usec, null: false)
      add(:emb_updated_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table(:emb_article))
    execute("DROP INDEX IF EXISTS aie_embedding_hnsw_idx")
    drop(table(:aie_embedding))
    # Leave the extension installed on down — other objects in a shared DB may use it, and it
    # is idempotently (re)created on up.
  end
end
