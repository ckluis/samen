defmodule SamenCore.Support.UnreadableFlag do
  @moduledoc """
  Test fixture: a feature-flag resource (`name`, `org_id`) whose table does not exist, so every read is a REAL database
  error (`undefined_table`). It lets a test prove that `Samen.FeatureFlags` reports a flag it could not LOAD, rather than
  letting it read as an ordinary killed flag. Deliberately NOT in `:ash_domains`.
  """
  use Ash.Resource, domain: SamenCore.Support.UnreadableFlag.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "zz_no_such_flag_table"
    repo SamenCore.TestRepo
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :org_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule SamenCore.Support.UnreadableFlag.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.UnreadableFlag)
  end
end
