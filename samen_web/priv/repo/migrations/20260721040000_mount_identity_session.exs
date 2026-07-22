defmodule Samen.WebTest.Repo.Migrations.MountIdentitySession do
  @moduledoc """
  ADR-035 §3.1/§4.3 (T03, A2+A3 token loops) — adds the identity spine's
  THIRD org-less resource to the samen_web test host's Operator Identity
  mount: `Identity.Session` (a revocable, DB-backed login session). A3's
  "revoke all sessions on reset" done-criterion needs real Session rows to
  revoke; T04 (A4) extends this SAME table with the full remember-me/
  listing/revocation surface — no second Session table, no schema churn.

  Fresh `wos` abbrev (append-only registry row, `mix samen.abbrev.reserve`).
  Catalogued in the SAME transaction (ADR-004 catalog-in-tx), mirroring
  `20260721010000_mount_identity_credential_auth_token.exs`.

  No PII here: `device_label` is a bounded browser/OS-family string (never
  the raw user-agent, never an IP); `token_digest` is the SHA-256 digest of
  the raw session token (the ApiKey `token_digest` precedent) — never
  vault-routed, never allowlisted.
  """
  use Samen.Migration

  @resources [Samen.WebTest.Operator.Session]

  def up do
    create table(:wos_session, primary_key: false) do
      add(:wos_token_digest, :text, null: false)
      add(:wos_last_seen_at, :utc_datetime)
      add(:wos_expires_at, :utc_datetime, null: false)
      add(:wos_revoked_at, :utc_datetime)
      add(:wos_device_label, :text)

      add(
        :wos_credential_id,
        references(:woc_credential,
          column: :woc_id,
          name: "wos_session_wos_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:wos_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wos_org_id, :uuid)
      add(:wos_inserted_at, :utc_datetime, null: false)
      add(:wos_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:wos_session, [:wos_token_digest]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:wos_session, "wos_session_wos_credential_id_fkey"))
    drop(table(:wos_session))
  end
end
