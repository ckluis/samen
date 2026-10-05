defmodule Driftwood.Repo.Migrations.AiAgentCachedInputBucket do
  @moduledoc """
  Issue #74 — input SERVED from the provider's prompt cache is its own token bucket, on the
  already-catalogued agent tables:

    * `ai_agent_run.arn_cached_input_tokens_used` — the run's cached-input counter;
    * `ai_agent_run.arn_max_cached_input_tokens` — its own ceiling, read by
      `Samen.AI.Agent.over_budget/2` (`:max_cached_input_tokens`). Defaulted to 600_000
      (10x the default uncached `max_input_tokens`: a cache read costs about a tenth of fresh
      input, so it is the same spend headroom) so existing rows carry the documented posture;
    * `ai_agent_turn.atn_cached_input_tokens` — the turn ledger's copy.

  Additive, defaulted columns → `catalog_sync/2`'s `only:` scoping (the
  `arn_context_cutoff_tokens` precedent), reversible via `change/0`. No abbrev-registry
  allocation: the existing `arn` / `atn` owners.
  """
  use Samen.Migration

  def change do
    alter table(:ai_agent_run) do
      add(:arn_cached_input_tokens_used, :bigint, null: false, default: 0)
      add(:arn_max_cached_input_tokens, :bigint, null: false, default: 600_000)
    end

    alter table(:ai_agent_turn) do
      add(:atn_cached_input_tokens, :bigint, null: false, default: 0)
    end

    catalog_sync([Samen.AI.Agent.Run],
      only: [:cached_input_tokens_used, :max_cached_input_tokens]
    )

    catalog_sync([Samen.AI.Agent.Turn], only: [:cached_input_tokens])
  end
end
