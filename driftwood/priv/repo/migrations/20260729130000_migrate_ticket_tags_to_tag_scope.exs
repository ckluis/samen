defmodule Driftwood.Repo.Migrations.MigrateTicketTagsToTagScope do
  @moduledoc """
  F4/T46 — migrates Driftwood's Support-scope `Ticket.tags` (`fsk_tags`) to the
  generic `Driftwood.Tags` `Tag`/`Tagging` mechanism, then drops the column.
  Mirrors `demo/priv/repo/migrations/20260729130000_migrate_ticket_tags_to_tag_scope.exs`
  with Driftwood's own abbrevs (`fsk_ticket`, `ftt_tag`/`tft_tagging`) and
  object-ref key `"support.ticket"` (`Driftwood.Support` carries no `Scope`
  suffix, unlike demo). Requires `20260729120000_add_tags_scope.exs` to have
  run first. Contract-phase; `down/0` is a documented no-op (same posture as
  the demo migration — see its moduledoc for the full rationale).
  """
  use Samen.Migration, phase: :contract

  def up do
    if column_exists?("fsk_ticket", "fsk_tags") do
      execute(seed_tags_sql())
      execute(seed_taggings_sql())
    end

    alter table(:fsk_ticket) do
      remove_if_exists(:fsk_tags)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'fsk_ticket' AND fld_column_name = 'fsk_tags'")
  end

  def down do
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

  defp seed_tags_sql do
    """
    INSERT INTO ftt_tag (ftt_org_id, ftt_name, ftt_color, ftt_inserted_at, ftt_updated_at)
    SELECT DISTINCT fsk_org_id, unnest(fsk_tags), 'gray', now(), now()
    FROM fsk_ticket
    WHERE fsk_tags IS NOT NULL AND array_length(fsk_tags, 1) > 0
    ON CONFLICT (ftt_org_id, ftt_name) WHERE ftt_archived_at IS NULL DO NOTHING
    """
  end

  defp seed_taggings_sql do
    """
    INSERT INTO tft_tagging (
      tft_org_id, tft_tag_id, tft_subject_key, tft_subject_id, tft_inserted_at, tft_updated_at
    )
    SELECT
      tk.fsk_org_id,
      tag.ftt_id,
      'support.ticket',
      tk.fsk_id,
      now(),
      now()
    FROM fsk_ticket tk
    CROSS JOIN LATERAL unnest(tk.fsk_tags) AS tag_name
    JOIN ftt_tag tag
      ON tag.ftt_org_id = tk.fsk_org_id
     AND tag.ftt_name = tag_name
     AND tag.ftt_archived_at IS NULL
    WHERE tk.fsk_tags IS NOT NULL
    ON CONFLICT (tft_tag_id, tft_subject_key, tft_subject_id) DO NOTHING
    """
  end
end
