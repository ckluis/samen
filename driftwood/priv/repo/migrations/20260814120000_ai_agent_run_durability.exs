defmodule Driftwood.Repo.Migrations.AiAgentRunDurability do
  @moduledoc """
  ADR-047 batch A2 (durability + erasure) — the driftwood mount of the additive agent
  columns (the samen_core-owned `Samen.AI.Agent.{Run,Turn}` resources ride this host's
  repo via `Samen.AI.Domain`; the `ai_prompt` T155 precedent). Replicates
  `samen_core/priv/test_repo/migrations/20260814120000_ai_agent_run_durability.exs`
  verbatim:

    * `ai_agent_run.pii_arn_transcript` — the vault-routed transcript (ADR-047 §7.4):
      only ever a `vt_*` token at rest; ciphertext under the run row's own DEK; reached
      by the derived 90-day retention `:shred` arm (§9#4 TAKEN);
    * `ai_agent_run.arn_owner_id` / `arn_agent_module` — the durable worker-resume facts;
    * `ai_agent_turn.atn_meta` — bounded jsonb replay provenance (token-only allowlist).

  Additive columns on already-catalogued resources → `catalog_sync/2` `only:` scoping,
  reversible via `change/0`. No abbrev-registry allocation (existing `arn`/`atn` owners).
  """
  use Samen.Migration

  def change do
    alter table(:ai_agent_run) do
      add(:arn_owner_id, :text)
      add(:arn_agent_module, :text)
      add(:pii_arn_transcript, :text)
    end

    alter table(:ai_agent_turn) do
      add(:atn_meta, :map, null: false, default: %{})
    end

    catalog_sync([Samen.AI.Agent.Run], only: [:owner_id, :agent_module, :transcript])
    catalog_sync([Samen.AI.Agent.Turn], only: [:meta])
  end
end
