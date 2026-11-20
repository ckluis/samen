defmodule SamenCore.Support.UnreadableApproval do
  @moduledoc """
  Test fixture: an approval resource whose table does not exist, so every read is a REAL database error
  (`undefined_table`) — the shape a dropped table, a revoked grant or a lost connection takes. It lets a test prove
  that the approvals engine answers an unreadable approval store with `{:error, :unavailable}` instead of "no such
  approval" / "no pending approval". Wire it through `config :samen_core, Samen.Approvals, approval_resource: …`.

  Deliberately NOT in `:ash_domains` (like `SamenCore.Support.ApprovalsFixture`).
  """
  use Ash.Resource, domain: SamenCore.Support.UnreadableApproval.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "zz_no_such_approval_table"
    repo SamenCore.TestRepo
  end

  attributes do
    uuid_primary_key :id
    attribute :state, :atom, public?: true
    attribute :kind, :string, public?: true
    attribute :subject_ref, :string, public?: true
    attribute :org_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule SamenCore.Support.UnreadableApproval.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.UnreadableApproval)
  end
end
