defmodule SamenCore.Support.PropFixture do
  @moduledoc """
  Fixture for the T1.1 property test (round-trip create/read via logical names).
  Backed by Postgres so the round-trip exercises the real prefixed columns
  end-to-end (the abbrev transformer + injected columns + physical storage).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.PropDomain,
    data_layer: AshPostgres.DataLayer,
    abbrev: "prp"

  postgres do
    table("prp_fixture")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true)
    attribute(:label, :string, public?: true)
    attribute(:notes, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule SamenCore.Support.PropDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.PropFixture)
  end
end
