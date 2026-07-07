defmodule SamenCore.Support.SameOrgFkFixture do
  @moduledoc """
  Test fixture domain for the F3.5 `same_org_fk` verifier
  (`Mix.Tasks.Samen.Verify.SameOrgFk`).

  This domain is NOT registered in the global `:ash_domains` — the verifier's
  red-path test passes it explicitly via `violations(domain: __MODULE__)`, so the
  seeded violation never fails the real CI sweep.

  Four resources, chosen to exercise every branch of the verifier:

    * `Parent` — an org-scoped target with an `org_id` (a valid same-org FK target).
    * `Guarded` — org-scoped, `belongs_to :parent`, WITH a `SameOrgFk` change.
      MUST NOT be flagged (positive control — proves the check is not always-fail).
    * `Unguarded` — org-scoped, `belongs_to :parent`, NO `SameOrgFk` change.
      MUST be flagged (the red path — an unguarded org-scoped FK).
    * `NotOrgScoped` — has a `belongs_to :parent` but NO `OrgScope` policy.
      MUST NOT be flagged (not a tenant-plane org-scoped resource).

  The org-less-target branch is covered separately in the task test by pointing an
  FK at an org-less anchor.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.SameOrgFkFixture.Parent)
    resource(SamenCore.Support.SameOrgFkFixture.Guarded)
    resource(SamenCore.Support.SameOrgFkFixture.Unguarded)
    resource(SamenCore.Support.SameOrgFkFixture.NotOrgScoped)
  end
end

defmodule SamenCore.Support.SameOrgFkFixture.Parent do
  @moduledoc "An org-scoped FK target (has org_id)."
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.SameOrgFkFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sfp"

  postgres do
    table("sfp_parent")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end

defmodule SamenCore.Support.SameOrgFkFixture.Guarded do
  @moduledoc "Org-scoped, belongs_to :parent, WITH SameOrgFk. Must not be flagged."
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.SameOrgFkFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sfg"

  postgres do
    table("sfg_guarded")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true)
  end

  relationships do
    belongs_to :parent, SamenCore.Support.SameOrgFkFixture.Parent do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end
  end

  changes do
    change({Samen.Policy.SameOrgFk, relationships: [:parent]})
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end

defmodule SamenCore.Support.SameOrgFkFixture.Unguarded do
  @moduledoc "Org-scoped, belongs_to :parent, NO SameOrgFk. The red path — must be flagged."
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.SameOrgFkFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sfu"

  postgres do
    table("sfu_unguarded")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true)
  end

  relationships do
    belongs_to :parent, SamenCore.Support.SameOrgFkFixture.Parent do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end

defmodule SamenCore.Support.SameOrgFkFixture.NotOrgScoped do
  @moduledoc """
  Has a belongs_to :parent but NO OrgScope policy — an operator-plane-style
  resource. Must NOT be flagged (the same-org-FK idiom is a tenant-plane rule).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.SameOrgFkFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sfn"

  postgres do
    table("sfn_not_org_scoped")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true)
  end

  relationships do
    belongs_to :parent, SamenCore.Support.SameOrgFkFixture.Parent do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    # A non-OrgScope policy — this resource is not tenant-plane org-scoped.
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(always())
    end
  end
end
