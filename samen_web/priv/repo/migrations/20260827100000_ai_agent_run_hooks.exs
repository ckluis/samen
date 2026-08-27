defmodule Samen.WebTest.Repo.Migrations.AiAgentRunHooks do
  @moduledoc """
  UXD-08/UXD-09 (`/Users/clank/Desktop/projects/samen-oss-burndown/_orch/verify/T21-verdict.json`)
  — one additive column on the already-catalogued `ai_agent_run` table:

    * `ai_agent_run.arn_hooks` — the per-run `Samen.AI.Agent.Hook` module chain a caller
      passed to `start/4`, persisted as module-name strings so the durable
      `Samen.AI.Agent.TurnWorker` can re-resolve it at execution time
      (`Samen.AI.Agent.execute_batch/1`'s `worker_opts/1`). Oban job args stay
      token-only (`run_id` only — the ADR-037 §5.9 sink rule), so the row is the
      durability path instead — the same shape `arn_owner_id`/`arn_agent_module`
      already use for other start-time facts the worker resumes from.
      Host-configured hooks (`config :samen_core, Samen.AI.Agent, hooks: [...]`) are
      unaffected: `Samen.AI.Agent.Hooks.resolve/1` still puts them first.

  Additive, defaulted column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, reversible via `change/0`. No abbrev-registry allocation: reuses the
  existing `arn` owner (no new resource).
  """
  use Samen.Migration

  def change do
    alter table(:ai_agent_run) do
      add(:arn_hooks, {:array, :text}, null: false, default: [])
    end

    catalog_sync([Samen.AI.Agent.Run], only: [:hooks])
  end
end
