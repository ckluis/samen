defmodule Samen.WebTest.Repo.Migrations.MigrateOperatorTicketTagsToTagScope do
  @moduledoc """
  F4/T46 — the samen_web test host mounts the Support scope TWICE
  (`Samen.WebTest.Support`, the tenant-facing desk, AND `Samen.WebTest.Operator`,
  ADR-010 §8.2's SECOND mount). Both `Ticket` resources shared the SAME
  `Samen.Scopes.Support.Blueprint` and therefore BOTH carried the bespoke
  `tags` array (`wqk_tags` here, `wsk_tags` on the tenant mount — migrated
  separately by `20260729130000_migrate_ticket_tags_to_tag_scope.exs`).

  Migrates `Samen.WebTest.Operator.Ticket.tags` (`wqk_tags`) to the SAME
  `Samen.WebTest.Tags` scope, then drops the column. Anchored `subject_key =
  "operator.ticket"` (DISTINCT from the tenant mount's `"support.ticket"`
  key). Requires `20260729120000_mount_tags_scope.exs` to have run first.
  Same contract-phase, zero-drop shape as the tenant-mount migration.
  """
  use Samen.Migration, phase: :contract

  def up do
    if column_exists?("wqk_ticket", "wqk_tags") do
      execute(seed_tags_sql())
      execute(seed_taggings_sql())
    end

    alter table(:wqk_ticket) do
      remove_if_exists(:wqk_tags)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'wqk_ticket' AND fld_column_name = 'wqk_tags'")
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
    INSERT INTO wtt_tag (wtt_org_id, wtt_name, wtt_color, wtt_inserted_at, wtt_updated_at)
    SELECT DISTINCT wqk_org_id, unnest(wqk_tags), 'gray', now(), now()
    FROM wqk_ticket
    WHERE wqk_tags IS NOT NULL AND array_length(wqk_tags, 1) > 0
    ON CONFLICT (wtt_org_id, wtt_name) WHERE wtt_archived_at IS NULL DO NOTHING
    """
  end

  defp seed_taggings_sql do
    """
    INSERT INTO twt_tagging (
      twt_org_id, twt_tag_id, twt_subject_key, twt_subject_id, twt_inserted_at, twt_updated_at
    )
    SELECT
      tk.wqk_org_id,
      tag.wtt_id,
      'operator.ticket',
      tk.wqk_id,
      now(),
      now()
    FROM wqk_ticket tk
    CROSS JOIN LATERAL unnest(tk.wqk_tags) AS tag_name
    JOIN wtt_tag tag
      ON tag.wtt_org_id = tk.wqk_org_id
     AND tag.wtt_name = tag_name
     AND tag.wtt_archived_at IS NULL
    WHERE tk.wqk_tags IS NOT NULL
    ON CONFLICT (twt_tag_id, twt_subject_key, twt_subject_id) DO NOTHING
    """
  end
end
