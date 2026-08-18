defmodule Driftwood.Repo.Migrations.AiSupportReplyDraft do
  @moduledoc """
  `ai_support_reply_draft` — the D5 AI-support-operator draft resource (ADR-043 §6.3, T70),
  mounted in driftwood via `Samen.AI.Domain` (T155) so AI support-reply drafts PERSIST in a
  real host and flow through the `ai_support_reply` E3 approval engine end-to-end. Allocator-
  owned abbrev `sas` (samen_core-owned resource, host-invariant). Carries NO vault-routed
  column: `sas_body`/`sas_subject` are the AI operator's own masked output (already through the
  chokepoint egress scrub, not subject PII) and `sas_to_subscriber_id` is a recipient TOKEN
  (the email is revealed at delivery time, never stored). Replicates
  `samen_core/priv/test_repo/migrations/20260805160000_ai_support_reply_draft.exs` verbatim.
  """
  use Samen.Migration

  @resources [Samen.AI.SupportReplyDraft]

  def up do
    create table(:ai_support_reply_draft, primary_key: false) do
      add(:sas_to_subscriber_id, :uuid, null: false)
      add(:sas_inbound_ref, :text)
      add(:sas_subject, :text)
      add(:sas_body, :text, null: false)
      add(:sas_requested_by, :text)
      add(:sas_status, :text, null: false, default: "draft")
      add(:sas_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sas_org_id, :uuid, null: false)
      add(:sas_inserted_at, :utc_datetime, null: false)
      add(:sas_updated_at, :utc_datetime, null: false)
    end

    create(index(:ai_support_reply_draft, [:sas_org_id], name: "ai_support_reply_draft_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:ai_support_reply_draft, [:sas_org_id], name: "ai_support_reply_draft_org_idx"))
    drop(table(:ai_support_reply_draft))
  end
end
