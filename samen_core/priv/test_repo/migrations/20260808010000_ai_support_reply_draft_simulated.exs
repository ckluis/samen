defmodule SamenCore.TestRepo.Migrations.AiSupportReplyDraftSimulated do
  @moduledoc """
  Additive `sas_simulated :boolean` column on `ai_support_reply_draft` (PP-16, T152 honesty
  provenance). The D5 AI-support-operator draft (`Samen.AI.SupportReplyDraft`) now persists
  WHETHER its body came from a keyless/deterministic (SIMULATED) provider, so the tenant
  Support-draft list (which re-reads persisted rows) can render the loud "SIMULATED — not a
  real model" badge on a stored simulated draft — the persistence PP-15's in-memory thread
  cannot provide.

  Additive, nullable-by-default-then-defaulted column on an already-catalogued resource →
  `catalog_sync/2`'s `only:` scoping, so `down` (reversible via `change/0`) removes exactly
  the one `sas_simulated` `fld_field` row without touching the rest of the table entry
  (the `CrmScopeArchivable` additive-column precedent). No abbrev-registry allocation: the
  column reuses the existing owner abbrev `sas` (no new resource).
  """
  use Samen.Migration

  def change do
    alter table(:ai_support_reply_draft) do
      add(:sas_simulated, :boolean, null: false, default: false)
    end

    catalog_sync([Samen.AI.SupportReplyDraft], only: [:simulated])
  end
end
