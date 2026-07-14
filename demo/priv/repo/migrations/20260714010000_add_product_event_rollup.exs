defmodule Demo.Repo.Migrations.AddProductEventRollup do
  @moduledoc """
  WS-B / Phase B8 (ADR-021): the DOMAIN-SOURCED funnel/retention rollup
  (`paf_product_event_rollup`) over the `pae` product-event ledger — the G12 SEED
  read's data source. Built on the `mrr_revenue_rollup` (B2/ADR-018) precedent
  EXACTLY: a RAW rollup table, NO Ash resource fronts it, and `paf` is its COLUMN
  PREFIX, not an abbrev-registry row (the `@resource` below is the tam_table
  catalog's logical name, not a module — the same amendment the design §8 table
  records for `mrr`). Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  ## Grain (two arms in ONE table — the seed's two reads, nothing more)

    * **funnel** (`paf_kind = 'funnel'`): one row per `(org_id, stage)` for the
      signup→first-run→first-record activation funnel (stages map to the bounded
      catalog events `session.signed_in` / `first_run.completed` / `record.created`).
      A row EXISTS iff the org has ≥1 such event; `paf_actor_count` is the org's
      DISTINCT `pae_actor_ref` count for the stage (0 for org-level events like
      `first_run.completed`, which carry no actor — COUNT(DISTINCT) skips NULL).
      The operator read counts ROWS per stage cross-tenant (orgs-reached), under
      the aggregate k-anon floors — floors live at the READ, the rollup stores
      raw counts exactly like `mrr`.
    * **retention** (`paf_kind = 'retention'`): one row per
      `(org_id, cohort_week, week_offset 0..4)` — actors cohorted by the week
      (date_trunc 'week') of their FIRST `pae` event, counted DISTINCT in each
      offset week they were active. Bounded to the design's 4-week curve; offsets
      beyond 4 are NOT materialized (seed scope — no open-ended DAU/MAU surface).

  ## Erasure stance (design §4.4 — `pae` has NO subject column)

  `pae_actor_ref` is a per-subject HMAC pseudonym (`WideEvent.for_subject/2`), so
  the LOAD-BEARING erasure is B7's key destruction: post-shred the pseudonym is
  unreconstructable across live + mirror at once, and this rollup's counts stay
  honest k-anonymous aggregate (rows persist, linkage does not — AC-G12-5). The
  `:domain` spec's `subject_delete_sql` / residue scan key `pae_actor_ref` against
  the RAW subject id and therefore match ZERO rows BY CONSTRUCTION — which is
  itself the guarantee they enforce: if a sabotaged `track/1` ever leaked a raw
  subject id into `pae_actor_ref`, the domain REBUILD arm deletes it on shred and
  the DbContent oracle's independent residue scan flags any survivor. See the
  `:rollups` registry comment in `config/config.exs`.

  Token-blind by construction: every column is a bounded id (uuid), a bounded enum
  label (kind/stage as text), a week bucket (date), a count/offset (int), a
  boolean, or a timestamp — NO plaintext PII type. The `no_plaintext_pii` Rollup
  CI tier asserts exactly that over the `bounded_columns` allow-list (`paf_kind`
  / `paf_stage` / `paf_cohort_week` ride the allow-list the same way `mrr_kind`
  and `rol_day` do).

    * `paf_suppressed` — a domain rollup is subject-free aggregate by construction
      (its grain is org/stage/week, it carries NO per-subject column), so the
      ADR-018 domain arm never flips this; carried physically only so a future
      operator-driven suppression has a column (the `mrr_suppressed` precedent).
  """
  use Ecto.Migration

  @resource "Demo.Analytics.ProductEventRollup"
  @table "paf_product_event_rollup"
  @fields [
    {"paf_id", "id", "UUID"},
    {"paf_org_id", "org_id", "UUID"},
    {"paf_kind", "kind", "Text"},
    {"paf_stage", "stage", "Text"},
    {"paf_cohort_week", "cohort_week", "Date"},
    {"paf_week_offset", "week_offset", "Integer"},
    {"paf_actor_count", "actor_count", "Integer"},
    {"paf_suppressed", "suppressed", "Boolean"},
    {"paf_refreshed_at", "refreshed_at", "UTCDatetime"}
  ]

  def up do
    execute """
            CREATE TABLE #{@table} (
              paf_id           UUID        NOT NULL DEFAULT gen_random_uuid(),
              paf_org_id       UUID        NOT NULL,
              paf_kind         TEXT        NOT NULL,
              paf_stage        TEXT,
              paf_cohort_week  DATE,
              paf_week_offset  INTEGER,
              paf_actor_count  INTEGER     NOT NULL DEFAULT 0,
              paf_suppressed   BOOLEAN     NOT NULL DEFAULT FALSE,
              paf_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
              PRIMARY KEY (paf_id)
            )
            """,
            "DROP TABLE IF EXISTS #{@table}"

    execute """
            CREATE INDEX paf_product_event_rollup_read_idx
            ON #{@table} (paf_org_id, paf_kind)
            """,
            "DROP INDEX IF EXISTS paf_product_event_rollup_read_idx"

    execute """
            INSERT INTO tam_table (tam_table_name, tam_resource)
            VALUES ('#{@table}', '#{@resource}')
            ON CONFLICT (tam_table_name) DO NOTHING
            """,
            "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"

    for {col, logical, type} <- @fields do
      execute """
              INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
              VALUES ('#{@table}', '#{col}', '#{logical}', '#{type}')
              ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
              """,
              """
              DELETE FROM fld_field
              WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
              """
    end
  end

  def down do
    for {col, _logical, _type} <- Enum.reverse(@fields) do
      execute """
      DELETE FROM fld_field
      WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
      """
    end

    execute "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"
    execute "DROP INDEX IF EXISTS paf_product_event_rollup_read_idx"
    execute "DROP TABLE IF EXISTS #{@table}"
  end
end
