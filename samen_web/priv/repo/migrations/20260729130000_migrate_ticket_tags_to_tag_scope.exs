defmodule Samen.WebTest.Repo.Migrations.MigrateTicketTagsToTagScope do
  @moduledoc """
  F4/T46 — migrates the samen_web test host's Support-scope `Ticket.tags`
  (`wsk_tags`) to the generic `Samen.WebTest.Tags` `Tag`/`Tagging` mechanism,
  then drops the column. Mirrors
  `demo/priv/repo/migrations/20260729130000_migrate_ticket_tags_to_tag_scope.exs`
  with the samen_web test host's own abbrevs (`wsk_ticket`,
  `wtt_tag`/`twt_tagging`) and object-ref key `"support.ticket"`
  (`Samen.WebTest.Support` carries no `Scope` suffix, unlike demo). Requires
  `20260729120000_mount_tags_scope.exs` to have run first. Contract-phase;
  `down/0` is a documented no-op (same posture as the demo migration).

  `Samen.Web.TicketTagsMigrationTest` drives this migration's REAL `up/0` (via
  `Ecto.Migrator`) to prove the zero-drop set-based copy — not a hand-copied
  duplicate of this SQL.
  """
  use Samen.Migration, phase: :contract

  def up do
    if column_exists?("wsk_ticket", "wsk_tags") do
      execute(seed_tags_sql())
      execute(seed_taggings_sql())
    end

    alter table(:wsk_ticket) do
      remove_if_exists(:wsk_tags)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'wsk_ticket' AND fld_column_name = 'wsk_tags'")
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
    SELECT DISTINCT wsk_org_id, unnest(wsk_tags), 'gray', now(), now()
    FROM wsk_ticket
    WHERE wsk_tags IS NOT NULL AND array_length(wsk_tags, 1) > 0
    ON CONFLICT (wtt_org_id, wtt_name) WHERE wtt_archived_at IS NULL DO NOTHING
    """
  end

  defp seed_taggings_sql do
    """
    INSERT INTO twt_tagging (
      twt_org_id, twt_tag_id, twt_subject_key, twt_subject_id, twt_inserted_at, twt_updated_at
    )
    SELECT
      tk.wsk_org_id,
      tag.wtt_id,
      'support.ticket',
      tk.wsk_id,
      now(),
      now()
    FROM wsk_ticket tk
    CROSS JOIN LATERAL unnest(tk.wsk_tags) AS tag_name
    JOIN wtt_tag tag
      ON tag.wtt_org_id = tk.wsk_org_id
     AND tag.wtt_name = tag_name
     AND tag.wtt_archived_at IS NULL
    WHERE tk.wsk_tags IS NOT NULL
    ON CONFLICT (twt_tag_id, twt_subject_key, twt_subject_id) DO NOTHING
    """
  end
end
