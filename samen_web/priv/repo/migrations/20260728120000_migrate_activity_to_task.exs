defmodule Samen.WebTest.Repo.Migrations.MigrateActivityToTask do
  @moduledoc """
  ADR-041 §5 (ruling M5) — the destructive CRM `Activity` → canonical Work-scope
  `Task` migration for the samen_web test host (`swa_activity` → `wwt_task`). See
  `Demo.Repo.Migrations.MigrateActivityToTask` for the full field-mapping /
  zero-data-drop / fresh-build-vs-deployment rationale (ADR-041 §5.1/§5.4/§5.5/§8.2).
  Contract phase, PITR-covered.
  """
  use Samen.Migration, phase: :contract

  def up do
    if table_exists?("swa_activity") do
      execute(copy_sql("swa", "wwt"))
    end

    execute("DROP TABLE IF EXISTS swa_activity")
    execute("DELETE FROM fld_field WHERE fld_table_name = 'swa_activity'")
    execute("DELETE FROM tam_table WHERE tam_table_name = 'swa_activity'")
  end

  def down do
    # Contract-phase / PITR-covered (ADR-041 §8.2) — no-op reverse (see the demo migration).
    :ok
  end

  defp table_exists?(name) do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
        [name]
      )

    rows != []
  end

  defp copy_sql(a, t) do
    """
    INSERT INTO #{t}_task (
      #{t}_id, #{t}_org_id, #{t}_kind, #{t}_title, #{t}_body, #{t}_status,
      #{t}_priority, #{t}_due_at, #{t}_completed_at, #{t}_subject_key, #{t}_subject_id,
      #{t}_custom, #{t}_owner_id, #{t}_parent_id, #{t}_project_id,
      #{t}_inserted_at, #{t}_updated_at
    )
    SELECT
      #{a}_id,
      #{a}_org_id,
      #{a}_type,
      #{a}_subject,
      #{a}_body,
      #{a}_status,
      20,
      #{a}_due_at,
      #{a}_completed_at,
      CASE
        WHEN #{a}_opportunity_id IS NOT NULL THEN 'crm.opportunity'
        WHEN #{a}_person_id IS NOT NULL THEN 'crm.person'
        WHEN #{a}_company_id IS NOT NULL THEN 'crm.company'
        ELSE NULL
      END,
      COALESCE(#{a}_opportunity_id, #{a}_person_id, #{a}_company_id),
      COALESCE(#{a}_custom, '{}'::jsonb) || jsonb_build_object(
        'crm_refs',
        jsonb_strip_nulls(jsonb_build_object(
          'company_id', #{a}_company_id,
          'person_id', #{a}_person_id,
          'opportunity_id', #{a}_opportunity_id
        ))
      ),
      NULL,
      NULL,
      NULL,
      #{a}_inserted_at,
      #{a}_updated_at
    FROM #{a}_activity
    ON CONFLICT (#{t}_id) DO NOTHING
    """
  end
end
