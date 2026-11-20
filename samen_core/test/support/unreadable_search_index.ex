defmodule SamenCore.Support.UnreadableSearchIndex do
  @moduledoc """
  Test fixture: a search-index registry resource (`org_id`, `resource_name`, `field_name`, `enabled`) whose table does not
  exist, so every read is a REAL database error (`undefined_table`). It lets a test prove that `Samen.Search.query/3`
  does not answer an unreadable registry with `[]` ("nothing is searchable"). Deliberately NOT in `:ash_domains`.
  """
  use Ash.Resource, domain: SamenCore.Support.UnreadableSearchIndex.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "zz_no_such_search_index_table"
    repo SamenCore.TestRepo
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :uuid, public?: true
    attribute :resource_name, :string, public?: true
    attribute :field_name, :string, public?: true
    attribute :enabled, :boolean, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule SamenCore.Support.UnreadableSearchIndex.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.UnreadableSearchIndex)
  end
end
