defmodule Driftwood.Repo.Migrations.AiSupportReplyDraftSimulated do
  @moduledoc """
  Additive `sas_simulated :boolean` column on `ai_support_reply_draft` (PP-16, T152 honesty
  provenance) — the driftwood host replica of
  `samen_core/priv/test_repo/migrations/20260808010000_ai_support_reply_draft_simulated.exs`.
  Driftwood mounts `Samen.AI.Domain` (T155) so AI support-reply drafts persist end to end; the
  new column stores whether a draft body came from a keyless/deterministic (SIMULATED) provider
  so the tenant Support-draft list renders the loud "SIMULATED — not a real model" badge on a
  stored simulated draft. Additive, `catalog_sync/2 only:`-scoped (reversible via `change/0`);
  reuses the existing owner abbrev `sas` (no new resource → no registry allocation). Regenerate
  `schema.dict.json` after this migration (`MIX_ENV=test mix samen.catalog.dump --output
  schema.dict.json`).
  """
  use Samen.Migration

  def change do
    alter table(:ai_support_reply_draft) do
      add(:sas_simulated, :boolean, null: false, default: false)
    end

    catalog_sync([Samen.AI.SupportReplyDraft], only: [:simulated])
  end
end
