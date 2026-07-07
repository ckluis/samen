defmodule Demo.Crm do
  @moduledoc """
  The Demo contact-manager domain (T1.9 dogfood).

  Uses every samen_core T1 feature:
    - base macro + abbrev transformer (self-qualifying storage)
    - catalog (tam_table / fld_field)
    - PII DSL: composite FullName/Emails + scalar pii_ field
    - vault round-trip (%Masked{} default + :reveal action + grant)
    - non_pii! reviewed plaintext column
    - crypto-shred
    - all 5 verifiers pass in CI gate
  """
  # T3.11 — AshJsonApi.Domain makes this domain routable (it generates the
  # `json_api_match_route/2` dispatcher the AshJsonApi controller calls). Safe here:
  # the CRM resources are top-level `defmodule`s (not nested in this module body), so
  # the domain's `json_api/1` macro import does not collide with the resource-level
  # `json_api/1` on Demo.Crm.Contact. Only Contact carries a resource `json_api` block.
  use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]

  resources do
    resource(Demo.Crm.Org)
    resource(Demo.Crm.Membership)
    resource(Demo.Crm.Contact)
  end
end

# ---------------------------------------------------------------------------
# Org: the tenant anchor. A plain Samen resource (no PII).
# ---------------------------------------------------------------------------
defmodule Demo.Crm.Org do
  @moduledoc "An organization (tenant anchor). Plain Samen resource — no PII."
  use Samen.Resource,
    otp_app: :demo,
    domain: Demo.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "org"

  postgres do
    table("org_org")
    repo(Demo.Repo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true)
    attribute(:plan, :string, public?: true, default: "free")
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

# ---------------------------------------------------------------------------
# Membership: joins an org and a contact. No PII.
# ---------------------------------------------------------------------------
defmodule Demo.Crm.Membership do
  @moduledoc "Membership: a contact belongs to an org. No PII."
  use Samen.Resource,
    otp_app: :demo,
    domain: Demo.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "mbr"

  postgres do
    table("mbr_membership")
    repo(Demo.Repo)
  end

  attributes do
    attribute(:role, :string, public?: true, default: "member")
    attribute(:status, :string, public?: true, default: "active")
  end

  relationships do
    belongs_to :contact, Demo.Crm.Contact do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(false)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

