defmodule Driftwood.Repo.Migrations.AiAgentRunHooks do
  @moduledoc """
  UXD-08/UXD-09 (`/Users/clank/Desktop/projects/samen-oss-burndown/_orch/verify/T21-verdict.json`)
  — the driftwood mount of one additive column on the already-catalogued `ai_agent_run`
  table (the samen_core-owned `Samen.AI.Agent.Run` resource rides this host's repo).
  Replicates `samen_core/priv/test_repo/migrations/20260827100000_ai_agent_run_hooks.exs`
  verbatim:

    * `ai_agent_run.arn_hooks` — the per-run `Samen.AI.Agent.Hook` module chain a caller
      passed to `start/4`, persisted as module-name strings so the durable TurnWorker can
      re-resolve it at execution time. Oban job args stay token-only (ADR-037 §5.9 sink
      rule), so the row is the durability path instead.

  Additive column on an already-catalogued resource → `catalog_sync/2` `only:` scoping,
  reversible via `change/0`. No abbrev-registry allocation (existing `arn` owner).
  """
  use Samen.Migration

  def change do
    alter table(:ai_agent_run) do
      add(:arn_hooks, {:array, :text}, null: false, default: [])
    end

    catalog_sync([Samen.AI.Agent.Run], only: [:hooks])
  end
end
