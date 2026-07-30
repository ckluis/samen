defmodule Demo.Repo.Migrations.MigrateTicketTagsToTagScope do
  @moduledoc """
  F4/T46 (spec §F4) — migrates the Support scope's bespoke `Ticket.tags`
  (`{:array, :string}`, `stk_tags`) column to the generic `Samen.Scopes.Tags`
  `Tag`/`Tagging` mechanism, then DROPS the array column. Same shape as the
  `H1MoneyMigration` precedent (`20260721030000_h1_money_migration.exs`) — a
  single-migration, same-transaction data copy + column drop (M6; ADR-037
  §5.2), NOT the whole-table-excision shape `MigrateActivityToTask` used
  (Ticket keeps existing; only ONE column moves+drops). Requires
  `20260729120000_add_tags_scope.exs` (creates `dtt_tag`/`tdt_tagging`) to
  have run first.

  ## Zero-drop, set-based copy (ADR-040 §5's "zero data drop" convention)

  1. **Tags**: every DISTINCT `(org_id, tag_name)` pair unnested out of every
     ticket's `stk_tags` array becomes ONE live `dtt_tag` row (find-or-create
     via `ON CONFLICT` against the SAME partial unique index `Tag`'s own
     uniqueness relies on — `(org_id, name) WHERE archived_at IS NULL`).
  2. **Taggings**: every `(ticket, tag)` PAIR becomes one `tdt_tagging` row,
     anchored `subject_key = "support_scope.ticket"` (demo's OWN
     `Samen.Web.ObjectRef.Catalog.key_for(Demo.SupportScope.Ticket)` —
     `SupportScope` is NOT renamed by this migration, only Tags dropped its
     `Scope` suffix; see `Demo.Tags` moduledoc), `subject_id = ticket.id`.
     `ON CONFLICT (tag_id, subject_key, subject_id) DO NOTHING` — idempotent,
     matches `Tagging`'s own uniqueness.
  3. **Drop**: `stk_tags` is removed from `stk_ticket` + its `fld_field` row is
     deleted (`catalog_parity` would otherwise flag an orphan row — the
     `H1MoneyMigration` precedent).

  Contract-phase (destructive column drop, no bake window needed — same M6
  posture as `H1MoneyMigration`; PITR-covered, not `down/0`-round-trip-tested).
  `down/0` is a documented no-op: reversing would require re-deriving
  `stk_tags` from Tagging rows, which is NOT lossless (a ticket may have
  gained/lost tags via the generic mechanism since the forward migration ran)
  — same posture as `MigrateActivityToTask`'s `down/0`.
  """
  use Samen.Migration, phase: :contract

  def up do
    if column_exists?("stk_ticket", "stk_tags") do
      execute(seed_tags_sql())
      execute(seed_taggings_sql())
    end

    alter table(:stk_ticket) do
      remove_if_exists(:stk_tags)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'stk_ticket' AND fld_column_name = 'stk_tags'")
  end

  def down do
    # Contract-phase / PITR-covered (same posture as MigrateActivityToTask's
    # down/0) — re-deriving stk_tags from Tagging rows is not lossless (tags
    # may have been added/removed via the generic mechanism since forward-
    # migrating), so the reversal is a documented no-op, not a fabricated
    # backfill.
    :ok
  end

  defp column_exists?(table, column) do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    rows != []
  end

  # One live dtt_tag row per DISTINCT (org, tag name) unnested out of every
  # ticket's stk_tags array. ON CONFLICT matches Tag's own live-uniqueness
  # partial index (dtt_tag_org_name_live_index).
  defp seed_tags_sql do
    """
    INSERT INTO dtt_tag (dtt_org_id, dtt_name, dtt_color, dtt_inserted_at, dtt_updated_at)
    SELECT DISTINCT stk_org_id, unnest(stk_tags), 'gray', now(), now()
    FROM stk_ticket
    WHERE stk_tags IS NOT NULL AND array_length(stk_tags, 1) > 0
    ON CONFLICT (dtt_org_id, dtt_name) WHERE dtt_archived_at IS NULL DO NOTHING
    """
  end

  # One tdt_tagging row per (ticket, tag) pair, anchored to the ticket's
  # object-ref key ("support_scope.ticket" on demo). ON CONFLICT matches
  # Tagging's own uniqueness (tdt_tagging_tag_subject_index).
  defp seed_taggings_sql do
    """
    INSERT INTO tdt_tagging (
      tdt_org_id, tdt_tag_id, tdt_subject_key, tdt_subject_id, tdt_inserted_at, tdt_updated_at
    )
    SELECT
      tk.stk_org_id,
      tag.dtt_id,
      'support_scope.ticket',
      tk.stk_id,
      now(),
      now()
    FROM stk_ticket tk
    CROSS JOIN LATERAL unnest(tk.stk_tags) AS tag_name
    JOIN dtt_tag tag
      ON tag.dtt_org_id = tk.stk_org_id
     AND tag.dtt_name = tag_name
     AND tag.dtt_archived_at IS NULL
    WHERE tk.stk_tags IS NOT NULL
    ON CONFLICT (tdt_tag_id, tdt_subject_key, tdt_subject_id) DO NOTHING
    """
  end
end
