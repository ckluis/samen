defmodule S06Verify.Crm.Contact do
  @moduledoc """
  Spike resource, `abbrev: "com"`. Columns:

    * `:id`     → stored `com_id`
    * `:name`   → stored `com_name`
    * `:org_id` → stored `com_org_id`
    * `:email`  → stored `com_email`
  """
  use Samen.Resource,
    otp_app: :s06_verify,
    domain: S06Verify.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "com"

  postgres do
    table("com_contact")
    repo(S06Verify.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:email, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
