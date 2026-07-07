defmodule Driftwood.Freight do
  @moduledoc """
  Driftwood's Freight domain — the VERTICAL-authored resources with no kernel
  analogue (design §1.2, §1.5, §3.2, §1.4):

    * `Driftwood.Freight.Driver`        — composes `Samen.Fragments.CorePerson`
      (name/emails/phones vault) + the scalar vault field `pii_drv_cdl_number`
      + non-PII CDL/medical dates + the ELD provider (Tier-0 enum).
    * `Driftwood.Freight.Settlement`    — the carrier-settlement inputs stored as
      typed integer-cents columns. `Driftwood.Context` reshapes it into the netting
      calcs (gross / factoring_fee / net_payable / carryover).
    * `Driftwood.Freight.DispatchEvent` — the FMCSA-gated dispatch action (assigning
      a Driver to a Load). The `Driftwood.Policy.FmcsaDispatchGate` `before_action`
      change refuses an expired-CDL / expired-medical / out-of-service driver.

  These are all Tier-3 code composition: the substrate correctly refuses to let an
  `alias_resource` rename or a `reshape` mint storage, a relationship, or a
  validation, so the new nouns and the compliance gate are authored domain code.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Driftwood.Freight.Driver)
    resource(Driftwood.Freight.Settlement)
    resource(Driftwood.Freight.DispatchEvent)
  end
end

# ---------------------------------------------------------------------------
# Driver — composes CorePerson (single-table) + CDL/medical PII + Tier-0 ELD.
# design DECISION D (§1.5). pii_drv_cdl_number is the scalar vault field.
# ---------------------------------------------------------------------------
defmodule Driftwood.Freight.Driver do
  @moduledoc """
  A freight DRIVER. `use Samen.Resource, base: Samen.Fragments.CorePerson` folds the
  nine core-person columns (full_name/emails/phones vault-routed, job_title, custom,
  id/org_id/timestamps) into ONE physical table `drv_driver`, and adds the
  driver-specific fields:

    * `pii_drv_cdl_number` — the CDL number, the scalar `pii_` vault field
      (`pii_attribute :cdl_number, :string, vault: :pii_cdl`). Masked `••••` by
      default; plaintext only via `:reveal_driver` under a distinct-party grant.
    * `cdl_state`, `cdl_expiry`, `medical_card_expiry` — non-PII plain columns (a US
      state code + expiry dates are not subject-identifying alone). `cdl_state` and
      `cdl_expiry` trip `pii_classify`'s `cdl` name heuristic and are cleared via a
      reviewed `non_pii!` (design OR-2; `Driftwood.Freight.NonPiiSetup`).
    * `eld_provider` — a Tier-0 config enum (samsara/motive/geotab/other).
    * `status` — available/on_load/out_of_service/terminated (the FMCSA gate refuses
      out_of_service / terminated).
    * `carrier` — a `belongs_to` FK → the composed Company table (`fcm_company`),
      guarded by `Samen.Policy.SameOrgFk`.
  """
  use Samen.Resource,
    otp_app: :driftwood,
    domain: Driftwood.Freight,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "drv",
    base: Samen.Fragments.CorePerson

  postgres do
    table("drv_driver")
    repo(Driftwood.Repo)
  end

  attributes do
    attribute(:cdl_state, :string, public?: true)
    # cdl_expiry is stored as ISO-8601 TEXT (not :date): it is a reviewed non_pii!
    # column (its name trips pii_classify's `cdl` heuristic), and the substrate's
    # non_pii redaction arm writes a TEXT sentinel over the plaintext on a
    # driver-erasure request — which only works against a text-typed column. Storing
    # the CDL validity date as ISO text makes crypto-shred erase it end-to-end
    # (design §5). The FMCSA gate parses it via Date.from_iso8601/1 (design §4).
    attribute(:cdl_expiry, :string, public?: true)
    attribute(:medical_card_expiry, :date, public?: true)

    attribute(:eld_provider, :atom,
      public?: true,
      constraints: [one_of: [:samsara, :motive, :geotab, :other]]
    )

    attribute(:status, :atom,
      public?: true,
      default: :available,
      constraints: [one_of: [:available, :on_load, :out_of_service, :terminated]]
    )
  end

  pii do
    vault(:pii_cdl)
    # Scalar pii_ field → column pii_drv_cdl_number (abbrev-prefixed scalar rule).
    pii_attribute(:cdl_number, :string, vault: :pii_cdl)
    reveal(:reveal_driver)
  end

  relationships do
    belongs_to :carrier, Driftwood.Crm.Company do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end
  end

  # F3.5 same-org FK: a driver may only reference a same-org carrier.
  changes do
    change({Samen.Policy.SameOrgFk, relationships: [:carrier]})
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    action :reveal_driver, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: __MODULE__,
          action: :reveal_driver,
          label: :cdl_number
        }

        if Samen.Reveal.grant_checker().granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action(:reveal_driver) do
      authorize_if(always())
    end
  end
end

# ---------------------------------------------------------------------------
# Settlement — the carrier-settlement STORED inputs (typed integer cents).
# The netting math is a Driftwood.Context reshape over this (design DECISION S).
# ---------------------------------------------------------------------------
defmodule Driftwood.Freight.Settlement do
  @moduledoc """
  The carrier settlement: `net_payable = linehaul − advances − factoring_fee −
  claim deductions`, clamped at 0 with the shortfall booked as `carryover`
  (design §3, DECISION S + DECISION N).

  This resource STORES the settlement inputs as typed integer-cents columns (correct
  money — never float). The DERIVED netting fields (gross / factoring_fee /
  net_raw / net_payable / carryover) are added by `Driftwood.Context`'s
  `reshape Settlement` as `calculate … expr(...)` computed at query time — the
  substrate's anti-corruption layer (the doc's exact "reshape money" idiom). The
  kernel Billing Invoice stays UNCORRUPTED, used as-is for the shipper AR side.
  """
  use Samen.Resource,
    otp_app: :driftwood,
    domain: Driftwood.Freight,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "stl"

  postgres do
    table("stl_settlement")
    repo(Driftwood.Repo)
  end

  attributes do
    # Stored inputs (integer cents; factoring_rate_bps is basis points 0..10000).
    attribute(:linehaul_cents, :integer, public?: true, default: 0)
    attribute(:advances_cents, :integer, public?: true, default: 0)
    attribute(:fuel_surcharge_cents, :integer, public?: true, default: 0)
    attribute(:accessorial_cents, :integer, public?: true, default: 0)
    attribute(:claim_deduction_cents, :integer, public?: true, default: 0)
    attribute(:factoring_rate_bps, :integer, public?: true, default: 0)
    attribute(:currency, :string, public?: true, default: "USD")

    attribute(:status, :atom,
      public?: true,
      default: :draft,
      constraints: [one_of: [:draft, :approved, :paid]]
    )
  end

  relationships do
    belongs_to :load, Driftwood.Crm.Opportunity do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end

    belongs_to :carrier, Driftwood.Crm.Company do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end
  end

  changes do
    change({Samen.Policy.SameOrgFk, relationships: [:load, :carrier]})
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

# ---------------------------------------------------------------------------
# DispatchEvent — the FMCSA-gated dispatch action (Driver → Load). design DECISION A.
# ---------------------------------------------------------------------------
defmodule Driftwood.Freight.DispatchEvent do
  @moduledoc """
  Assigning a Driver to a Load — the FMCSA-gated action (design §1.4 DECISION A,
  §4 DECISION F). `Activity → CheckCall` (the routine event stream) is an
  `alias_resource` in `Driftwood.Context`; DISPATCH is authored domain code here
  because an alias/reshape cannot add the driver/load FKs or the compliance
  validation.

  The `:dispatch` create action runs `Driftwood.Policy.FmcsaDispatchGate` as a
  `before_action` change: it refuses when the driver's medical card or CDL is
  expired/missing, the CDL vault token is absent/shredded, or the driver is
  out_of_service/terminated. The ordinary OrgScope policy gates WHO may dispatch;
  the change is the load-bearing legality gate.
  """
  use Samen.Resource,
    otp_app: :driftwood,
    domain: Driftwood.Freight,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dsp"

  postgres do
    table("dsp_dispatch_event")
    repo(Driftwood.Repo)
  end

  attributes do
    attribute(:status, :atom,
      public?: true,
      default: :dispatched,
      constraints: [one_of: [:dispatched, :in_transit, :delivered, :cancelled]]
    )

    attribute(:dispatched_at, :utc_datetime, public?: true)
  end

  relationships do
    belongs_to :driver, Driftwood.Freight.Driver do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(false)
    end

    belongs_to :load, Driftwood.Crm.Opportunity do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(false)
    end
  end

  # Same-org FK guard on both FKs (a dispatch may only join a same-org driver+load).
  changes do
    change({Samen.Policy.SameOrgFk, relationships: [:driver, :load]})
  end

  actions do
    defaults([:read, :destroy, update: :*])

    # The FMCSA-gated dispatch action. The gate change refuses an illegal dispatch.
    # org_id is set from the acting scope (the actor's org) so the same-org-FK guard
    # and OrgScope have a tenant boundary to check against.
    create :dispatch do
      accept([:driver_id, :load_id, :status, :dispatched_at])
      change(set_attribute(:org_id, actor(:org_id)))
      change({Driftwood.Policy.FmcsaDispatchGate, []})
    end

    # A plain create WITHOUT the gate — used only to prove the gate is the thing
    # that refuses (a control), never used in the real dispatch workflow.
    create :create_ungated do
      accept([:driver_id, :load_id, :status, :dispatched_at])
      change(set_attribute(:org_id, actor(:org_id)))
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end
