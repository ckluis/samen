defmodule SamenCore.Support.Crm do
  @moduledoc "Kernel test fixture domain: a plain (non-fragment) CRM scope."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.Crm.Contact)
    resource(SamenCore.Support.Crm.Company)
  end
end

defmodule SamenCore.Support.Crm.Company do
  @moduledoc "A plain Samen resource. FK *target* for Contact — proves prefixed FK references."
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "cpy"

  postgres do
    table("cpy_company")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule SamenCore.Support.Crm.Contact do
  @moduledoc """
  A plain Samen resource with a `belongs_to` to Company. Proves:

    * injected `id`/`org_id`/`inserted_at`/`updated_at` (all prefixed `com_*`);
    * user attributes prefixed (`com_name`);
    * the synthesized FK is prefixed AND targets the composed table
      (`com_company_id` -> `cpy_company.cpy_id`) — the S0.2 caveat-F1 ordering fix.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "com"

  postgres do
    table("com_contact")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :company, SamenCore.Support.Crm.Company do
      public?(true)
      attribute_type(:uuid)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
