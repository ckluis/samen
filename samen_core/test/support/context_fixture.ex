defmodule Core.Ctx do
  @moduledoc """
  Toy KERNEL domain for the `Samen.Context` bounded-context DSL tests (T3.10).

  Mirrors the vision doc's `Lumen.Context` example (doc §core `Lumen.Context`
  block): a kernel `Activity`-like resource that a vertical re-identifies as
  `Encounter`, and a kernel `Invoice`-like resource whose money the vertical
  reshapes into `patient_responsibility + payer_claim`.

  These are ordinary `use Samen.Resource` kernel resources — org-scoped, vault-
  routed PII, audit-writing — exactly so the tests can prove the inherited
  plumbing rides underneath a context UNCHANGED.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Core.Ctx.Activity)
    resource(Core.Ctx.Invoice)
  end
end

defmodule Core.Ctx.Activity do
  @moduledoc """
  Kernel `Activity`-like resource (aliased as `Encounter` by the toy context).

  Org-scoped (the `OrgScope` FilterCheck) and carries ONE vault-routed PII field
  (`attendee_note` → `:pii_note`) so the alias tests can prove masking still fires
  underneath the vertical's rename. No reveal action — a plain `pii_attribute`
  masks by default.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Core.Ctx,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cea"

  postgres do
    table("cea_activity")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:kind, :atom,
      public?: true,
      allow_nil?: false,
      default: :visit,
      constraints: [one_of: [:visit, :call, :note]]
    )

    attribute(:subject, :string, public?: true)
  end

  pii do
    vault(:pii_note)
    pii_attribute(:attendee_note, :string, vault: :pii_note)
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

defmodule Core.Ctx.Invoice do
  @moduledoc """
  Kernel `Invoice`-like resource (reshaped by the toy context: one charge split
  into `patient_responsibility + payer_claim`).

  Money columns are `:decimal`: `total` (invoice gross) and `covered_amount`
  (payer-covered portion). The reshape reads these existing columns and computes
  the split — it declares NO new column. Org-scoped.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Core.Ctx,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cei"

  postgres do
    table("cei_invoice")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:total, :decimal, public?: true, allow_nil?: false)
    attribute(:covered_amount, :decimal, public?: true, allow_nil?: false, default: Decimal.new(0))
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

defmodule Ctx.Toy do
  @moduledoc """
  The toy bounded context (T3.10) mirroring the vision doc's `Lumen.Context`:

    * `alias_resource Core.Ctx.Activity, as: Ctx.Toy.Encounter` — re-identify the
      kernel Activity as the vertical's Encounter.
    * `reshape Core.Ctx.Invoice` — split the kernel invoice charge into
      `patient_responsibility` (`total - covered_amount`) and `payer_claim`
      (`covered_amount`), the doc's exact money reshape.

  The inherited plumbing (vault · catalog · org-scope · audit · crypto-shred)
  stays underneath the kernel resources UNCHANGED — only the ubiquitous language
  is translated.
  """
  use Samen.Context

  context do
    domain(Core.Ctx)

    alias_resource(Core.Ctx.Activity, as: Ctx.Toy.Encounter)

    reshape Core.Ctx.Invoice do
      calculate(:patient_responsibility, :money, expr(total - covered_amount))
      calculate(:payer_claim, :money, expr(covered_amount))
    end
  end
end
