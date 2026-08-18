defmodule Samen.WebTest.Repo.Migrations.MountIdentityLoginFailure do
  @moduledoc """
  ADR-038 §6.4 (T109) — adds the identity spine's FIFTH org-less resource to the
  samen_web test host's Operator Identity mount: `Identity.LoginFailure`, the
  DURABLE brute-force failure counter. Mirrors
  `demo/priv/repo/migrations/20260729310000_mount_identity_login_failure.exs`
  exactly, adapted to the samen_web test host's `wol` abbrev (append-only registry
  row, `mix samen.abbrev.reserve`).

  Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  No PII here: `key_value` is a non-reversible `email_bidx` HMAC or an opaque
  credential UUID — never a plaintext email, never vault-routed.
  """
  use Samen.Migration

  @resources [Samen.WebTest.Operator.LoginFailure]

  def up do
    create table(:wol_login_failure, primary_key: false) do
      add(:wol_key_kind, :text, null: false)
      add(:wol_key_value, :text, null: false)
      add(:wol_failure_count, :integer, null: false, default: 1)
      add(:wol_window_started_at, :utc_datetime_usec, null: false)
      add(:wol_last_failed_at, :utc_datetime_usec, null: false)

      add(:wol_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wol_org_id, :uuid)
      add(:wol_inserted_at, :utc_datetime, null: false)
      add(:wol_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:wol_login_failure, [:wol_key_kind, :wol_key_value]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:wol_login_failure))
  end
end
