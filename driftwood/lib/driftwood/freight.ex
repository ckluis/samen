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
  # F1 (Gate-5 carry) — the versioned public API surface over freight. `AshJsonApi.Domain`
  # makes this domain routable (it generates the `json_api_match_route/2` dispatcher the
  # AshJsonApi controller calls). Safe here exactly as in `Demo.Crm`: the Freight resources
  # are top-level `defmodule`s (not nested in this module body), so the domain's `json_api/1`
  # macro import does not collide with the resource-level `json_api/1` on Driver /
  # DispatchEvent. Only Driver + DispatchEvent carry a resource `json_api` block.
  use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]

  resources do
    resource(Driftwood.Freight.Driver)
    resource(Driftwood.Freight.Settlement)
    resource(Driftwood.Freight.DispatchEvent)
    # F1 — the two-key-class credential the public API auth resolver reads (dak_api_key).
    resource(Driftwood.Freight.ApiKey)
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
    extensions: [AshJsonApi.Resource],
    abbrev: "drv",
    base: Samen.Fragments.CorePerson

  postgres do
    table("drv_driver")
    repo(Driftwood.Repo)
  end

  # F1 (Gate-5 carry) — the public API surface over the PII-bearing Driver.
  #
  # ALLOWLIST (opt-in, default not-exposed). `show_fields` is the load-bearing control:
  # a field NOT named here is ABSENT from every payload (JSON:API + webhook), even via
  # `?fields=`. The names are CATALOG names (`:cdl_number`, `:full_name`, `:cdl_state`) —
  # NEVER storage names (`pii_drv_cdl_number`, `drv_full_name`). What marks
  # `cdl_number`/`full_name` as PII is their vault routing (the `pii do` below), not any
  # `pii_`/`drv_` prefix. Those vault fields serialize `••••` (masked) on the operator
  # plane WITHOUT a grant they are ABSENT; on the tenant plane they read in CLEAR.
  # Deliberately NOT allowlisted: `org_id` (internal routing — absent by omission) and
  # `custom` (the Tier-1 bag — never auto-published).
  json_api do
    type("driver")
    show_fields([
      :id,
      :cdl_state,
      :cdl_expiry,
      :medical_card_expiry,
      :status,
      :eld_provider,
      :full_name,
      :cdl_number
    ])

    # F3.7 — make the FILTER surface match the SERIALIZATION surface: a `?filter[org_id]`
    # side channel over a de-allowlisted field is closed by turning derive_filter? off
    # (cross-org is already defended by OrgScope; this closes the same-org residual).
    derive_filter?(false)

    routes do
      base("/drivers")
      # Bounded-by-default API read (WS-A design §1.1, ADR-016 §3): keyset pagination,
      # default_limit 50 / max_page_size 200 — no-page index reads are bounded; an
      # over-max page[limit] is clamped.
      get(:api_read)
      index(:api_read)
    end
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

  # F1 (Gate-5 carry) — the two-key-classes PII-resolution rule on all reads (the SAME
  # `Samen.Api.PiiResolution` the tenant console F2 uses). Inert for plane-less internal
  # reads (leaves `%Masked{}` → ••••); on the API a `:tenant` key reads its own org's
  # CDL/name in CLEAR, and an `:operator` key sees `%Ash.ForbiddenField{}` (ABSENT)
  # without a live reveal grant. One read path serves the UI, the API, and the webhook.
  preparations do
    prepare(Samen.Api.PiiResolution)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # Bounded-by-default API read the JSON:API routes bind to (WS-A design §1.1,
    # ADR-016 §3). PII resolves per plane via the resource-level PiiResolution prep.
    read :api_read do
      pagination(
        keyset?: true,
        default_limit: 50,
        max_page_size: 200,
        required?: false,
        paginate_by_default?: true
      )
    end

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
    extensions: [AshJsonApi.Resource],
    abbrev: "dsp"

  postgres do
    table("dsp_dispatch_event")
    repo(Driftwood.Repo)
  end

  # F1 (Gate-5 carry) — a load-status event IS the subject of the `load.status` webhook
  # (a dispatch's status: dispatched/in_transit/delivered/cancelled). This resource is
  # non-PII, so its allowlisted payload proves the opt-in / storage-name / custom-bag
  # controls on a freight event WITHOUT any decrypt: `status`, `dispatched_at`, and the
  # FK ids are catalog names; `org_id` and the `custom` bag are ABSENT by omission.
  json_api do
    type("dispatch_event")
    show_fields([:id, :status, :dispatched_at, :driver_id, :load_id])
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

# ---------------------------------------------------------------------------
# ApiKey — F1 (Gate-5 carry). The two-key-class credential the public `/api/v1` auth
# resolver reads. Bound to ONE plane (:tenant | :operator) and its org. Mirrors the
# Identity-scope ApiKey shape (samen_core blueprint) but is self-contained on the
# freight vertical (no Identity mount — driftwood keeps its resource surface small).
# ---------------------------------------------------------------------------
defmodule Driftwood.Freight.ApiKey do
  @moduledoc """
  A scoped API credential (doc §external-surface "two key classes"). Bound to one plane
  (`:tenant`/`:operator`) and its minting org. Its effective authority is `∩` the
  minter's role — a key can never out-reach its actor (`Samen.Scope.ApiKey.authorized?/4`).

  The `token_digest` column stores a SHA-256 digest of the key, never the key itself
  (the raw key is shown once at mint and never persisted in clear). It is a one-way
  digest — NOT PII, NOT vault-routed (a credential, not subject data), and `public?:
  false` so it is never catalogued/rendered.

  The `minter_user_id` is the id the built actor carries (so an audit of an API-driven
  action attributes to a real minter, not a synthetic user). Org-scoped like every
  tenant-plane resource.
  """
  use Samen.Resource,
    otp_app: :driftwood,
    domain: Driftwood.Freight,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dak"

  postgres do
    table("dak_api_key")
    repo(Driftwood.Repo)
  end

  attributes do
    # SHA-256 digest of the key material. One-way; the raw key is never stored.
    attribute(:token_digest, :string, public?: false, allow_nil?: false)

    attribute(:plane, :atom,
      public?: true,
      allow_nil?: false,
      default: :tenant,
      constraints: [one_of: [:tenant, :operator]]
    )

    # Declared scopes as a bounded map: %{family => [:read,:write]}. Effective authority
    # is the intersection with the minter's role at USE time.
    attribute(:scopes, :map, public?: true, default: %{})

    # The role of the minter — the actor ceiling this key inherits.
    attribute(:minter_role, :atom,
      public?: true,
      constraints: [one_of: Samen.Scope.Role.all()]
    )

    # The minter user id the built actor carries (attribution). Non-PII opaque id.
    attribute(:minter_user_id, :string, public?: true)

    attribute(:revoked_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Only admins+ may mint or revoke keys; org-scoped.
    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end
  end
end
