defmodule Clinical.Patient do
  @moduledoc """
  A composed resource (`abbrev: "pat"`) that folds in `Core.Person` (doc §core
  `Lumen.Patient` block).

  `base: Core.Person` folds the shared attributes + `pii` section into ONE
  resource → ONE physical table `pat_patient`. The folded-in columns inherit the
  `pat` abbrev (`pat_full_name`, `pat_job_title`, ...). It adds its own domain
  attributes/PII and a `belongs_to :primary_provider, Clinical.Staff` — the FK
  targets the Staff **table** (`stf_staff` / `stf_id`), a real composed resource,
  never the fragment.
  """
  use Samen.Resource,
    otp_app: :s03_fragments,
    domain: S03Fragments.Clinical,
    data_layer: AshPostgres.DataLayer,
    abbrev: "pat",
    base: Core.Person

  postgres do
    table("pat_patient")
    repo(S03Fragments.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:consent_on_file, :boolean, public?: true, default: false)
  end

  pii do
    pii_attribute(:dob, :date, vault: :pii_dob)
    pii_attribute(:mrn, :string, vault: :pii_mrn)
  end

  relationships do
    belongs_to :primary_provider, Clinical.Staff do
      public?(true)
      attribute_type(:uuid)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
