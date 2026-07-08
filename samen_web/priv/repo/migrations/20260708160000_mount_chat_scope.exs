defmodule Samen.WebTest.Repo.Migrations.MountChatScope do
  @moduledoc """
  Mounts the `Samen.Scopes.Chat` blueprint (ADR-012 — the flagship cross-plane realtime chat)
  into the samen_web test host's one Postgres, and catalogs every resource in the SAME
  migration transaction (ADR-004 catalog-in-tx). Fresh `wc*` abbrevs (see `Samen.WebTest.Chat`).

  ## Chat — wct/wcp/wcm/wcd

    * `wct_thread`             — a conversation that may span two planes (no PII)
    * `wcp_participant`        — 🔒 PII: full_name (composite vault token) + non-PII handle;
                                 the cross-plane grant carrier (party) + identity_shared opt-in
    * `wcm_message`            — 🔒 PII: body (scalar pii_ token; free-text vault) + refs
    * `wcd_disclosure_setting` — Tier-0 per-org identity-disclosure config (no PII)

  ## PII columns (vault vt_* tokens — plaintext never lands here)

  - `wcp_participant.wcp_full_name` — composite vault token (VaultField; no pii_ prefix)
  - `wcm_message.pii_wcm_body`      — scalar vault token (pii_ prefix; free-text)

  ## FK order

  wct_thread ← wcp_participant ← wcm_message → wct_thread
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Chat.ChatThread,
    Samen.WebTest.Chat.ChatParticipant,
    Samen.WebTest.Chat.ChatMessage,
    Samen.WebTest.Chat.ChatDisclosureSetting
  ]

  def up do
    # --- wct_thread : a conversation that may span two planes (no PII) ---
    create table(:wct_thread, primary_key: false) do
      add(:wct_subject, :text)
      add(:wct_kind, :text, default: "cross_plane")
      add(:wct_status, :text, default: "open")
      add(:wct_disclosure_mode, :text, default: "masked")
      add(:wct_context_ref, :text)
      add(:wct_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wct_org_id, :uuid, null: false)
      add(:wct_inserted_at, :utc_datetime, null: false)
      add(:wct_updated_at, :utc_datetime, null: false)
    end

    # --- wcp_participant : 🔒 PII full_name (composite vault token) + the grant carrier ---
    create table(:wcp_participant, primary_key: false) do
      add(:wcp_party, :text, default: "tenant")
      add(:wcp_principal_kind, :text, default: "user")
      add(:wcp_principal_id, :text)
      add(:wcp_handle, :text)
      add(:wcp_identity_shared, :boolean, default: false)
      add(:wcp_role, :text, default: "member")
      add(:wcp_online_at, :utc_datetime)
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:wcp_full_name, :text)

      add(
        :wcp_thread_id,
        references(:wct_thread,
          column: :wct_id,
          name: "wcp_participant_wcp_thread_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:wcp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcp_org_id, :uuid, null: false)
      add(:wcp_inserted_at, :utc_datetime, null: false)
      add(:wcp_updated_at, :utc_datetime, null: false)
    end

    # --- wcm_message : 🔒 PII body (scalar pii_ token — free-text vault) + refs ---
    create table(:wcm_message, primary_key: false) do
      add(:wcm_sender_party, :text, default: "tenant")
      add(:wcm_kind, :text, default: "message")
      add(:wcm_refs, {:array, :text}, default: [])
      # Scalar PII vault token: body carries the pii_ prefix (pii_wcm_body). Free-text.
      add(:pii_wcm_body, :text)

      add(
        :wcm_thread_id,
        references(:wct_thread,
          column: :wct_id,
          name: "wcm_message_wcm_thread_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :wcm_participant_id,
        references(:wcp_participant,
          column: :wcp_id,
          name: "wcm_message_wcm_participant_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:wcm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcm_org_id, :uuid, null: false)
      add(:wcm_inserted_at, :utc_datetime, null: false)
      add(:wcm_updated_at, :utc_datetime, null: false)
    end

    # --- wcd_disclosure_setting : Tier-0 per-org identity-disclosure config (no PII) ---
    create table(:wcd_disclosure_setting, primary_key: false) do
      add(:wcd_expose_identity_to_support, :boolean, default: false)
      add(:wcd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcd_org_id, :uuid, null: false)
      add(:wcd_inserted_at, :utc_datetime, null: false)
      add(:wcd_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:wcd_disclosure_setting))

    drop(constraint(:wcm_message, "wcm_message_wcm_participant_id_fkey"))
    drop(constraint(:wcm_message, "wcm_message_wcm_thread_id_fkey"))
    drop(table(:wcm_message))

    drop(constraint(:wcp_participant, "wcp_participant_wcp_thread_id_fkey"))
    drop(table(:wcp_participant))

    drop(table(:wct_thread))
  end
end
