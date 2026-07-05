defmodule S04CatalogTx.Crm.Contact do
  @moduledoc """
  Spike resource, `abbrev: "com"`. Its columns are what the migration test adds
  and what the catalog rows must mirror:

    * `:name`   → stored `com_name`
    * `:org_id` → stored `com_org_id`
    * `:phone`  → stored `com_phone`  (added by the AddPhone migration in the test)
  """
  use Samen.Resource,
    otp_app: :s04_catalog_tx,
    domain: S04CatalogTx.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "com"

  postgres do
    table("com_contact")
    repo(S04CatalogTx.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:phone, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
