defmodule Clinical.Staff do
  @moduledoc """
  A composed resource (`abbrev: "stf"`) that folds in `Core.Person`.

  Proves the fragment composes into more than one shape: the same shared
  attributes (`job_title`, `custom`) and PII columns (`full_name`, `emails`,
  `phones`) land here as `stf_*` (a different prefix from Patient's `pat_*`),
  from ONE fragment. It is the FK *target* for Patient's `primary_provider`, so
  it must be a real, queryable resource with its own `stf_staff` table — never
  the fragment.
  """
  use Samen.Resource,
    otp_app: :s03_fragments,
    domain: S03Fragments.Clinical,
    data_layer: AshPostgres.DataLayer,
    abbrev: "stf",
    base: Core.Person

  postgres do
    table("stf_staff")
    repo(S03Fragments.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:license_no, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