# ---------------------------------------------------------------------------
# Contact: the PII-bearing resource.
#
# Features exercised (T1.9):
#   - composite PII: FullName (pii_name vault) + Emails (pii_email vault)
#   - scalar pii_ field: dob → pii_cnt_dob (pii_dob vault)
#   - non_pii! reviewed column: :notes (plaintext-at-rest, raw DDL column)
#   - :reveal action declared first-class
#   - shred flow: Samen.Erasure.shred/2 erases the contact
# ---------------------------------------------------------------------------
defmodule Demo.Crm.Contact do
  @moduledoc """
  A contact with composite PII (FullName + Emails) and a scalar pii_ field (dob).

  The `cnt_notes` column is plaintext-at-rest by design (registered as a `non_pii!`
  override in the seed). The `:reveal_contact` action is the declared reveal entry
  point — the T1.9 LiveView page calls it under a grant to show plaintext.
  """
  use Samen.Resource,
    otp_app: :demo,
    domain: Demo.Crm,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource],
    abbrev: "cnt"

  postgres do
    table("cnt_contact")
    repo(Demo.Repo)
  end

  # T3.11 — the public API surface over a PII-bearing CRM resource.
  #
  # ALLOWLIST (opt-in, default not-exposed). `show_fields` is the load-bearing
  # control: a field NOT named here is ABSENT from every payload, even via
  # `?fields=` (AshJsonApi filters the final field set through `show_field?`, which
  # requires `field in show_fields`). So `active` is exposed, but a newly added
  # storage column is absent by omission until it is explicitly allowlisted — the
  # `newly added storage column does not appear` red path proves this.
  #
  # The names are CATALOG names (`:full_name`, `:emails`, `:display_name`) — never
  # storage names (`com_name`, `pii_cnt_dob`). What marks `full_name`/`emails`/`dob`
  # as PII is their vault routing (the `pii do` below), not any `pii_` prefix. Those
  # PII fields serialize `••••` (masked) or absent-on-operator-plane (see the API
  # masking layer). Deliberately NOT allowlisted: `notes` (the non_pii! plaintext
  # column) — a plaintext-at-rest field is never auto-published.
  json_api do
    type("contact")
    show_fields([:id, :display_name, :active, :full_name, :emails, :dob])

    # F3.7 — make the FILTER surface match the SERIALIZATION surface. AshJsonApi
    # derives a `?filter[…]` parameter from the resource's public attributes by
    # default (`derive_filter?` default true) — and Ash's filter parser accepts ANY
    # public attribute, INCLUDING one kept OFF `show_fields` (e.g. `org_id`, an
    # internal-routing column). That let `?filter[org_id]=…` act as a real predicate:
    # a hit/miss side channel over a field the allowlist omits from the body (Gate-3
    # §F3.7). Turning `derive_filter?` off routes any `filter` param to an unused
    # action argument (dropped), so a non-allowlisted field can no longer influence the
    # result set. Cross-org is already defended by OrgScope's FilterCheck; this closes
    # the residual same-org side channel over a de-allowlisted field.
    #
    # SORT is governed DIFFERENTLY and needs no flag here: AshJsonApi's sort parser
    # validates each `?sort=` field against `show_field?/2` and returns InvalidSort
    # (400) for a field absent from the allowlist — so `?sort=org_id` is ALREADY
    # refused. (Note: `AshJsonApi.Resource.Info.derive_sort?/1` reads the mis-keyed
    # option `:derive_sort` rather than the DSL's `:derive_sort?`, so a
    # `derive_sort?(false)` here is a no-op upstream — but it is unnecessary, since
    # show_fields already closes the sort surface. See the F3.7 red-path test.)
    derive_filter?(false)

    routes do
      base("/contacts")
      get(:read)
      index(:read)
    end
  end

  attributes do
    # Plain non-PII string (not flagged by pii_classify — not a known PII name).
    attribute(:display_name, :string, public?: true, allow_nil?: false)

    # A non-PII boolean — not a pii_ column, not a PII name. Proves pii_classify
    # does not flag everything.
    attribute(:active, :boolean, public?: true, default: true)

    # NOTE: `org_id` is injected by Samen.Transformers.CoreAttributes (public?: true,
    # allow_nil?: false → the NOT NULL `cnt_org_id` column). It is the tenant boundary
    # the org-scope policy filters on for the API's tenant-key cross-org denial proof.
    # It is deliberately NOT in the API allowlist (`show_fields`) — the org boundary
    # is internal routing, absent from the public payload by omission.
  end

  pii do
    # Vault declarations
    vault(:pii_name)
    vault(:pii_email)
    vault(:pii_dob)

    # Composite PII: FullName + Emails — the standard T1.9 composite pair.
    pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
    pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)

    # Scalar pii_ field: date of birth. Storage column: pii_cnt_dob.
    pii_attribute(:dob, :date, vault: :pii_dob)

    # Declare :reveal_contact as the reveal action. C3 pii_reads will not flag
    # vault-field reads inside this action.
    reveal(:reveal_contact)
  end

  relationships do
    has_many :memberships, Demo.Crm.Membership do
      public?(true)
    end
  end

  # T3.11 — the API PII-resolution rule on all reads. Inert for plane-less internal
  # reads (leaves `%Masked{}` → `••••`); on the API it makes tenant-plane keys read
  # own-org PII in clear, and operator-plane keys see `%Ash.ForbiddenField{}` (absent)
  # without a grant. The same read path serves UI + API.
  preparations do
    prepare(Samen.Api.PiiResolution)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # The declared reveal action. Called under a grant to expose plaintext.
    # In production this would load and return the plaintext fields; for the
    # dogfood we prove the boundary is declaration-driven, not name-matched.
    action :reveal_contact, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: Demo.Crm.Contact,
          action: :reveal_contact,
          label: :emails
        }

        # Use the configured grant checker (default-deny). NOTE: `Samen.Reveal` has
        # no bare `granted?/1` — the grant callback lives on the checker MODULE
        # (`grant_checker().granted?/1`), exactly as the scope-authoring guide §5
        # documents and the Identity blueprint does. A bare `Samen.Reveal.granted?(ctx)`
        # would raise UndefinedFunctionError if this action were ever invoked.
        if Samen.Reveal.grant_checker().granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end

  # T3.11 — the org-scope policy the tenant-plane API key runs under, on READS: a
  # tenant key scoped to org A reads only org A's contacts (the FilterCheck makes org
  # B's rows not exist → the `tenant key cross-org request denied` red path). This is
  # the load-bearing API boundary.
  #
  # Writes are left unauthorized (`always()`) so the T1.9 PII-vault dogfood — which
  # seeds contacts directly via `Ash.create` with no scoped actor — keeps working;
  # Contact is the T1.9 dogfood surface, and write-side org-scope is proven on the
  # policy-gated Identity scope (T3.1), not re-litigated here. The reveal action
  # carries its own grant gate (default-deny) inside its run/2.
  policies do
    # READS are org-scoped — the load-bearing API tenant boundary. A public API request
    # ALWAYS carries a scoped api_key actor; an actor-less API read (no/invalid key)
    # hits the FilterCheck's nil-org branch and sees ZERO rows (fail closed — the
    # boundary never opens by omission). The T1.9 PII-vault dogfood seeds/reads with
    # `authorize?: false`, so it is unaffected by this policy.
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Writes are left unauthorized (`always()`): the T1.9 dogfood seeds contacts via
    # `Ash.create` with no scoped actor, and write-side org-scope is proven on the
    # policy-gated Identity scope (T3.1). The reveal action carries its own grant gate.
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end

    policy action(:reveal_contact) do
      authorize_if(always())
    end
  end
end
