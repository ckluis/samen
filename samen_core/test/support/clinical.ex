defmodule Core.Person do
  @moduledoc """
  The SHARED base fragment (doc §core `Core.Person` block).

  A `Spark.Dsl.Fragment` of `Ash.Resource` — a tableless bundle of shared
  attributes and PII routing, NO data layer and NO table of its own. It declares
  the extensions whose DSL it uses. Folded into a composed resource via
  `use Samen.Resource, base: Core.Person`; its attributes and PII columns become
  columns of that resource, prefixed with the resource's abbrev.
  """
  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Catalog]

  attributes do
    attribute(:job_title, :string, public?: true)
  end

  pii do
    # Vaults declared here fold into every composing resource. Composite types
    # route by vault name (abbrev prefix, NO pii_ column prefix): per_full_name.
    vault(:pii_name)
    vault(:pii_email)
    vault(:pii_phone)

    pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
    pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)
    pii_attribute(:phones, Samen.Type.Phones, vault: :pii_phone)
  end
end

defmodule SamenCore.Support.Clinical do
  @moduledoc "Kernel test fixture domain: two resources composed over one fragment."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.Clinical.Patient)
    resource(SamenCore.Support.Clinical.Staff)
  end
end

defmodule SamenCore.Support.Clinical.Staff do
  @moduledoc """
  A composed resource (`abbrev: "stf"`) that folds in `Core.Person`. FK *target*
  for Patient's `primary_provider` — a real composed table, never the fragment.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Clinical,
    data_layer: AshPostgres.DataLayer,
    abbrev: "stf",
    base: Core.Person

  postgres do
    table("stf_staff")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:license_no, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule SamenCore.Support.Clinical.Patient do
  @moduledoc """
  A composed resource (`abbrev: "pat"`) folding in `Core.Person` → ONE table
  `pat_patient`. Folded-in columns inherit `pat_*`; adds its own PII + a
  `belongs_to :primary_provider, Staff` targeting the `stf_staff` table.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Clinical,
    data_layer: AshPostgres.DataLayer,
    abbrev: "pat",
    base: Core.Person

  postgres do
    table("pat_patient")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:consent_on_file, :boolean, public?: true, default: false)
  end

  pii do
    # Scalar pii_attributes carry the pii_ prefix: pii_pat_dob, pii_pat_mrn.
    vault(:pii_dob)
    vault(:pii_mrn)

    pii_attribute(:dob, :date, vault: :pii_dob)
    pii_attribute(:mrn, :string, vault: :pii_mrn)
  end

  relationships do
    belongs_to :primary_provider, SamenCore.Support.Clinical.Staff do
      public?(true)
      attribute_type(:uuid)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
