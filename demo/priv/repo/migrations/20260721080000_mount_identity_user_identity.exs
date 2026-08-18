defmodule Demo.Repo.Migrations.MountIdentityUserIdentity do
  @moduledoc """
  ADR-035 §3.1/§5 A6 (T06, sibling-host mirror migration) — adds the identity
  spine's FOURTH org-less resource to the demo host's Identity mount:
  `Identity.UserIdentity` (the SSO link binding an external IdP subject —
  `provider` + opaque `provider_uid` — to a `Credential`). Mirrors
  `samen_web/priv/repo/migrations/20260721080000_mount_identity_user_identity.exs`
  exactly, adapted to demo's abbrevs (`uid`, the DEFAULT — demo's Identity mount
  passes no `abbrevs:` override, so `Samen.Scopes.Identity.default_abbrevs/0`
  supplies `user_identity: "uid"`; the registry carries the permanent host row
  `hosts.demo.uid`, reserved by T06's `mix samen.abbrev.reserve`).

  Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  No PII here: `provider` is a bounded name and `provider_uid` is an IdP-scoped
  opaque handle — the IdP-asserted email is used only transiently for a bidx
  lookup at link time and, on JIT signup, vaulted on the `usr_user` row; it is
  NEVER persisted on this table (INV-1).
  """
  use Samen.Migration

  @resources [Demo.Identity.UserIdentity]

  def up do
    create table(:uid_user_identity, primary_key: false) do
      add(:uid_provider, :text, null: false)
      add(:uid_provider_uid, :text, null: false)
      add(:uid_linked_at, :utc_datetime, null: false)

      add(
        :uid_credential_id,
        references(:crd_credential,
          column: :crd_id,
          name: "uid_user_identity_uid_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:uid_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:uid_org_id, :uuid)
      add(:uid_inserted_at, :utc_datetime, null: false)
      add(:uid_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:uid_user_identity, [:uid_provider, :uid_provider_uid]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:uid_user_identity, "uid_user_identity_uid_credential_id_fkey"))
    drop(table(:uid_user_identity))
  end
end
