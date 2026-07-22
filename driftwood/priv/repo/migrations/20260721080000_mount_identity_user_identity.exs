defmodule Driftwood.Repo.Migrations.MountIdentityUserIdentity do
  @moduledoc """
  ADR-035 §3.1/§5 A6 (T06, sibling-host mirror migration) — adds the identity
  spine's FOURTH org-less resource to Driftwood's Operator Identity mount:
  `Identity.UserIdentity` (the SSO link binding an external IdP subject —
  `provider` + opaque `provider_uid` — to a `Credential`). Mirrors
  `samen_web/priv/repo/migrations/20260721080000_mount_identity_user_identity.exs`
  exactly, adapted to Driftwood's operator abbrevs (`doi`; the permanent host row
  `hosts.driftwood.doi` was reserved by T06's `mix samen.abbrev.reserve`).

  Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  No PII here: `provider` is a bounded name and `provider_uid` is an IdP-scoped
  opaque handle — the IdP-asserted email is used only transiently for a bidx
  lookup at link time and, on JIT signup, vaulted on the `dou_user` row; it is
  NEVER persisted on this table (INV-1).
  """
  use Samen.Migration

  @resources [Driftwood.Operator.UserIdentity]

  def up do
    create table(:doi_user_identity, primary_key: false) do
      add(:doi_provider, :text, null: false)
      add(:doi_provider_uid, :text, null: false)
      add(:doi_linked_at, :utc_datetime, null: false)

      add(
        :doi_credential_id,
        references(:doc_credential,
          column: :doc_id,
          name: "doi_user_identity_doi_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:doi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:doi_org_id, :uuid)
      add(:doi_inserted_at, :utc_datetime, null: false)
      add(:doi_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:doi_user_identity, [:doi_provider, :doi_provider_uid]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:doi_user_identity, "doi_user_identity_doi_credential_id_fkey"))
    drop(table(:doi_user_identity))
  end
end
