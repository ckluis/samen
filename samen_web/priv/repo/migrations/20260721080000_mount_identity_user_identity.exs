defmodule Samen.WebTest.Repo.Migrations.MountIdentityUserIdentity do
  @moduledoc """
  ADR-035 §3.1/§5 A6 (T06, the optional OIDC module) — adds the identity spine's
  FOURTH org-less resource to the samen_web test host's Operator Identity mount:
  `Identity.UserIdentity` (the SSO link binding an external IdP subject —
  `provider` + opaque `provider_uid` — to a `Credential`). The A6 link-to-existing
  and JIT-signup flows create rows here; the unique `(provider, provider_uid)`
  index makes one IdP subject map to at most one Credential.

  Fresh `woi` abbrev (append-only registry row, `mix samen.abbrev.reserve`).
  Catalogued in the SAME transaction (ADR-004 catalog-in-tx), mirroring
  `20260721040000_mount_identity_session.exs`.

  No PII here: `provider` is a bounded name and `provider_uid` is an IdP-scoped
  opaque handle (never an email/name) — the IdP-asserted email is used only
  transiently for a bidx lookup at link time and, on JIT signup, vaulted on the
  `wou_user` row; it is NEVER persisted on this table (INV-1).
  """
  use Samen.Migration

  @resources [Samen.WebTest.Operator.UserIdentity]

  def up do
    create table(:woi_user_identity, primary_key: false) do
      add(:woi_provider, :text, null: false)
      add(:woi_provider_uid, :text, null: false)
      add(:woi_linked_at, :utc_datetime, null: false)

      add(
        :woi_credential_id,
        references(:woc_credential,
          column: :woc_id,
          name: "woi_user_identity_woi_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:woi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:woi_org_id, :uuid)
      add(:woi_inserted_at, :utc_datetime, null: false)
      add(:woi_updated_at, :utc_datetime, null: false)
    end

    # ADR-035 §5 A6 — one external IdP subject maps to at most one Credential.
    create(unique_index(:woi_user_identity, [:woi_provider, :woi_provider_uid]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:woi_user_identity, "woi_user_identity_woi_credential_id_fkey"))
    drop(table(:woi_user_identity))
  end
end
