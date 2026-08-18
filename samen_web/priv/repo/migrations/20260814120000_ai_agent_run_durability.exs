defmodule Samen.WebTest.Repo.Migrations.AiAgentRunDurability do
  @moduledoc """
  ADR-047 batch A2 (durability + erasure) — additive columns on the two A1 agent tables:

    * `ai_agent_run.pii_arn_transcript` — the run's ONE persisted text artifact (goal +
      rendered lines), **vault-routed** (`pii do vault(:pii_transcript) … end` on
      `Samen.AI.Agent.Run`): the column only ever holds a `vt_*` token
      (`Samen.Vault.Change` + `Samen.Type.VaultField`'s fail-closed dump refusal); the
      plaintext ciphertext lives in `pii_vault` under the run row's OWN DEK (§7.4),
      reached by the derived 90-day retention `:shred` arm (§9#4 TAKEN).
    * `ai_agent_run.arn_owner_id` / `arn_agent_module` — the durable facts the Oban
      worker resumes from: the initiating member (owner re-resolution, never silent
      re-attribution) and the agent definition module (validated on resolve).
    * `ai_agent_turn.atn_meta` — the bounded jsonb replay/outcome provenance
      (`Samen.AI.Agent.bounded_meta/1`-filtered; token-only by allowlist).

  Additive, nullable-or-defaulted columns on already-catalogued resources →
  `catalog_sync/2`'s `only:` scoping (the `sas_simulated` precedent), reversible via
  `change/0`. No abbrev-registry allocation: the columns reuse the existing owner
  abbrevs `arn`/`atn` (no new resource).
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
