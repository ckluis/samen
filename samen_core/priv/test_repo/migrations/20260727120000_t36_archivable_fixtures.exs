defmodule SamenCore.TestRepo.Migrations.T36ArchivableFixtures do
  @moduledoc """
  Tables for the E6 soft-delete pilots (ADR-040 §5, T36): `arv_widget` (plain) and
  `avf_person` (vaulted, folds Core.Person). Both carry the `<abbrev>_archived_at`
  timestamp (NULL = live, spec-question c6).

  `arv_widget` demonstrates the **partial unique index convention** (§5.3): the
  uniqueness lives in a migration-level `unique_index ... WHERE arv_archived_at IS
  NULL`, so an archived row frees its `(org_id, code)` slot and a restore that would
  collide with a live claimant fails honest with `{:error, :restore_conflict}`.
  """
  use Ecto.Migration

  def up do
    create table(:arv_widget, primary_key: false) do
      add(:arv_name, :text, null: false)
      add(:arv_code, :text, null: false)
      add(:arv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:arv_org_id, :uuid, null: false)
      add(:arv_inserted_at, :utc_datetime, null: false)
      add(:arv_updated_at, :utc_datetime, null: false)
      add(:arv_archived_at, :utc_datetime_usec)
    end

    # §5.3 partial unique index: live rows only. An archived row frees its slot.
    create(
      unique_index(:arv_widget, [:arv_org_id, :arv_code],
        where: "arv_archived_at IS NULL",
        name: "arv_widget_org_code_live_uidx"
      )
    )

    create table(:avf_person, primary_key: false) do
      add(:avf_job_title, :text)
      # Vault-routed composite columns hold vt_* tokens (:text), never plaintext.
      add(:avf_full_name, :text)
      add(:avf_emails, :text)
      add(:avf_phones, :text)
      add(:avf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:avf_org_id, :uuid, null: false)
      add(:avf_inserted_at, :utc_datetime, null: false)
      add(:avf_updated_at, :utc_datetime, null: false)
      add(:avf_archived_at, :utc_datetime_usec)
    end
  end

  def down do
    drop(table(:avf_person))
    drop(index(:arv_widget, [:arv_org_id, :arv_code], name: "arv_widget_org_code_live_uidx"))
    drop(table(:arv_widget))
  end
end
