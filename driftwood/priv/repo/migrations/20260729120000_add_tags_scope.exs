defmodule Driftwood.Repo.Migrations.AddTagsScope do
  @moduledoc """
  Mounts the Tags universal scope (F4, T46) into Driftwood's Postgres, and
  catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `demo/priv/repo/migrations/20260729120000_add_tags_scope.exs`
  with Driftwood's own `ftt`/`tft` abbrevs (the `dtt`/`tdt` proposal collided
  with demo's — see `Driftwood.Tags` moduledoc).
  """
  use Samen.Migration

  @resources [
    Driftwood.Tags.Tag,
    Driftwood.Tags.Tagging
  ]

  def up do
    create table(:ftt_tag, primary_key: false) do
      add(:ftt_name, :text, null: false)
      add(:ftt_color, :text, null: false, default: "gray")
      add(:ftt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ftt_org_id, :uuid, null: false)
      add(:ftt_inserted_at, :utc_datetime, null: false)
      add(:ftt_updated_at, :utc_datetime, null: false)
      add(:ftt_archived_at, :utc_datetime_usec)
    end

    create(index(:ftt_tag, [:ftt_org_id]))

    create(
      unique_index(:ftt_tag, [:ftt_org_id, :ftt_name],
        where: "ftt_archived_at IS NULL",
        name: :ftt_tag_org_name_live_index
      )
    )

    create table(:tft_tagging, primary_key: false) do
      add(:tft_subject_key, :text, null: false)
      add(:tft_subject_id, :uuid, null: false)
      add(:tft_tag_id, :uuid, null: false)
      add(:tft_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tft_org_id, :uuid, null: false)
      add(:tft_inserted_at, :utc_datetime, null: false)
      add(:tft_updated_at, :utc_datetime, null: false)
    end

    create(index(:tft_tagging, [:tft_org_id]))
    create(index(:tft_tagging, [:tft_subject_key, :tft_subject_id]))

    create(
      unique_index(:tft_tagging, [:tft_tag_id, :tft_subject_key, :tft_subject_id],
        name: :tft_tagging_tag_subject_index
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:tft_tagging))
    drop(table(:ftt_tag))
  end
end
