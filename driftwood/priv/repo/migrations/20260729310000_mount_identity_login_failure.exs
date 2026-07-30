defmodule Driftwood.Repo.Migrations.MountIdentityLoginFailure do
  @moduledoc """
  ADR-038 §6.4 (T109, sibling-host mirror migration) — adds the identity spine's
  FIFTH org-less resource to driftwood's OPERATOR Identity mount:
  `Identity.LoginFailure`, the DURABLE brute-force failure counter. Mirrors
  `demo/priv/repo/migrations/20260729310000_mount_identity_login_failure.exs`
  exactly, adapted to driftwood's operator abbrev (`dol` — declared explicitly in
  `driftwood/lib/driftwood/operator.ex`'s `abbrevs:` map, registry row
  `hosts.driftwood.dol`, reserved by T109's `mix samen.abbrev.reserve`).

  Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  No PII here: `key_value` is a non-reversible `email_bidx` HMAC or an opaque
  credential UUID — never a plaintext email, never vault-routed.
  """
  use Samen.Migration

  @resources [Driftwood.Operator.LoginFailure]

  def up do
    create table(:dol_login_failure, primary_key: false) do
      add(:dol_key_kind, :text, null: false)
      add(:dol_key_value, :text, null: false)
      add(:dol_failure_count, :integer, null: false, default: 1)
      add(:dol_window_started_at, :utc_datetime_usec, null: false)
      add(:dol_last_failed_at, :utc_datetime_usec, null: false)

      add(:dol_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dol_org_id, :uuid)
      add(:dol_inserted_at, :utc_datetime, null: false)
      add(:dol_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:dol_login_failure, [:dol_key_kind, :dol_key_value]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:dol_login_failure))
  end
end
