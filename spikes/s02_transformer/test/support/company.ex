defmodule S02Transformer.Crm.Company do
  @moduledoc """
  Second resource, used to prove identities + FK naming survive the abbrev
  source override.

    * `abbrev: "cpy"` → columns cpy_id, cpy_org_id, cpy_slug, cpy_name
    * an identity on `[:org_id, :slug]` (logical names) must resolve to a
      unique index over the *prefixed* columns (cpy_org_id, cpy_slug).
  """
  use Samen.Resource,
    otp_app: :s02_transformer,
    domain: S02Transformer.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "cpy"

  postgres do
    table("cpy_company")
    repo(S02Transformer.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true, allow_nil?: false)
    attribute(:name, :string, public?: true)
  end

  identities do
    identity(:unique_slug_per_org, [:org_id, :slug])
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
