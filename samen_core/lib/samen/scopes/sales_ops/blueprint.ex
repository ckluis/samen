defmodule Samen.Scopes.SalesOps.Blueprint do
  @moduledoc """
  Resource-definition macros for the **SalesOps** scope (F6+F7; spec §F6,§F7/§F8).

  Two resources: **`Vendor`** (F6 — companies you buy from) and **`Lead`** (F7 — a
  sales lead distinct from marketing `Subscriber`, with a `:convert` action).
  See `Samen.Scopes.SalesOps` moduledoc for the full PII map and mounting recipe.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`, matching every other Samen scope.
  """

  # ---------------------------------------------------------------------------
  # Vendor — a company you buy from (F6). Org-scoped. Archivable.
  # Carries one embedded vendor contact (vaulted).
  # ---------------------------------------------------------------------------
  defmacro define_vendor(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        SalesOps.Vendor — a company you buy from (F6), CRM-adjacent but a standalone
        resource from `Samen.Scopes.Crm.Company` (a customer/prospect company). Carries
        one embedded vendor contact: `contact_name` (🔒 `Samen.Type.FullName`, `vault:
        :pii_name`), `contact_emails` (🔒 `Samen.Type.Emails`, `vault: :pii_email`),
        `contact_phones` (🔒 `Samen.Type.Phones`, `vault: :pii_phone`) — masked per plane
        through the standard `Samen.Api.PiiResolution` seam (INV-1).

        Archivable (ADR-040 §5.9). Org-scoped.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_vendor")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:website, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :inactive]]
          )

          attribute(:notes, :string, public?: true)
          # Tier-1 custom bag
          attribute(:custom, :map, public?: true)
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)
          vault(:pii_phone)

          pii_attribute(:contact_name, Samen.Type.FullName, vault: :pii_name)
          pii_attribute(:contact_emails, Samen.Type.Emails, vault: :pii_email)
          pii_attribute(:contact_phones, Samen.Type.Phones, vault: :pii_phone)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lead — a sales lead, distinct from marketing Subscriber (F7). Org-scoped.
  # Archivable. `:convert` — lead → CRM Person (Contact) + Opportunity.
  # ---------------------------------------------------------------------------
  defmacro define_lead(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             person_mod,
             opportunity_mod,
             company_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        SalesOps.Lead — a SALES lead (F7), distinct from
        `Samen.Scopes.Marketing.Subscriber` (a marketing opt-in list member): own table
        (`#{unquote(abbrev)}_lead`, never `_subscriber`), own PII shape
        (`full_name`/`emails`/`phones`, the SAME `Samen.Type.FullName`/`Emails`/`Phones`
        composites `Samen.Fragments.CorePerson` uses — 🔒 vaulted, masked per plane,
        INV-1), a sales-qualification `status` (`:new`/`:contacted`/`:qualified`/
        `:converted`/`:disqualified`) rather than a consent flag, and a `value` deal-size
        estimate typed `Samen.Type.Money` (H1/T12 — exact, never a float, INV-2).

        `:convert` is the F7 lead → contact/opportunity conversion action: creates a host
        CRM `#{inspect(unquote(person_mod))}` (the "Contact") + `#{inspect(unquote(opportunity_mod))}`
        (carrying `value` unchanged), links this Lead back to both, and closes it
        (`status: :converted`) — all inside ONE database transaction
        (`Samen.Scopes.SalesOps.ConvertLead`). A second `:convert` on an already-converted
        Lead is refused (`Samen.Scopes.SalesOps.AlreadyConverted`), never silently
        re-converts.

        The created Person's `full_name`/`emails`/`phones` are FRESHLY vaulted (a new
        `vt_*` token minted on ITS OWN table) — the Lead's own vault token is never
        copied or reused across the conversion (INV-1's re-tokenize-on-copy rule).

        Archivable (ADR-040 §5.9). Org-scoped.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_lead")
          repo(unquote(repo))
        end

        attributes do
          # The lead's freeform employer label — NOT a FK (pre-conversion, there is no
          # CRM Company row yet for most leads). Non-PII (a business name, not a person).
          attribute(:company_name, :string, public?: true)

          attribute(:source, :atom,
            public?: true,
            default: :other,
            constraints: [one_of: [:web, :referral, :event, :cold_outreach, :other]]
          )

          attribute(:status, :atom,
            public?: true,
            default: :new,
            constraints: [one_of: [:new, :contacted, :qualified, :converted, :disqualified]]
          )

          # Deal-size estimate. Exact (Decimal-backed composite Postgres type via
          # AshMoney), never a float — INV-2.
          attribute(:value, Samen.Type.Money, public?: true, default: {Money, :new!, [:USD, 0]})

          attribute(:notes, :string, public?: true)
          # Tier-1 custom bag
          attribute(:custom, :map, public?: true)

          attribute(:converted_at, :utc_datetime_usec, public?: true)
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)
          vault(:pii_phone)

          pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
          pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)
          pii_attribute(:phones, Samen.Type.Phones, vault: :pii_phone)
        end

        relationships do
          belongs_to :converted_person, unquote(person_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :converted_opportunity, unquote(opportunity_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: a converted Lead may only link to same-org Person/Opportunity
        # rows (both are always created same-org by ConvertLead — this is a structural
        # belt, never expected to fire in normal operation).
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:converted_person, :converted_opportunity]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # F7 — the lead → contact/opportunity conversion action.
          update :convert do
            accept([])
            argument(:company_id, :uuid, allow_nil?: true)

            require_atomic?(false)

            validate({Samen.Scopes.SalesOps.AlreadyConverted, []})

            change(set_attribute(:status, :converted))
            change(set_attribute(:converted_at, &DateTime.utc_now/0))

            change(
              {Samen.Scopes.SalesOps.ConvertLead,
               person_mod: unquote(person_mod),
               opportunity_mod: unquote(opportunity_mod),
               company_mod: unquote(company_mod)}
            )
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end
