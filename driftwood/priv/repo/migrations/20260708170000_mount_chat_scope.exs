defmodule Driftwood.Repo.Migrations.MountChatScope do
  @moduledoc """
  Mounts the Driftwood Chat scope tables (fresh abbrevs dct/dcp/dcm/dcd — the FLAGSHIP
  cross-plane realtime chat, ADR-012) and catalogs every resource in the SAME migration
  transaction (ADR-004 catalog-in-tx). Column shape mirrors the `Samen.Scopes.Chat` blueprint.

  ## Chat — dct/dcp/dcm/dcd

    * `dct_thread`             — a conversation that may span two planes (no PII)
    * `dcp_participant`        — 🔒 PII: full_name (composite vault token) + the grant carrier
    * `dcm_message`            — 🔒 PII: body (scalar pii_ token; free-text vault) + refs
    * `dcd_disclosure_setting` — Tier-0 per-org identity-disclosure config (no PII)

  ## PII columns (vault vt_* tokens — plaintext never lands here)

  - `dcp_participant.dcp_full_name` — composite vault token (VaultField; no pii_ prefix)
  - `dcm_message.pii_dcm_body`      — scalar vault token (pii_ prefix; free-text)

  ## FK order: dct_thread ← dcp_participant ← dcm_message → dct_thread
  """
  use Samen.Migration

  @resources [
    Driftwood.Chat.ChatThread,
    Driftwood.Chat.ChatParticipant,
    Driftwood.Chat.ChatMessage,
    Driftwood.Chat.ChatDisclosureSetting
  ]

  def up do
    create table(:dct_thread, primary_key: false) do
      add(:dct_subject, :text)
      add(:dct_kind, :text, default: "cross_plane")
      add(:dct_status, :text, default: "open")
      add(:dct_disclosure_mode, :text, default: "masked")
      add(:dct_context_ref, :text)
      add(:dct_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dct_org_id, :uuid, null: false)
      add(:dct_inserted_at, :utc_datetime, null: false)
      add(:dct_updated_at, :utc_datetime, null: false)
    end

    create table(:dcp_participant, primary_key: false) do
      add(:dcp_party, :text, default: "tenant")
      add(:dcp_principal_kind, :text, default: "user")
      add(:dcp_principal_id, :text)
      add(:dcp_handle, :text)
      add(:dcp_identity_shared, :boolean, default: false)
      add(:dcp_role, :text, default: "member")
      add(:dcp_online_at, :utc_datetime)
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:dcp_full_name, :text)

      add(
        :dcp_thread_id,
        references(:dct_thread,
          column: :dct_id,
          name: "dcp_participant_dcp_thread_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:dcp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dcp_org_id, :uuid, null: false)
      add(:dcp_inserted_at, :utc_datetime, null: false)
      add(:dcp_updated_at, :utc_datetime, null: false)
    end

    create table(:dcm_message, primary_key: false) do
      add(:dcm_sender_party, :text, default: "tenant")
      add(:dcm_kind, :text, default: "message")
      add(:dcm_refs, {:array, :text}, default: [])
      # Scalar PII vault token: body carries the pii_ prefix (pii_dcm_body). Free-text.
      add(:pii_dcm_body, :text)

      add(
        :dcm_thread_id,
        references(:dct_thread,
          column: :dct_id,
          name: "dcm_message_dcm_thread_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dcm_participant_id,
        references(:dcp_participant,
          column: :dcp_id,
          name: "dcm_message_dcm_participant_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:dcm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dcm_org_id, :uuid, null: false)
      add(:dcm_inserted_at, :utc_datetime, null: false)
      add(:dcm_updated_at, :utc_datetime, null: false)
    end

    create table(:dcd_disclosure_setting, primary_key: false) do
      add(:dcd_expose_identity_to_support, :boolean, default: false)
      add(:dcd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dcd_org_id, :uuid, null: false)
      add(:dcd_inserted_at, :utc_datetime, null: false)
      add(:dcd_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:dcd_disclosure_setting))

    drop(constraint(:dcm_message, "dcm_message_dcm_participant_id_fkey"))
    drop(constraint(:dcm_message, "dcm_message_dcm_thread_id_fkey"))
    drop(table(:dcm_message))

    drop(constraint(:dcp_participant, "dcp_participant_dcp_thread_id_fkey"))
    drop(table(:dcp_participant))

    drop(table(:dct_thread))
  end
end
