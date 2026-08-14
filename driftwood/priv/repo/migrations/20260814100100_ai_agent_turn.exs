defmodule Driftwood.Repo.Migrations.AiAgentTurn do
  @moduledoc """
  `ai_agent_turn` — the bounded per-turn agent log row (ADR-047 §6, batch A1), mounted in
  driftwood via `Samen.AI.Domain` (the `ai_prompt` T155 precedent). Allocator-owned
  abbrev `atn` (samen_core-owned resource, host-invariant table name + abbrev). Replicates
  `samen_core/priv/test_repo/migrations/20260814100100_ai_agent_turn.exs` verbatim.
  TOKEN-ONLY by allowlist (never prompt/arg/result text); the `{atn_run_id,
  atn_turn_index}` unique index is the A2 crash-replay idempotency key. `catalog_sync/1`
  keeps `mix samen.verify.catalog_parity` green in the same transaction as the DDL.
  """
  use Samen.Migration

  @resources [Samen.AI.Agent.Turn]

  def up do
    create table(:ai_agent_turn, primary_key: false) do
      add(:atn_run_id, :uuid, null: false)
      add(:atn_turn_index, :bigint, null: false)
      add(:atn_status, :text, null: false)
      add(:atn_tool_kind, :text)
      add(:atn_arg_keys, {:array, :text}, null: false, default: [])
      add(:atn_error_kind, :text)
      add(:atn_input_tokens, :bigint, null: false, default: 0)
      add(:atn_output_tokens, :bigint, null: false, default: 0)
      add(:atn_duration_ms, :bigint, null: false, default: 0)
      add(:atn_provider, :text)
      add(:atn_simulated, :boolean, null: false, default: false)
      add(:atn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:atn_org_id, :uuid, null: false)
      add(:atn_inserted_at, :utc_datetime, null: false)
      add(:atn_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ai_agent_turn, [:atn_run_id, :atn_turn_index],
        name: "ai_agent_turn_run_turn_index"
      )
    )

    create(index(:ai_agent_turn, [:atn_org_id], name: "ai_agent_turn_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:ai_agent_turn, [:atn_org_id], name: "ai_agent_turn_org_idx"))

    drop_if_exists(
      unique_index(:ai_agent_turn, [:atn_run_id, :atn_turn_index],
        name: "ai_agent_turn_run_turn_index"
      )
    )

    drop(table(:ai_agent_turn))
  end
end
