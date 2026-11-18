defmodule SamenCore.Support.UnreadableSend do
  @moduledoc """
  Test fixture: a send resource (`provider_message_id`, `org_id`, `subscriber_id`, `enrollment_id`) whose table does not
  exist, so every read is a REAL database error (`undefined_table`). It lets a test prove that a receipt lookup answers
  an unreadable send store with `{:error, :unavailable}` instead of `:not_found` ("no such send").

  Deliberately NOT in `:ash_domains` (like `SamenCore.Support.UnreadableApproval`).
  """
  use Ash.Resource, domain: SamenCore.Support.UnreadableSend.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "zz_no_such_send_table"
    repo SamenCore.TestRepo
  end

  attributes do
    uuid_primary_key :id
    attribute :provider_message_id, :string, public?: true
    attribute :org_id, :uuid, public?: true
    attribute :subscriber_id, :uuid, public?: true
    attribute :enrollment_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule SamenCore.Support.UnreadableSend.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.UnreadableSend)
  end
end
