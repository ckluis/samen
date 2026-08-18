defmodule Driftwood.Repo.Migrations.AiAgentRun do
  @moduledoc """
  `ai_agent_run` — the durable agent-run cursor (ADR-047 §4.1/§6, batch A1), mounted in
  driftwood via `Samen.AI.Domain` (the `ai_prompt` T155 precedent). Allocator-owned
  abbrev `arn` (samen_core-owned resource, host-invariant table name + abbrev — no fresh
  abbrev). Replicates `samen_core/priv/test_repo/migrations/20260814100000_ai_agent_run.exs`
  verbatim. TOKEN-ONLY at rest (no prompt/completion text column; the vault-routed
  transcript is batch A2). `catalog_sync/1` writes the `tam_table`/`fld_field` rows in the
  SAME transaction as the DDL so `mix samen.verify.catalog_parity` + the schema.dict drift
  gate stay green.
  """
  use Samen.Migration

  @resources [Samen.AI.Agent.Run]

  def up do
    create table(:ai_agent_run, primary_key: false) do
      add(:arn_agent, :text, null: false)
      # AshStateMachine state stored as text (the apv_state precedent).
      add(:arn_state, :text, null: false, default: "queued")
      add(:arn_current_turn, :bigint, null: false, default: 0)
      add(:arn_next_turn_at, :utc_datetime_usec)
      add(:arn_started_at, :utc_datetime_usec)
      add(:arn_cancel_requested_at, :utc_datetime_usec)
      add(:arn_error_kind, :text)
      add(:arn_max_turns, :bigint, null: false)
      add(:arn_max_tool_calls, :bigint, null: false)
      add(:arn_max_input_tokens, :bigint, null: false)
      add(:arn_max_output_tokens, :bigint, null: false)
      add(:arn_deadline_seconds, :bigint, null: false)
      add(:arn_tool_calls_used, :bigint, null: false, default: 0)
      add(:arn_input_tokens_used, :bigint, null: false, default: 0)
      add(:arn_output_tokens_used, :bigint, null: false, default: 0)
      add(:arn_origin, :text)
      add(:arn_depth, :bigint, null: false, default: 0)
      add(:arn_chain, {:array, :text}, null: false, default: [])
      add(:arn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:arn_org_id, :uuid, null: false)
      add(:arn_inserted_at, :utc_datetime, null: false)
      add(:arn_updated_at, :utc_datetime, null: false)
    end

    create(index(:ai_agent_run, [:arn_org_id], name: "ai_agent_run_org_idx"))

    # The A2 due-scan's selector shape (`next_turn_at <= now`, non-terminal) — indexed now
    # so the watchdog lands on a ready table.
    create(index(:ai_agent_run, [:arn_next_turn_at], name: "ai_agent_run_next_turn_at_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:ai_agent_run, [:arn_next_turn_at], name: "ai_agent_run_next_turn_at_idx"))
    drop(index(:ai_agent_run, [:arn_org_id], name: "ai_agent_run_org_idx"))
    drop(table(:ai_agent_run))
  end
end
