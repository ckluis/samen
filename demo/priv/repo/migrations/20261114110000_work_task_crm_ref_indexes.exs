defmodule Demo.Repo.Migrations.WorkTaskCrmRefIndexes do
  @moduledoc """
  ARCH-4 — the CRM detail timeline (`Samen.Web.CRM.Reads.activities_for_person/3`, `…_for_company/3`)
  filters the Work `Task` by `(subject_key, subject_id)` OR `get_path(custom, ["crm_refs", "<kind>_id"])`.
  AshPostgres renders the second arm as `jsonb_extract_path_text(custom, 'crm_refs', '<kind>_id') = $n`,
  which no btree on the column can serve, so the OR forced a sequential scan of the org's tasks. These two
  partial expression indexes match that exact expression, so Postgres can BitmapOr them with the existing
  `(subject_key, subject_id)` index (`Samen.Web.CrmRefsIndexPlanTest` proves the plan).

  Partial (`WHERE <expr> IS NOT NULL`): `crm_refs` is a migration-only preservation bag, so the index holds
  only the rows that carry the key. Built `CONCURRENTLY` (no write lock on a populated table). Idempotent.
  """
  use Samen.Migration, phase: :expand
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_jsonb_path_index(Demo.WorkScope.Task, :custom, ["crm_refs", "person_id"], concurrently: true)
    create_jsonb_path_index(Demo.WorkScope.Task, :custom, ["crm_refs", "company_id"], concurrently: true)
  end

  def down do
    drop_jsonb_path_index(Demo.WorkScope.Task, :custom, ["crm_refs", "company_id"], concurrently: true)
    drop_jsonb_path_index(Demo.WorkScope.Task, :custom, ["crm_refs", "person_id"], concurrently: true)
  end
end
