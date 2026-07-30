defmodule Samen.WebTest.Repo.Migrations.MountTagsScope do
  @moduledoc """
  Mounts the Tags universal scope (F4, T46) into the samen_web test host's
  Postgres, and catalogs the resources in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260729100000_mount_docs_scope.exs` with
  the samen_web test host's own `wtt`/`twt` abbrevs.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Tags.Tag,
    Samen.WebTest.Tags.Tagging
  ]

  def up do
    create table(:wtt_tag, primary_key: false) do
      add(:wtt_name, :text, null: false)
      add(:wtt_color, :text, null: false, default: "gray")
      add(:wtt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wtt_org_id, :uuid, null: false)
      add(:wtt_inserted_at, :utc_datetime, null: false)
      add(:wtt_updated_at, :utc_datetime, null: false)
      add(:wtt_archived_at, :utc_datetime_usec)
    end

    create(index(:wtt_tag, [:wtt_org_id]))

    create(
      unique_index(:wtt_tag, [:wtt_org_id, :wtt_name],
        where: "wtt_archived_at IS NULL",
        name: :wtt_tag_org_name_live_index
      )
    )

    create table(:twt_tagging, primary_key: false) do
      add(:twt_subject_key, :text, null: false)
      add(:twt_subject_id, :uuid, null: false)
      add(:twt_tag_id, :uuid, null: false)
      add(:twt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:twt_org_id, :uuid, null: false)
      add(:twt_inserted_at, :utc_datetime, null: false)
      add(:twt_updated_at, :utc_datetime, null: false)
    end

    create(index(:twt_tagging, [:twt_org_id]))
    create(index(:twt_tagging, [:twt_subject_key, :twt_subject_id]))

    create(
      unique_index(:twt_tagging, [:twt_tag_id, :twt_subject_key, :twt_subject_id],
        name: :twt_tagging_tag_subject_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:twt_tagging))
    drop(table(:wtt_tag))
  end
end
