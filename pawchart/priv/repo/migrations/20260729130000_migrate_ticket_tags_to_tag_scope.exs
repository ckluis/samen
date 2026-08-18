defmodule PawChart.Repo.Migrations.MigrateTicketTagsToTagScope do
  @moduledoc """
  F4/T46 — migrates PawChart's Support-scope `Ticket.tags` (`vsa_tags`) to the
  generic `PawChart.Tags` `Tag`/`Tagging` mechanism, then drops the column.
  Mirrors `demo/priv/repo/migrations/20260729130000_migrate_ticket_tags_to_tag_scope.exs`
  with PawChart's own abbrevs (`vsa_ticket`, `ptt_tag`/`tpt_tagging`) and
  object-ref key `"support.ticket"` (`PawChart.Support` carries no `Scope`
  suffix, unlike demo). Requires `20260729120000_add_tags_scope.exs` to have
  run first. Contract-phase; `down/0` is a documented no-op (same posture as
  the demo migration — see its moduledoc for the full rationale).
  """
  use Samen.Migration, phase: :contract

  def up do
    if column_exists?("vsa_ticket", "vsa_tags") do
      execute(seed_tags_sql())
      execute(seed_taggings_sql())
    end

    alter table(:vsa_ticket) do
      remove_if_exists(:vsa_tags)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'vsa_ticket' AND fld_column_name = 'vsa_tags'")
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
    INSERT INTO ptt_tag (ptt_org_id, ptt_name, ptt_color, ptt_inserted_at, ptt_updated_at)
    SELECT DISTINCT vsa_org_id, unnest(vsa_tags), 'gray', now(), now()
    FROM vsa_ticket
    WHERE vsa_tags IS NOT NULL AND array_length(vsa_tags, 1) > 0
    ON CONFLICT (ptt_org_id, ptt_name) WHERE ptt_archived_at IS NULL DO NOTHING
    """
  end

  defp seed_taggings_sql do
    """
    INSERT INTO tpt_tagging (
      tpt_org_id, tpt_tag_id, tpt_subject_key, tpt_subject_id, tpt_inserted_at, tpt_updated_at
    )
    SELECT
      tk.vsa_org_id,
      tag.ptt_id,
      'support.ticket',
      tk.vsa_id,
      now(),
      now()
    FROM vsa_ticket tk
    CROSS JOIN LATERAL unnest(tk.vsa_tags) AS tag_name
    JOIN ptt_tag tag
      ON tag.ptt_org_id = tk.vsa_org_id
     AND tag.ptt_name = tag_name
     AND tag.ptt_archived_at IS NULL
    WHERE tk.vsa_tags IS NOT NULL
    ON CONFLICT (tpt_tag_id, tpt_subject_key, tpt_subject_id) DO NOTHING
    """
  end
end
