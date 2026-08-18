defmodule PawChart.Repo.Migrations.AddTagsScope do
  @moduledoc """
  Mounts the Tags universal scope (F4, T46) into PawChart's Postgres, and
  catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `demo/priv/repo/migrations/20260729120000_add_tags_scope.exs`
  with PawChart's own `ptt`/`tpt` abbrevs.
  """
  use Samen.Migration

  @resources [
    PawChart.Tags.Tag,
    PawChart.Tags.Tagging
  ]

  def up do
    create table(:ptt_tag, primary_key: false) do
      add(:ptt_name, :text, null: false)
      add(:ptt_color, :text, null: false, default: "gray")
      add(:ptt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ptt_org_id, :uuid, null: false)
      add(:ptt_inserted_at, :utc_datetime, null: false)
      add(:ptt_updated_at, :utc_datetime, null: false)
      add(:ptt_archived_at, :utc_datetime_usec)
    end

    create(index(:ptt_tag, [:ptt_org_id]))

    create(
      unique_index(:ptt_tag, [:ptt_org_id, :ptt_name],
        where: "ptt_archived_at IS NULL",
        name: :ptt_tag_org_name_live_index
      )
    )

    create table(:tpt_tagging, primary_key: false) do
      add(:tpt_subject_key, :text, null: false)
      add(:tpt_subject_id, :uuid, null: false)
      add(:tpt_tag_id, :uuid, null: false)
      add(:tpt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tpt_org_id, :uuid, null: false)
      add(:tpt_inserted_at, :utc_datetime, null: false)
      add(:tpt_updated_at, :utc_datetime, null: false)
    end

    create(index(:tpt_tagging, [:tpt_org_id]))
    create(index(:tpt_tagging, [:tpt_subject_key, :tpt_subject_id]))

    create(
      unique_index(:tpt_tagging, [:tpt_tag_id, :tpt_subject_key, :tpt_subject_id],
        name: :tpt_tagging_tag_subject_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:tpt_tagging))
    drop(table(:ptt_tag))
  end
end
