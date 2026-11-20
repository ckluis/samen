defmodule Samen.WebTest.UnreadableMailRecord do
  @moduledoc """
  Test fixture: a CRM-shaped record (`org_id`, `emails`, `company_id`, `domain`) whose table does not exist, so every
  read is a REAL database error (`undefined_table`). Used as a mailbox `person_resource` / `company_resource` to prove
  that a failed CRM match read is never "no match".
  """
  use Ash.Resource, domain: Samen.WebTest.UnreadableMailRecord.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "zz_no_such_crm_table"
    repo Samen.WebTest.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :uuid, public?: true
    attribute :company_id, :uuid, public?: true
    attribute :domain, :string, public?: true
    attribute :emails, :map, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule Samen.WebTest.UnreadableMailRecord.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.WebTest.UnreadableMailRecord)
  end
end
