defmodule SamenCore.Support.PiiClassifyDomain do
  @moduledoc "Test domain for T1.8c pii_classify fixture resources."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.PiiClassify.PersonRecord)
  end
end

defmodule SamenCore.Support.PiiClassify.PersonRecord do
  @moduledoc """
  Fixture resource for T1.8c (`pii_classify`) verifier tests.

  Uses `Samen.Resource` with AshPostgres so that `AshPostgres.DataLayer.Info.table/1`
  and `Ash.Resource.Info.attributes/1` work correctly.

  Attributes:
    * `:ssn`        — RED PATH: identifier-shape name match
    * `:email_addr` — RED PATH: identifier-shape name match on "email"
    * `:mobile`     — RED PATH: identifier-shape name match on "mobile"
    * `:dob`        — RED PATH: identifier-shape name match, but ONLY when NOT in pii do
    * `:notes`      — GREEN PATH: safe plain string (not PII-named)
    * `:status`     — GREEN PATH: safe plain string

  All of these are plain `:string` or `:date` attributes with NO pii do block —
  the scanner should flag `:ssn`, `:email_addr`, `:mobile`, `:dob`.

  NOTE: `:dob` and `:mrn` are flagged on this resource because they are NOT
  in a `pii do` block here (unlike pat_patient which properly vaults them).
  This is intentional — it proves the scanner detects them on un-vaulted resources.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.PiiClassifyDomain,
    data_layer: AshPostgres.DataLayer,
    abbrev: "pcl"

  postgres do
    table("pcl_person_record")
    repo(SamenCore.TestRepo)
  end

  attributes do
    # RED PATH: these names match PII identifier patterns
    attribute(:ssn, :string, public?: true)
    attribute(:email_addr, :string, public?: true)
    attribute(:mobile, :string, public?: true)
    attribute(:dob, :date, public?: true)

    # GREEN PATH: safe plain strings (not PII-named)
    attribute(:notes, :string, public?: true)
    attribute(:status, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
