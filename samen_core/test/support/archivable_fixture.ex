defmodule SamenCore.Support.Archivable do
  @moduledoc """
  Kernel test-fixture domain for the E6 soft-delete substrate (ADR-040 §5, T36).

  Two pilots prove the `archivable true` convention (do NOT sweep the §5.9 roster —
  that is T37):

    * `Widget` — a plain (non-vaulted) resource with a **partial** unique index on
      `(org_id, code) WHERE archived_at IS NULL`, exercising archive/restore/idempotence,
      the default-read exclusion, and the `:restore_conflict` honest error.
    * `Person` — a **vaulted** (🔒) resource folding `Core.Person`, proving INV-1:
      an archived row still masks its vault fields per plane and a restore never leaks.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.Archivable.Widget)
    resource(SamenCore.Support.Archivable.Person)
  end
end

defmodule SamenCore.Support.Archivable.Widget do
  @moduledoc """
  Plain archivable pilot. The `code` slot has a partial unique index
  (`WHERE arv_archived_at IS NULL`, migration `t36_archivable_fixtures`) so an
  archived row frees the slot and `:restore` can hit `{:error, :restore_conflict}`.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Archivable,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "arv",
    archivable: true

  postgres do
    table("arv_widget")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:code, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  # OrgScope composes with the archival default filter (both are read FilterChecks,
  # ANDed): the `:archived` include-read is still org-scoped (T36 c3).
  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end

defmodule SamenCore.Support.Archivable.Person do
  @moduledoc """
  Vaulted archivable pilot (folds `Core.Person` → `avf_*` vault-token columns). Proves
  that archiving does not disturb per-plane masking (INV-1): the archived row's
  `full_name`/`emails`/`phones` stay tokenized and mask on the operator-without-grant
  plane, and restore does not leak.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Archivable,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "avf",
    base: Core.Person,
    archivable: true

  postgres do
    table("avf_person")
    repo(SamenCore.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
