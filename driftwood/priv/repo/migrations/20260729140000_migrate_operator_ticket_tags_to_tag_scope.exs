defmodule Driftwood.Repo.Migrations.MigrateOperatorTicketTagsToTagScope do
  @moduledoc """
  F4/T46 — Driftwood mounts the Support scope TWICE (`Driftwood.Support`, the
  freight-vertical tenant-facing desk, AND `Driftwood.Operator`, ADR-010 §8.1's
  SECOND mount describing the SaaS's OWN book of business — "the tickets
  tenants file WITH the SaaS"). Both `Ticket` resources shared the SAME
  `Samen.Scopes.Support.Blueprint` and therefore BOTH carried the bespoke
  `tags` array (`dqk_tags` on the operator mount, `fsk_tags` on the tenant
  mount — migrated separately by
  `20260729130000_migrate_ticket_tags_to_tag_scope.exs`).

  Migrates `Driftwood.Operator.Ticket.tags` (`dqk_tags`) to the SAME
  `Driftwood.Tags` scope (ONE Tags scope per host, shared across both Support
  mounts — a Tag/Tagging is a host-wide concept, not namespace-scoped), then
  drops the column. Anchored `subject_key = "operator.ticket"`
  (`Samen.Web.ObjectRef.Catalog.key_for(Driftwood.Operator.Ticket)` —
  DISTINCT from the tenant mount's `"support.ticket"` key, correctly modeling
  these as different catalogued objects). Requires
  `20260729120000_add_tags_scope.exs` to have run first. Same contract-phase,
  zero-drop, set-based-copy shape as the tenant-mount migration — see its
  moduledoc for the full rationale (`down/0` is likewise a documented no-op).
  """
  use Samen.Migration, phase: :contract

  def up do
    if column_exists?("dqk_ticket", "dqk_tags") do
      execute(seed_tags_sql())
      execute(seed_taggings_sql())
    end

    alter table(:dqk_ticket) do
      remove_if_exists(:dqk_tags)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'dqk_ticket' AND fld_column_name = 'dqk_tags'")
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
    SELECT DISTINCT dqk_org_id, unnest(dqk_tags), 'gray', now(), now()
    FROM dqk_ticket
    WHERE dqk_tags IS NOT NULL AND array_length(dqk_tags, 1) > 0
    ON CONFLICT (ftt_org_id, ftt_name) WHERE ftt_archived_at IS NULL DO NOTHING
    """
  end

  defp seed_taggings_sql do
    """
    INSERT INTO tft_tagging (
      tft_org_id, tft_tag_id, tft_subject_key, tft_subject_id, tft_inserted_at, tft_updated_at
    )
    SELECT
      tk.dqk_org_id,
      tag.ftt_id,
      'operator.ticket',
      tk.dqk_id,
      now(),
      now()
    FROM dqk_ticket tk
    CROSS JOIN LATERAL unnest(tk.dqk_tags) AS tag_name
    JOIN ftt_tag tag
      ON tag.ftt_org_id = tk.dqk_org_id
     AND tag.ftt_name = tag_name
     AND tag.ftt_archived_at IS NULL
    WHERE tk.dqk_tags IS NOT NULL
    ON CONFLICT (tft_tag_id, tft_subject_key, tft_subject_id) DO NOTHING
    """
  end
end
