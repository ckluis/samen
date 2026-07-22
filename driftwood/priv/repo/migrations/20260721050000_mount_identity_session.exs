defmodule Driftwood.Repo.Migrations.MountIdentitySession do
  @moduledoc """
  ADR-035 §3.1/§4.3 (T04, binding addendum — sibling-host mirror migration) —
  adds the identity spine's THIRD org-less resource to driftwood's OPERATOR
  Identity mount: `Identity.Session` (a revocable, DB-backed login session).
  Mirrors `samen_web/priv/repo/migrations/20260721040000_mount_identity_session.exs`
  exactly, adapted to driftwood's operator abbrevs (`dos` — declared explicitly
  in `driftwood/lib/driftwood/operator.ex`'s `abbrevs:` map, registry row
  `hosts.driftwood.dos`, reserved by T03's `mix samen.abbrev.reserve`).

  Per the T04 addendum, this ships NOW rather than deferred (the deferral
  pattern T02/T03 used for demo/driftwood's own Credential/AuthToken/Session
  migrations stops here — every WS-A task from T04 on ships host mirror
  migrations for any blueprint resource it adds or extends).

  Catalogued in the SAME transaction (ADR-004 catalog-in-tx), mirroring
  `20260721040000_mount_identity_credential_auth_token.exs`.

  No PII here: `device_label` is a bounded browser/OS-family string (never
  the raw user-agent, never an IP); `token_digest` is the SHA-256 digest of
  the raw session token (the ApiKey `token_digest` precedent) — never
  vault-routed, never allowlisted.
  """
  use Samen.Migration

  @resources [Driftwood.Operator.Session]

  def up do
    create table(:dos_session, primary_key: false) do
      add(:dos_token_digest, :text, null: false)
      add(:dos_last_seen_at, :utc_datetime)
      add(:dos_expires_at, :utc_datetime, null: false)
      add(:dos_revoked_at, :utc_datetime)
      add(:dos_device_label, :text)

      add(
        :dos_credential_id,
        references(:doc_credential,
          column: :doc_id,
          name: "dos_session_dos_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:dos_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dos_org_id, :uuid)
      add(:dos_inserted_at, :utc_datetime, null: false)
      add(:dos_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:dos_session, [:dos_token_digest]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:dos_session, "dos_session_dos_credential_id_fkey"))
    drop(table(:dos_session))
  end
end
