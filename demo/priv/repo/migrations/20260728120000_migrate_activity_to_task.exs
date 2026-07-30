defmodule Demo.Repo.Migrations.MigrateActivityToTask do
  @moduledoc """
  ADR-041 §5 (operator ruling M5) — the DESTRUCTIVE CRM `Activity` → canonical
  Work-scope `Task` migration for the demo host (`act_activity` → `wtk_task`).

  Contract phase (net-destructive, PITR-covered, ADR-041 §8.2). The destination
  `wtk_task` already exists (T43's `AddWorkScope`, which orders before this).

  ## What it does (ADR-041 §5.1 — ZERO data drop)

    * Copies every `act_activity` row into `wtk_task`, field-for-field: type→kind,
      subject→title, body/status/due_at/completed_at/custom/id/org_id/timestamps
      VERBATIM. Priority is the added `:normal` rank (20). owner/parent/project are
      NULL (no Activity source).
    * The ≤3 CRM FKs collapse to the PRIMARY subject anchor `(subject_key, subject_id)`
      by precedence `opportunity ▸ person ▸ company`, AND the FULL non-null ref set is
      preserved in `custom.crm_refs` — so nothing is dropped and the CRM timeline's
      OR-match (`Samen.Web.CRM.Reads`) still surfaces every entry in BOTH timelines.
    * `INSERT … ON CONFLICT (wtk_id) DO NOTHING` — id-preserving + IDEMPOTENT.
    * Then DROPs `act_activity` and deletes its catalog rows.

  ## Fresh-build vs real deployment

  On a clean drop/create (the `ci.sh` gate) the historical CRM-scope migration no
  longer creates `act_activity` (its resource is gone), so the copy is a guarded
  no-op and the DROP/DELETE are IF-EXISTS no-ops — the end state is identical: no
  `act_activity`, canonical Task in place. On a real deployment `act_activity`
  carries rows and this migration moves them, then drops the table. Atomic: the
  whole migration is one transaction (ADR-041 §5.5) — a mid-run failure rolls back
  whole (no half-migrated state); safe under partial failure across hosts (each
  host's migration is its own transaction).
  """
  use Samen.Migration, phase: :contract

  def up do
    if table_exists?("act_activity") do
      execute(copy_sql("act", "wtk"))
    end

    execute("DROP TABLE IF EXISTS act_activity")
    execute("DELETE FROM fld_field WHERE fld_table_name = 'act_activity'")
    execute("DELETE FROM tam_table WHERE tam_table_name = 'act_activity'")
  end

  def down do
    # Contract-phase / PITR-covered (ADR-041 §8.2). Activity was destructively removed;
    # a fresh build never created it and nothing downstream references it, so the reverse
    # is a no-op. The operator reversal recipe (recreate the table + reverse-map from the
    # migrated Tasks) is documented in ADR-041 §8.2; PITR is the production control.
    :ok
  end

  # Does a physical table exist in the public schema (real deployment) or not (fresh
  # clean drop/create, where the CRM-scope migration no longer creates it)?
  defp table_exists?(name) do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
        [name]
      )

    rows != []
  end

  # The set-based Activity→Task copy (ADR-041 §5.1). `a`/`t` are the source/destination
  # abbrev prefixes (developer-controlled compile-time identifiers, not user input).
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
