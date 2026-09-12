defmodule Driftwood.Repo.Migrations.AiAgentFoldSource do
  @moduledoc """
  `ai_agent_fold_source` — ADR-048 §7.3's PSEUDONYM-KEYED PROVENANCE INDEX (batch C4).
  Allocator-owned abbrev `afs` (`samen.abbrev.reserve --host samen_core --owner
  Samen.AI.Agent.FoldSource --abbrev afs`). One row per `{run, fold, source subject}`
  citation, living OUTSIDE the sealed transcript body so the §7.3 withdrawal walk never
  decrypts a transcript to find its own targets.

  `afs_subject_ref` is the DEK-KEYED PSEUDONYM `HMAC(psk_S, subject_id)`, hex-encoded —
  never a raw subject id. That is what makes the index self-erasing: destroying the
  subject's DEK makes the ref permanently uncomputable, so §7.3 keeps the rows and kills
  the key instead of deleting anything. `afs_withdrawn_at` is step 3's neutralizing stamp.
  `catalog_sync/1` keeps `mix samen.verify.catalog_parity` green in the same transaction
  as the DDL.
  """
  use Samen.Migration

  @resources [Samen.AI.Agent.FoldSource]

  def up do
    create table(:ai_agent_fold_source, primary_key: false) do
      add(:afs_run_id, :uuid, null: false)
      add(:afs_fold_n, :bigint, null: false)
      add(:afs_subject_ref, :text, null: false)
      add(:afs_withdrawn_at, :utc_datetime_usec)
      add(:afs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:afs_org_id, :uuid, null: false)
      add(:afs_inserted_at, :utc_datetime, null: false)
      add(:afs_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ai_agent_fold_source, [:afs_run_id, :afs_fold_n, :afs_subject_ref],
        name: "ai_agent_fold_source_run_fold_ref_index"
      )
    )

    # THE walk's own match predicate: resolve every citing fold from a pseudonym alone.
    create(
      index(:ai_agent_fold_source, [:afs_subject_ref], name: "ai_agent_fold_source_ref_idx")
    )

    create(index(:ai_agent_fold_source, [:afs_org_id], name: "ai_agent_fold_source_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:ai_agent_fold_source, [:afs_org_id], name: "ai_agent_fold_source_org_idx"))
    drop(index(:ai_agent_fold_source, [:afs_subject_ref], name: "ai_agent_fold_source_ref_idx"))

    drop_if_exists(
      unique_index(:ai_agent_fold_source, [:afs_run_id, :afs_fold_n, :afs_subject_ref],
        name: "ai_agent_fold_source_run_fold_ref_index"
      )
    )

    drop(table(:ai_agent_fold_source))
  end
end
