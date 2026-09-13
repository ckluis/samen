defmodule SamenCore.TestRepo.Migrations.AiAgentRunContextBudget do
  @moduledoc """
  ADR-048 §6 (`T218`, batch C2) — one additive column on the already-catalogued
  `ai_agent_run` table:

    * `ai_agent_run.arn_context_cutoff_tokens` — the per-run CONTEXT WATERMARK (not a
      spend ceiling): the assembled-context size at which Level 1 folds the oldest
      eligible span, and above which — with nothing eligible to fold — the run takes
      ADR-048 §6's Level 3 terminal `:context_exhausted`. Persisted on the row for the
      same reason the five ADR-047 §9#3 spend ceilings are (`arn_max_input_tokens` and
      siblings): the durable `Samen.AI.Agent.TurnWorker` resumes from the row, so a
      per-run override has to survive the worker boundary. Defaulted to 42_000 — 70% of
      the default `max_input_tokens`, exactly as §6 states it — so existing rows carry
      the documented posture rather than a null.

  The Level 3 terminal STATE needs no schema change: `arn_state` is a plain text column
  (the `apv_state` precedent recorded on the attribute itself), so widening its `one_of`
  is a resource-level change only.

  Additive, defaulted column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping (the `arn_hooks` precedent), reversible via `change/0`. No
  abbrev-registry allocation: reuses the existing `arn` owner (no new resource).
  """
  use Samen.Migration

  def change do
    alter table(:ai_agent_run) do
      add(:arn_context_cutoff_tokens, :bigint, null: false, default: 42_000)
    end

    catalog_sync([Samen.AI.Agent.Run], only: [:context_cutoff_tokens])
  end
end
