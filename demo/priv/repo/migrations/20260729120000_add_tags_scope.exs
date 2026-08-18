defmodule Demo.Repo.Migrations.AddTagsScope do
  @moduledoc """
  Mounts the Tags universal scope (F4, T46) into the demo host's one Postgres,
  and catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260729100000_add_docs_scope.exs`.

    * `dtt_tag`     — Tag: name (unique per org among live rows — partial
      unique index), color (bounded palette). Archivable (ADR-040 §5.9).
    * `tdt_tagging` — Tagging: the polymorphic join (`tag_id` + the generic
      `(subject_key, subject_id)` object-ref anchor). NOT archivable. Unique
      per `(tag_id, subject_key, subject_id)`.
  """
  use Samen.Migration

  @resources [
    Demo.Tags.Tag,
    Demo.Tags.Tagging
  ]

  def up do
    create table(:dtt_tag, primary_key: false) do
      add(:dtt_name, :text, null: false)
      add(:dtt_color, :text, null: false, default: "gray")
      add(:dtt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dtt_org_id, :uuid, null: false)
      add(:dtt_inserted_at, :utc_datetime, null: false)
      add(:dtt_updated_at, :utc_datetime, null: false)
      add(:dtt_archived_at, :utc_datetime_usec)
    end

    create(index(:dtt_tag, [:dtt_org_id]))

    create(
      unique_index(:dtt_tag, [:dtt_org_id, :dtt_name],
        where: "dtt_archived_at IS NULL",
        name: :dtt_tag_org_name_live_index
      )
    )

    create table(:tdt_tagging, primary_key: false) do
      add(:tdt_subject_key, :text, null: false)
      add(:tdt_subject_id, :uuid, null: false)
      add(:tdt_tag_id, :uuid, null: false)
      add(:tdt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tdt_org_id, :uuid, null: false)
      add(:tdt_inserted_at, :utc_datetime, null: false)
      add(:tdt_updated_at, :utc_datetime, null: false)
    end

    create(index(:tdt_tagging, [:tdt_org_id]))
    create(index(:tdt_tagging, [:tdt_subject_key, :tdt_subject_id]))

    create(
      unique_index(:tdt_tagging, [:tdt_tag_id, :tdt_subject_key, :tdt_subject_id],
        name: :tdt_tagging_tag_subject_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:tdt_tagging))
    drop(table(:dtt_tag))
  end
end
