defmodule Demo.Repo.Migrations.AddSupportScope do
  @moduledoc """
  Mounts the Support scope tables into the Demo host's one Postgres, and catalogs
  them in the SAME migration transaction (ADR-004 §"Migrations": the
  catalog-in-tx guarantee requires DDL + catalog_sync in one transaction in the
  host's repo).

  T3.6 — the Support scope (doc §"The inherited 80%" scope table:
  `ticket · conversation · message🔒 · agent🔒 · sla · macro · csat`):

    * `ssl_sla`         — Tier-0 config rows: SLA policies per org (first-response/resolution targets)
    * `stk_ticket`      — the top-level support ticket (SLA deadline, priority, status; no PII)
    * `scv_conversation`— a conversation thread on a ticket (no PII)
    * `sag_agent`       — 🔒 PII: full_name (composite, vault :pii_name) + email (scalar pii_ prefix)
    * `smg_message`     — 🔒 PII: body (scalar, vault :pii_body; free-text; pii_ prefix)
    * `smc_macro`       — Tier-0 config rows: canned response macros per org
    * `scs_csat`        — customer satisfaction survey responses

  ## PII columns

  - `sag_agent.sag_full_name` — composite vault token (VaultField type; no `pii_` prefix)
  - `sag_agent.pii_sag_email` — scalar vault token (`pii_` prefix per storage convention)
  - `smg_message.pii_smg_body`— scalar vault token (`pii_` prefix per storage convention)

  See `Samen.Scopes.Support.Blueprint` moduledoc for the free-text-vs-composite tension
  documentation on `message.body`.

  ## FK order

  ssl_sla ← stk_ticket ← scv_conversation ← smg_message → sag_agent
  stk_ticket ← scs_csat → sag_agent

  `sag_agent` is independent (no FK dependencies from system resources — agents
  are looked up by ID from messages and csats).
  """
  use Samen.Migration

  @resources [
    Demo.SupportScope.Sla,
    Demo.SupportScope.Ticket,
    Demo.SupportScope.Conversation,
    Demo.SupportScope.Agent,
    Demo.SupportScope.Message,
    Demo.SupportScope.Macro,
    Demo.SupportScope.Csat
  ]

  def up do
    # --- ssl_sla : Tier-0 SLA policy rows ---
    create table(:ssl_sla, primary_key: false) do
      add(:ssl_name, :text, null: false)
      add(:ssl_label, :text)
      add(:ssl_first_response_minutes, :integer, default: 60)
      add(:ssl_resolve_minutes, :integer, default: 480)
      add(:ssl_priority, :text, default: "normal")
      add(:ssl_enabled, :boolean, default: true)
      add(:ssl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ssl_org_id, :uuid, null: false)
      add(:ssl_inserted_at, :utc_datetime, null: false)
      add(:ssl_updated_at, :utc_datetime, null: false)
    end

    # --- stk_ticket : the top-level support ticket ---
    create table(:stk_ticket, primary_key: false) do
      add(:stk_subject, :text, null: false)
      add(:stk_status, :text, default: "open")
      add(:stk_priority, :text, default: "normal")
      # SLA deadline — set at create time; the SlaBreachWorker cron scans this.
      add(:stk_sla_breach_at, :utc_datetime)
      add(:stk_breached, :boolean, default: false, null: false)
      add(:stk_resolved_at, :utc_datetime)
      add(:stk_closed_at, :utc_datetime)
      add(:stk_tags, {:array, :text}, default: [])
      add(:stk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:stk_external_id, :text)

      add(
        :stk_sla_id,
        references(:ssl_sla,
          column: :ssl_id,
          name: "stk_ticket_stk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:stk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:stk_org_id, :uuid, null: false)
      add(:stk_inserted_at, :utc_datetime, null: false)
      add(:stk_updated_at, :utc_datetime, null: false)
    end

    # Index for the SlaBreachWorker cron query performance.
    create(
      index(:stk_ticket, [:stk_sla_breach_at, :stk_breached],
        name: "stk_ticket_sla_breach_idx",
        where: "stk_sla_breach_at IS NOT NULL AND stk_breached = false"
      )
    )

    # --- scv_conversation : a conversation thread on a ticket ---
    create table(:scv_conversation, primary_key: false) do
      add(:scv_channel, :text, default: "email")
      add(:scv_status, :text, default: "open")
      add(:scv_subject, :text)

      add(
        :scv_ticket_id,
        references(:stk_ticket,
          column: :stk_id,
          name: "scv_conversation_scv_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:scv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scv_org_id, :uuid, null: false)
      add(:scv_inserted_at, :utc_datetime, null: false)
      add(:scv_updated_at, :utc_datetime, null: false)
    end

    # --- sag_agent : 🔒 PII: full_name (composite vault token) + email (scalar pii_ token) ---
    create table(:sag_agent, primary_key: false) do
      add(:sag_handle, :text)
      add(:sag_status, :text, default: "active")
      add(:sag_role, :text, default: "agent")
      add(:sag_external_id, :text)
      add(:sag_timezone, :text)
      add(:sag_custom, :map, default: fragment("'{}'::jsonb"))
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:sag_full_name, :text)
      # Scalar PII vault token: email carries the pii_ prefix (pii_sag_email).
      add(:pii_sag_email, :text)
      add(:sag_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sag_org_id, :uuid, null: false)
      add(:sag_inserted_at, :utc_datetime, null: false)
      add(:sag_updated_at, :utc_datetime, null: false)
    end

    # --- smg_message : 🔒 PII: body (scalar pii_ token — free-text vault) ---
    create table(:smg_message, primary_key: false) do
      add(:smg_sender_type, :text, default: "customer")
      add(:smg_sender_id, :uuid)
      add(:smg_message_type, :text, default: "reply")
      add(:smg_attachments, {:array, :text}, default: [])
      add(:smg_created_via, :text, default: "web")
      # Scalar PII vault token: body carries the pii_ prefix (pii_smg_body).
      # Free-text message content — vaulted as a single ciphertext blob.
      add(:pii_smg_body, :text)

      add(
        :smg_conversation_id,
        references(:scv_conversation,
          column: :scv_id,
          name: "smg_message_smg_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :smg_agent_id,
        references(:sag_agent,
          column: :sag_id,
          name: "smg_message_smg_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:smg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:smg_org_id, :uuid, null: false)
      add(:smg_inserted_at, :utc_datetime, null: false)
      add(:smg_updated_at, :utc_datetime, null: false)
    end

    # --- smc_macro : Tier-0 canned response macros per org ---
    create table(:smc_macro, primary_key: false) do
      add(:smc_name, :text, null: false)
      add(:smc_description, :text)
      # body_template: operator-authored template text — non-PII (see NonPiiSetup).
      add(:smc_body_template, :text)
      add(:smc_tags, {:array, :text}, default: [])
      add(:smc_enabled, :boolean, default: true)
      add(:smc_category, :text)
      add(:smc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:smc_org_id, :uuid, null: false)
      add(:smc_inserted_at, :utc_datetime, null: false)
      add(:smc_updated_at, :utc_datetime, null: false)
    end

    # --- scs_csat : customer satisfaction survey responses ---
    create table(:scs_csat, primary_key: false) do
      add(:scs_score, :integer, null: false)
      # scs_comments: free-text survey response — non-PII (see NonPiiSetup).
      add(:scs_comments, :text)
      add(:scs_channel, :text, default: "email")
      add(:scs_responded_at, :utc_datetime)

      add(
        :scs_ticket_id,
        references(:stk_ticket,
          column: :stk_id,
          name: "scs_csat_scs_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :scs_agent_id,
        references(:sag_agent,
          column: :sag_id,
          name: "scs_csat_scs_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:scs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scs_org_id, :uuid, null: false)
      add(:scs_inserted_at, :utc_datetime, null: false)
      add(:scs_updated_at, :utc_datetime, null: false)
    end

    # --- catalog all seven Support resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse FK order.
    drop(constraint(:scs_csat, "scs_csat_scs_agent_id_fkey"))
    drop(constraint(:scs_csat, "scs_csat_scs_ticket_id_fkey"))
    drop(table(:scs_csat))

    drop(constraint(:smg_message, "smg_message_smg_agent_id_fkey"))
    drop(constraint(:smg_message, "smg_message_smg_conversation_id_fkey"))
    drop(table(:smg_message))

    drop(table(:smc_macro))

    drop(constraint(:scv_conversation, "scv_conversation_scv_ticket_id_fkey"))
    drop(table(:scv_conversation))

    drop(table(:sag_agent))

    drop(index(:stk_ticket, [:stk_sla_breach_at, :stk_breached], name: "stk_ticket_sla_breach_idx"))
    drop(constraint(:stk_ticket, "stk_ticket_stk_sla_id_fkey"))
    drop(table(:stk_ticket))

    drop(table(:ssl_sla))
  end
end
