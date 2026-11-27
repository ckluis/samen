defmodule SamenCore.Support.CustomFields do
  @moduledoc """
  Kernel test-fixture domain for T3.8 Tier-1 custom fields — a resource that
  carries an `xxx_custom` jsonb bag so the validated-at-write change and the
  containment rules can be exercised against a real Postgres round-trip.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.CustomFields.Widget)
  end
end

defmodule SamenCore.Support.CustomFields.Widget do
  @moduledoc """
  A plain Samen resource with a Tier-1 `:custom` jsonb bag (abbrev `tcf` →
  `tcf_custom`). Opting into the bag (declaring `attribute(:custom, :map)`) is
  what wires `Samen.CustomFields.Change` via
  `Samen.Transformers.MaterializeCustomFields`, so every bag write is
  validated-at-write against the org's `tnt_field` definitions.

  Org-scoped (the injected `org_id` core column is the tenant boundary the
  custom-field definitions are scoped to). No PII — the containment story is
  specifically that a PII-*shaped* value in a plain custom field is rejected, so
  the fixture has no `pii do` block.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.CustomFields,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "tcf"

  postgres do
    table("tcf_widget")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    # Tier-1 custom bag — opt-in. Its presence wires the validated-at-write change.
    attribute(:custom, :map, public?: true)
  end

  # ARCH-26: a reveal action and nothing else (still no vaulted field) — so the pii_declared bag key's
  # operator-WITH-a-grant posture can be exercised (`pii_resolution_bag_planes_test.exs`). Without a declared
  # reveal action `PiiResolution` can never grant a reveal, whatever the checker says.
  pii do
    reveal(:reveal_widget)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    action :reveal_widget, :map do
      argument(:subject_id, :string, allow_nil?: false)

      run({Samen.Reveal.GrantProbe, label: :widget})
    end
  end

  policies do
    # test fixture: the CRUD actions stay as open as they were before the probe rule needed an authorizer
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(always())
    end

    policy action(:reveal_widget) do
      authorize_if(actor_present())
    end
  end
end
