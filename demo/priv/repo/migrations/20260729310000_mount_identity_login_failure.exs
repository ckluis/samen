defmodule Demo.Repo.Migrations.MountIdentityLoginFailure do
  @moduledoc """
  ADR-038 §6.4 (T109) — adds the identity spine's FIFTH org-less resource to the
  demo host's Identity mount: `Identity.LoginFailure`, the DURABLE brute-force
  failure counter. Closes T103's named §6.4 mechanism gap (the count was
  ETS-ephemeral, reset on restart): one row per `(key_kind, key_value)` — the SAME
  two non-PII key axes `Samen.Web.RateLimit`'s bounded `login_failed_audit` counter
  already bumps (`email_bidx` for the sign-in path, `credential` id for the
  post-2FA-pending wrong-code path).

  Fresh `dil` abbrev (append-only registry row, `mix samen.abbrev.reserve`).
  Catalogued in the SAME transaction (ADR-004 catalog-in-tx), mirroring
  `20260721050000_mount_identity_session.exs`.

  No PII here: `key_value` is a non-reversible `email_bidx` HMAC or an opaque
  credential UUID — never a plaintext email, never vault-routed.
  """
  use Samen.Migration

  @resources [Demo.Identity.LoginFailure]

  def up do
    create table(:dil_login_failure, primary_key: false) do
      add(:dil_key_kind, :text, null: false)
      add(:dil_key_value, :text, null: false)
      add(:dil_failure_count, :integer, null: false, default: 1)
      add(:dil_window_started_at, :utc_datetime_usec, null: false)
      add(:dil_last_failed_at, :utc_datetime_usec, null: false)

      add(:dil_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dil_org_id, :uuid)
      add(:dil_inserted_at, :utc_datetime, null: false)
      add(:dil_updated_at, :utc_datetime, null: false)
    end

    # The bump!/reset! upsert key (Samen.Identity.LoginFailure's raw-SQL write path
    # ON CONFLICTs on exactly this pair) — one row per (key_kind, key_value).
    create(unique_index(:dil_login_failure, [:dil_key_kind, :dil_key_value]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:dil_login_failure))
  end
end
