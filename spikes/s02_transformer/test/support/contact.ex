defmodule S02Transformer.Crm.Contact do
  @moduledoc """
  Primary spike resource. `abbrev: "com"`:

    * `attribute :name`   → stored column `com_name`
    * `attribute :org_id` → stored column `com_org_id`
    * `belongs_to :company` → FK attribute `company_id` → stored `com_company_id`,
      referencing Company's prefixed primary key `cpy_id`.

  App code addresses everything by the logical name (:name, :org_id, :company_id);
  only storage carries the prefix.
  """
  use Samen.Resource,
    otp_app: :s02_transformer,
    domain: S02Transformer.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "com"

  postgres do
    table("com_contact")
    repo(S02Transformer.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :company, S02Transformer.Crm.Company do
      public?(true)
      attribute_type(:uuid)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
