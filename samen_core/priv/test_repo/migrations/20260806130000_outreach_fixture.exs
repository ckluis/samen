defmodule SamenCore.TestRepo.Migrations.OutreachFixture do
  @moduledoc """
  T75 (spec §I2 CRM sequences actually send) Outreach-scope fixture tables:
  `Sequence` (`sos`), `Enrollment` (`soe`), `StepSend` (`sso`) mounted in
  `samen_core` tests via `test/support/outreach_fixture.ex`.

  No PII by schema on any of the three tables: `sos_steps` is tenant-authored
  template config (subject/body strings a human wrote — the same non-PII
  posture as `Marketing.Template`), `soe_person_id` is an opaque uuid reference
  (no FK — the scope mounts independently of CRM, mirrors
  `Samen.Scopes.Mailbox.MailMessage.company_id`).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.OutreachFixture.Sequence,
    SamenCore.Support.OutreachFixture.Enrollment,
    SamenCore.Support.OutreachFixture.StepSend
  ]

  def up do
    # --- sos_sequence : tenant-defined multi-step outreach definition ---
    create table(:sos_sequence, primary_key: false) do
      add(:sos_name, :text, null: false)
      add(:sos_status, :text, null: false, default: "draft")
      add(:sos_steps, :map, default: fragment("'[]'::jsonb"))

      add(:sos_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sos_org_id, :uuid, null: false)
      add(:sos_inserted_at, :utc_datetime, null: false)
      add(:sos_updated_at, :utc_datetime, null: false)
    end

    create(index(:sos_sequence, [:sos_org_id]))

    # --- soe_enrollment : one contact's membership in a Sequence ---
    create table(:soe_enrollment, primary_key: false) do
      add(:soe_person_id, :uuid, null: false)
      add(:soe_status, :text, null: false, default: "active")
      add(:soe_current_step, :integer, null: false, default: 0)
      add(:soe_next_send_at, :utc_datetime)
      add(:soe_paused_reason, :text)
      add(:soe_enrolled_at, :utc_datetime)
      add(:soe_completed_at, :utc_datetime)
      # T75 fix round MED-4: the reply-detection cutoff, independent of
      # `soe_enrolled_at` (which is a permanent, never-updated fact). Initialized
      # to `enrolled_at`; bumped to "now" by `:resume` so a resumed enrollment
      # is not immediately re-paused by the SAME stale reply that (correctly)
      # paused it the first time.
      add(:soe_reply_cutoff_at, :utc_datetime)

      add(
        :soe_sequence_id,
        references(:sos_sequence,
          column: :sos_id,
          name: "soe_enrollment_soe_sequence_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:soe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:soe_org_id, :uuid, null: false)
      add(:soe_inserted_at, :utc_datetime, null: false)
      add(:soe_updated_at, :utc_datetime, null: false)
    end

    create(index(:soe_enrollment, [:soe_org_id]))
    create(index(:soe_enrollment, [:soe_org_id, :soe_person_id]))
    # The AshOban :sequence_step_due scan's own WHERE clause (status/next_send_at).
    create(index(:soe_enrollment, [:soe_status, :soe_next_send_at], name: "soe_enrollment_due_scan_idx"))

    # --- sso_step_send : one step's honest send outcome ---
    create table(:sso_step_send, primary_key: false) do
      add(:sso_step_index, :integer, null: false)
      add(:sso_status, :text, null: false, default: "queued")
      add(:sso_queued_at, :utc_datetime)
      add(:sso_sent_at, :utc_datetime)
      add(:sso_provider_message_id, :text)
      add(:sso_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :sso_enrollment_id,
        references(:soe_enrollment,
          column: :soe_id,
          name: "sso_step_send_sso_enrollment_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:sso_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sso_org_id, :uuid, null: false)
      add(:sso_inserted_at, :utc_datetime, null: false)
      add(:sso_updated_at, :utc_datetime, null: false)
    end

    create(index(:sso_step_send, [:sso_org_id]))
    create(index(:sso_step_send, [:sso_org_id, :sso_enrollment_id]))
    # T75 fix round MED-3: the deliverability receipt-lookup join key
    # (`Samen.Sequences.ReceiptLookup`, mirrors `MarketingReceiptLookup`'s own
    # provider_message_id lookup).
    create(index(:sso_step_send, [:sso_provider_message_id]))
    create(index(:sso_step_send, [:sso_enrollment_id, :sso_step_index], name: "sso_step_send_enrollment_step_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sso_step_send))
    drop(table(:soe_enrollment))
    drop(table(:sos_sequence))
  end
end
