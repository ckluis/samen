defmodule SamenCore.Support.Completeness.Domain do
  @moduledoc """
  Kernel test-fixture domain for the ADR-046 §6 erasure-completeness verifier.

  Deliberately NOT in `:ash_domains` — these plain Ash resources exist only to be passed
  EXPLICITLY to `Samen.Erasure.Completeness.check/1` (`:resources`) so the discovery +
  coverage logic is exercised against a controlled, deterministic residue set (never the
  CI verifier/catalog sweeps). Physical column sources are hand-prefixed (`cpc_*`, `atc_*`,
  `fil_*`, `med_*`) to mirror the abbrev-prefixing a real `use Samen.Resource` applies, so
  the test proves discovery resolves PHYSICAL columns (not logical names).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.Completeness.Credential)
    resource(SamenCore.Support.Completeness.AuthToken)
    resource(SamenCore.Support.Completeness.File)
    resource(SamenCore.Support.Completeness.Attachment)
    resource(SamenCore.Support.Completeness.OrgAsset)
    resource(SamenCore.Support.Completeness.Bag)
    resource(SamenCore.Support.Completeness.RogueBidx)
  end
end

defmodule SamenCore.Support.Completeness.Credential do
  @moduledoc "Derived-linkable fixture: `email_bidx` owned by the row's own pk (`:id`)."
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("cpc_credential")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :cpc_id)
    attribute(:email_bidx, :string, public?: false, source: :cpc_email_bidx)
  end

  actions do
    defaults([:read])
  end
end

defmodule SamenCore.Support.Completeness.AuthToken do
  @moduledoc "Derived-linkable fixture: `sent_to_bidx` owned by the `:credential_id` principal."
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("atc_auth_token")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :atc_id)
    attribute(:credential_id, :uuid, public?: false, source: :atc_credential_id)
    attribute(:sent_to_bidx, :string, public?: false, source: :atc_sent_to_bidx)
  end

  actions do
    defaults([:read])
  end
end

defmodule SamenCore.Support.Completeness.File do
  @moduledoc "storage_key fixture: subject-linked (carries `uploaded_by_id`)."
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("fil_file")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :fil_id)
    attribute(:storage_key, :string, public?: true, allow_nil?: false, source: :fil_storage_key)
    attribute(:uploaded_by_id, :uuid, public?: true, source: :fil_uploaded_by_id)
  end

  actions do
    defaults([:read])
  end
end

defmodule SamenCore.Support.Completeness.Attachment do
  @moduledoc """
  storage_key fixture: subject-linked via a DOMAIN subject-FK (`person_id`) — a blob
  *ABOUT* a data subject (e.g. a person's scanned ID / signed contract), NOT one uploaded
  BY them. The completeness gate must treat this as subject-linked (GATED, requiring a
  `:file_erasure_specs` arm keyed on `:person_id`), the ADR-046 §7 #5 reach.
  """
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("ath_attachment")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :ath_id)
    attribute(:storage_key, :string, public?: true, source: :ath_storage_key)
    attribute(:person_id, :uuid, public?: true, source: :ath_person_id)
    attribute(:org_id, :uuid, public?: true, source: :ath_org_id)
  end

  actions do
    defaults([:read])
  end
end

defmodule SamenCore.Support.Completeness.OrgAsset do
  @moduledoc "storage_key fixture: org-asset blob (NO data-subject field) — an org-lifecycle residual."
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("med_media")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :med_id)
    attribute(:storage_key, :string, public?: true, source: :med_storage_key)
    attribute(:org_id, :uuid, public?: true, source: :med_org_id)
  end

  actions do
    defaults([:read])
  end
end

defmodule SamenCore.Support.Completeness.Bag do
  @moduledoc "custom-bag fixture: a `public?: true` `:map` `:custom` bag column."
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("bag_widget")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :bag_id)
    attribute(:custom, :map, public?: true, source: :bag_custom)
  end

  actions do
    defaults([:read])
  end
end

defmodule SamenCore.Support.Completeness.RogueBidx do
  @moduledoc """
  A resource with a `_bidx`-shaped column that is NOT registered in
  `Samen.DerivedLinkable` — the structural backstop's target: discovery must FLAG it as
  an unregistered derived-linkable residue (a future blind index cannot ship silently).
  """
  use Ash.Resource, domain: SamenCore.Support.Completeness.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table("rog_rogue")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, source: :rog_id)
    attribute(:handle_bidx, :string, public?: false, source: :rog_handle_bidx)
  end

  actions do
    defaults([:read])
  end
end
