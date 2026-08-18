defmodule SamenCore.TestRepo.Migrations.TagsScopeFixture do
  @moduledoc """
  Tables for the Tags scope (F4, T46): `stt_tag` + `tst_tagging`, mounted in
  `samen_core` tests via `test/support/tags_fixture.ex`.

  `stt_tag` — org-scoped, colored label. Archivable (`stt_archived_at`).
  Partial unique index `(org_id, name) WHERE archived_at IS NULL` (ADR-040
  §5.3 — an archived Tag frees its name for reuse).

  `tst_tagging` — the polymorphic join. NOT archivable (a pure join row).
  Unique per `(tag_id, subject_key, subject_id)` — a Tag attaches to the same
  object at most once.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.TagsFixture.Tag,
    SamenCore.Support.TagsFixture.Tagging
  ]

  def up do
    create table(:stt_tag, primary_key: false) do
      add(:stt_name, :text, null: false)
      add(:stt_color, :text, null: false, default: "gray")
      add(:stt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:stt_org_id, :uuid, null: false)
      add(:stt_inserted_at, :utc_datetime, null: false)
      add(:stt_updated_at, :utc_datetime, null: false)
      add(:stt_archived_at, :utc_datetime_usec)
    end

    create(index(:stt_tag, [:stt_org_id]))

    create(
      unique_index(:stt_tag, [:stt_org_id, :stt_name],
        where: "stt_archived_at IS NULL",
        name: :stt_tag_org_name_live_index
      )
    )

    create table(:tst_tagging, primary_key: false) do
      add(:tst_subject_key, :text, null: false)
      add(:tst_subject_id, :uuid, null: false)
      add(:tst_tag_id, :uuid, null: false)
      add(:tst_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tst_org_id, :uuid, null: false)
      add(:tst_inserted_at, :utc_datetime, null: false)
      add(:tst_updated_at, :utc_datetime, null: false)
    end

    create(index(:tst_tagging, [:tst_org_id]))
    create(index(:tst_tagging, [:tst_subject_key, :tst_subject_id]))

    create(
      unique_index(:tst_tagging, [:tst_tag_id, :tst_subject_key, :tst_subject_id],
        name: :tst_tagging_tag_subject_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:tst_tagging))
    drop(table(:stt_tag))
  end
end
