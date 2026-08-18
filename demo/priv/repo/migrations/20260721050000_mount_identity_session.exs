defmodule Demo.Repo.Migrations.MountIdentitySession do
  @moduledoc """
  ADR-035 §3.1/§4.3 (T04, binding addendum — sibling-host mirror migration) —
  adds the identity spine's THIRD org-less resource to the demo host's
  Identity mount: `Identity.Session` (a revocable, DB-backed login session).
  Mirrors `samen_web/priv/repo/migrations/20260721040000_mount_identity_session.exs`
  exactly, adapted to demo's abbrevs (`ses`, the DEFAULT — demo's Identity
  mount passes no `abbrevs:` override, so `Samen.Scopes.Identity.default_abbrevs/0`
  supplies `session: "ses"`; the registry already carries this as the permanent
  host row `hosts.demo.ses`, reserved by T03's `mix samen.abbrev.reserve`).

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

  @resources [Demo.Identity.Session]

  def up do
    create table(:ses_session, primary_key: false) do
      add(:ses_token_digest, :text, null: false)
      add(:ses_last_seen_at, :utc_datetime)
      add(:ses_expires_at, :utc_datetime, null: false)
      add(:ses_revoked_at, :utc_datetime)
      add(:ses_device_label, :text)

      add(
        :ses_credential_id,
        references(:crd_credential,
          column: :crd_id,
          name: "ses_session_ses_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:ses_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ses_org_id, :uuid)
      add(:ses_inserted_at, :utc_datetime, null: false)
      add(:ses_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:ses_session, [:ses_token_digest]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:ses_session, "ses_session_ses_credential_id_fkey"))
    drop(table(:ses_session))
  end
end
