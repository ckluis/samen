defmodule SamenCore.TestRepo.Migrations.AiPrompt do
  @moduledoc """
  `ai_prompt` — the D3 versioned managed-prompt-template resource (ADR-043 §7.5, T68).
  Allocator-owned abbrev `aip` (`samen.abbrev.reserve --host samen_core --owner
  Samen.AI.Prompt --abbrev aip`). The `{aip_org_id, aip_name, aip_version}` unique index
  is the DB-level belt to `Samen.AI.PromptChange`'s next-version computation: history can
  never be silently overwritten, even under a same-{org,name} race. `catalog_sync/1` writes
  the `tam_table`/`fld_field` rows in the SAME transaction as the DDL (the `tnt_record`
  precedent, `Samen.Migration`) so `mix samen.verify.catalog_parity` stays green.
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
      unique_index(:ai_prompt, [:aip_org_id, :aip_name, :aip_version],
        name: "ai_prompt_name_version_index"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop_if_exists(
      unique_index(:ai_prompt, [:aip_org_id, :aip_name, :aip_version],
        name: "ai_prompt_name_version_index"
      )
    )

    drop(table(:ai_prompt))
  end
end
