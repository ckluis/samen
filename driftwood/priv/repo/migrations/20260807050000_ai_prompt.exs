defmodule Driftwood.Repo.Migrations.AiPrompt do
  @moduledoc """
  `ai_prompt` — the D3 versioned managed-prompt resource (ADR-043 §7.5, T68), mounted in
  driftwood via `Samen.AI.Domain` (T155). Allocator-owned abbrev `aip` (samen_core-owned
  resource, host-invariant table name + abbrev — no fresh abbrev). Replicates
  `samen_core/priv/test_repo/migrations/20260805140000_ai_prompt.exs` verbatim; the AI-plane
  domain brings BOTH `ai_prompt` and `ai_support_reply_draft`, so both tables land together.
  `catalog_sync/1` writes the `tam_table`/`fld_field` rows in the SAME transaction as the DDL
  so `mix samen.verify.catalog_parity` + the schema.dict drift gate stay green.
  """
  use Samen.Migration

  @resources [Samen.AI.Prompt]

  def up do
    create table(:ai_prompt, primary_key: false) do
      add(:aip_name, :text, null: false)
      add(:aip_version, :bigint, null: false)
      add(:aip_body, :text, null: false)
      add(:aip_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aip_org_id, :uuid, null: false)
      add(:aip_inserted_at, :utc_datetime, null: false)
      add(:aip_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ai_prompt, [:aip_org_id, :aip_name, :aip_version], name: "ai_prompt_name_version_index")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(unique_index(:ai_prompt, [:aip_org_id, :aip_name, :aip_version], name: "ai_prompt_name_version_index"))
    drop(table(:ai_prompt))
  end
end
