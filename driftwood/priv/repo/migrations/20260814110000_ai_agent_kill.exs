defmodule Driftwood.Repo.Migrations.AiAgentKill do
  @moduledoc """
  `ai_agent_kill` — the DURABLE per-{org, agent-definition} kill switch (ADR-047 §6,
  batch A5). Allocator-owned abbrev `akl` (`samen.abbrev.reserve --host samen_core
  --owner Samen.AI.Agent.Kill --abbrev akl`). Closes the A2/A3 cross-tenant blast
  radius: a rate trip now writes ONE row for the offending {org, definition} instead of
  throwing the host-level switch for every tenant. TOKEN-ONLY: org id, the authored
  definition name, a bounded reason enum, bounded actor ids, two timestamps — no PII
  column exists here to reach. The `{akl_org_id, akl_agent}` unique index is the upsert
  identity that makes a repeated trip idempotent. `catalog_sync/1` keeps
  `mix samen.verify.catalog_parity` green in the same transaction as the DDL.
  """
  use Samen.Migration

  @resources [Samen.AI.Agent.Kill]

  def up do
    create table(:ai_agent_kill, primary_key: false) do
      add(:akl_agent, :text, null: false)
      add(:akl_reason, :text, null: false)
      add(:akl_killed_at, :utc_datetime_usec, null: false)
      add(:akl_killed_by, :text)
      add(:akl_rearmed_at, :utc_datetime_usec)
      add(:akl_rearmed_by, :text)
      add(:akl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:akl_org_id, :uuid, null: false)
      add(:akl_inserted_at, :utc_datetime, null: false)
      add(:akl_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ai_agent_kill, [:akl_org_id, :akl_agent], name: "ai_agent_kill_org_agent_index")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop_if_exists(
      unique_index(:ai_agent_kill, [:akl_org_id, :akl_agent], name: "ai_agent_kill_org_agent_index")
    )

    drop(table(:ai_agent_kill))
  end
end
