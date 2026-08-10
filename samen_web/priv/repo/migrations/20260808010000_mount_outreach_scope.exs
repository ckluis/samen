defmodule Samen.WebTest.Repo.Migrations.MountOutreachScope do
  @moduledoc """
  Mounts the Outreach universal scope (spec §I2 CRM sequences actually send, T75) into
  the samen_web test host's Postgres, and catalogs all three resources in the SAME
  migration transaction (ADR-004 catalog-in-tx). Mirrors
  `samen_core/priv/test_repo/migrations/20260806130000_outreach_fixture.exs` with the
  samen_web test host's own `wso`/`woe`/`ows` abbrevs.

  No PII by schema on any of the three tables: `wso_steps` is tenant-authored template
  config (subject/body strings a human wrote — the same non-PII posture as
  `Marketing.Template`), `woe_person_id` is an OPAQUE uuid reference (no FK — the scope
  mounts independently of CRM, mirrors `Samen.Scopes.Mailbox.MailMessage.company_id`).
  There is deliberately NO `pii_`-prefixed column anywhere on this scope (INV-1): the
  Sequences tenant surface therefore resolves nothing through the vault.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Outreach.Sequence,
    Samen.WebTest.Outreach.Enrollment,
    Samen.WebTest.Outreach.StepSend
  ]

  def up do
    # --- wso_sequence : tenant-defined multi-step outreach definition (no PII) ---
    create table(:wso_sequence, primary_key: false) do
      add(:wso_name, :text, null: false)
      add(:wso_status, :text, null: false, default: "draft")
      add(:wso_steps, :map, default: fragment("'[]'::jsonb"))

      add(:wso_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wso_org_id, :uuid, null: false)
      add(:wso_inserted_at, :utc_datetime, null: false)
      add(:wso_updated_at, :utc_datetime, null: false)
    end

    create(index(:wso_sequence, [:wso_org_id]))

    # --- woe_enrollment : one contact's membership in a Sequence (opaque person_id) ---
    create table(:woe_enrollment, primary_key: false) do
      add(:woe_person_id, :uuid, null: false)
      add(:woe_status, :text, null: false, default: "active")
      add(:woe_current_step, :integer, null: false, default: 0)
      add(:woe_next_send_at, :utc_datetime)
      add(:woe_paused_reason, :text)
      add(:woe_enrolled_at, :utc_datetime)
      add(:woe_completed_at, :utc_datetime)
      add(:woe_reply_cutoff_at, :utc_datetime)

      add(
        :woe_sequence_id,
        references(:wso_sequence,
          column: :wso_id,
          name: "woe_enrollment_woe_sequence_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:woe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:woe_org_id, :uuid, null: false)
      add(:woe_inserted_at, :utc_datetime, null: false)
      add(:woe_updated_at, :utc_datetime, null: false)
    end

    create(index(:woe_enrollment, [:woe_org_id]))
    create(index(:woe_enrollment, [:woe_org_id, :woe_person_id]))
    create(index(:woe_enrollment, [:woe_status, :woe_next_send_at], name: "woe_enrollment_due_scan_idx"))

    # --- ows_step_send : one step's honest send outcome (no PII) ---
    create table(:ows_step_send, primary_key: false) do
      add(:ows_step_index, :integer, null: false)
      add(:ows_status, :text, null: false, default: "queued")
      add(:ows_queued_at, :utc_datetime)
      add(:ows_sent_at, :utc_datetime)
      add(:ows_provider_message_id, :text)
      add(:ows_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :ows_enrollment_id,
        references(:woe_enrollment,
          column: :woe_id,
          name: "ows_step_send_ows_enrollment_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:ows_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ows_org_id, :uuid, null: false)
      add(:ows_inserted_at, :utc_datetime, null: false)
      add(:ows_updated_at, :utc_datetime, null: false)
    end

    create(index(:ows_step_send, [:ows_org_id]))
    create(index(:ows_step_send, [:ows_org_id, :ows_enrollment_id]))
    create(index(:ows_step_send, [:ows_provider_message_id]))
    create(index(:ows_step_send, [:ows_enrollment_id, :ows_step_index], name: "ows_step_send_enrollment_step_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:ows_step_send))
    drop(table(:woe_enrollment))
    drop(table(:wso_sequence))
  end
end
