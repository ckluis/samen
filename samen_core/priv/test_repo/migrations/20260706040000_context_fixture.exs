defmodule SamenCore.TestRepo.Migrations.ContextFixture do
  @moduledoc """
  T3.10 test fixture: the toy KERNEL tables the `Samen.Context` DSL aliases and
  reshapes — `cea_activity` (aliased as `Encounter`, carries a vault-routed PII
  token column) and `cei_invoice` (reshaped into a money split). Plus their
  catalog rows, so catalog parity holds.

  `cea_attendee_note` is a `:text` TOKEN column (vault-routed PII, `vt_*`), never
  plaintext — the alias tests prove masking rides underneath the rename.
  """
  use Samen.Migration

  @resources [Core.Ctx.Activity, Core.Ctx.Invoice]

  def up do
    create table(:cea_activity, primary_key: false) do
      add(:cea_kind, :text, null: false)
      add(:cea_subject, :text)
      # Vault-routed PII: a text token column (holds vt_*), never plaintext.
      # Scalar pii_attribute carries the pii_ prefix: pii_cea_attendee_note.
      add(:pii_cea_attendee_note, :text)
      add(:cea_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cea_org_id, :uuid, null: false)
      add(:cea_inserted_at, :utc_datetime, null: false)
      add(:cea_updated_at, :utc_datetime, null: false)
    end

    create table(:cei_invoice, primary_key: false) do
      add(:cei_total, :decimal, null: false)
      add(:cei_covered_amount, :decimal, null: false, default: 0)
      add(:cei_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cei_org_id, :uuid, null: false)
      add(:cei_inserted_at, :utc_datetime, null: false)
      add(:cei_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:cei_invoice))
    drop(table(:cea_activity))
  end
end
