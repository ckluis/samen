defmodule Samen.Scopes.Crm.Blueprint do
  @moduledoc """
  Resource-definition macros for the CRM scope (T3.2; ADR-004 blueprint).

  Objects: `company · person🔒 · opportunity · pipeline · activity · attachment`
  (doc §"The inherited 80%" scope table; vision doc §core person table).

  ## PII map (🔒)

  | Resource | Field        | Vault      | Column type         |
  |----------|--------------|------------|---------------------|
  | person   | full_name    | :pii_name  | composite (no pii_) |
  | person   | emails       | :pii_email | composite (no pii_) |
  | person   | phones       | :pii_phone | composite (no pii_) |

  `person` composes `Samen.Fragments.CorePerson` (the canonical vault case from
  the vision doc): `use Samen.Resource, base: Samen.Fragments.CorePerson`. This
  folds full_name/emails/phones/job_title/custom into ONE physical table (single-
  table composition, never Postgres INHERITS). The FK rule: every `belongs_to`
  that targets a person must point at the HOST's `Person` resource (the composed
  table), never at the fragment.

  ## Tier-0 config rows

  `Pipeline` is the CRM's Tier-0 config-row resource: one row per pipeline stage
  per org (e.g. Lead→Qualified→Proposal→Closed). Tenants bend deal-stage names
  without forking the product.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage, injected by the
  Samen base macro and the abbrev transformer). The public API/catalog only ever
  sees the logical name.

  ## E6 soft-delete adoption (ADR-040 §5.9, T37c)

  `company`, `person` 🔒, `pipeline`, `opportunity`, and `attachment` all carry
  `archivable: true` — the §5.9 roster lists no exclusion for this scope. The
  former `activity` resource is NOT part of this adoption: it was destructively
  migrated into the canonical Work-scope `Task` and removed from this module
  before T37c ran (ADR-041 §5, T97) — the canonical Task arrives
  `archivable true` on its own terms, tracked by T97/T43, not here. No
  composition cascade is declared for CRM (§5.4): archiving any of the five
  adopted resources leaves its linked rows live.
  """

  # ---------------------------------------------------------------------------
  # Company — the CRM company record. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_company(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CRM.Company — a B2B company record (doc scope table `company`).
        Org-scoped. No PII. Admin-gated writes.

        ADR-040 §5.9 roster (T37c): `company` adopts E6 soft-delete
        (`archivable true`). No cascade declared for CRM (§5.4) — archiving a
        company leaves its linked person/opportunity/attachment rows live (no
        PII on this resource, so INV-1 masking is not applicable here).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          keyset_sort: :name,
          abbrev: unquote(abbrev),
          archivable: true

        resource do
          description(
            "A business the organization sells to or works with; people, deals and attachments link to it."
          )
        end

        meaning do
          synonyms(["account"])
        end

        postgres do
          table("#{unquote(abbrev)}_company")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            description: "Name of the company as entered by the team; required, and no uniqueness rule is enforced."
          )

          attribute(:domain, :string,
            public?: true,
            description: "Internet domain of the company as free text; no format is enforced."
          )

          attribute(:industry, :string,
            public?: true,
            description: "Industry or sector of the company as free text; no fixed list is enforced."
          )

          attribute(:size, :string,
            public?: true,
            description: "Size of the company as free text as entered; no format or fixed list is enforced."
          )

          attribute(:website, :string,
            public?: true,
            description: "Website address of the company as free text; no URL format is enforced."
          )

          attribute(:notes, :string,
            public?: true,
            description: "Free-text notes the team keeps about the company."
          )

          # Tier-1 custom bag
          attribute(:custom, :map, public?: true)
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
  # Person — 🔒 PII (full_name/emails/phones via Core.Person fragment).
  # Composes Samen.Fragments.CorePerson: single-table, ONE physical table.
  # Org-scoped.
  # ---------------------------------------------------------------------------
  defmacro define_person(module, otp_app, domain, repo, abbrev, company_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CRM.Person — the canonical PII vault case (doc §core person table;
        vision doc "The proof — one base, many shapes"). Composes
        `Samen.Fragments.CorePerson` via `base:` — a single physical table
        carrying `full_name`, `emails`, `phones` (each vault-routed PII,
        masked by default) plus `job_title`, `custom`, and `company_id`.

        The revealed vault action exposes plaintext under a grant only. Org-scoped.

        ADR-040 §5.9 roster (T37c): `person` 🔒 adopts E6 soft-delete
        (`archivable true`) — this scope's vaulted-pilot masking target. An
        archived person keeps its vault tokens (full_name/emails/phones stay
        `vt_*`, never erased) and masks per plane exactly like a live row
        (§5.1/INV-1): the operator-without-grant plane still resolves
        `%Samen.Masked{}`, never plaintext, never the raw token; a restore
        never leaks either. No cascade declared for CRM (§5.4) — archiving a
        person leaves its linked attachment rows live.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          keyset_sort: :display_name,
          abbrev: unquote(abbrev),
          base: Samen.Fragments.CorePerson,
          archivable: true

        resource do
          description(
            "A person the organization deals with, such as a customer contact; name, emails and phones are vault-routed (clear on the owning organization's tenant plane, masked or omitted on other planes without a reveal grant)."
          )
        end

        meaning do
          synonyms(["individual"])
        end

        postgres do
          table("#{unquote(abbrev)}_person")
          repo(unquote(repo))
        end

        # The declare_reveal here names the reveal action; actual PII fields are
        # contributed by the Core.Person fragment's pii do block (folded in via base:).
        pii do
          reveal(:reveal_person)
        end

        attributes do
          attribute(:display_name, :string,
            public?: true,
            description:
              "Label used to show and sort the person in lists; free text kept apart from the vault-routed full name."
          )
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            description("The company this person is associated with, if any.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: a person may only reference a same-org company.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:company]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_person, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_person,
                label: :emails
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

          policy action(:reveal_person) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline — Tier-0 config rows (deal-stage catalog per org). Org-scoped.
  # Admin-gated writes. The Tier-0 bottom rung of the malleability ladder.
  # ---------------------------------------------------------------------------
  defmacro define_pipeline(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CRM.Pipeline — Tier-0 config rows (doc scope table `pipeline`; malleability
        ladder §7 "config rows cover ~70%"). One row per pipeline/stage per org.
        Tenants rename stages and reorder without forking the product. Admin-gated
        writes. Org-scoped.

        ADR-040 §5.9 roster (T37c): `pipeline` adopts E6 soft-delete
        (`archivable true`). No cascade declared for CRM (§5.4) — archiving a
        pipeline stage leaves opportunities pointing at it live (no PII on
        this resource, so INV-1 masking is not applicable here).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        resource do
          description(
            "One stage of the organization's sales pipeline; deals point at a stage, and admins can rename or reorder stages."
          )
        end

        meaning do
          synonyms(["stage"])
        end

        postgres do
          table("#{unquote(abbrev)}_pipeline")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            description: "Name that identifies the pipeline stage; required."
          )

          attribute(:label, :string,
            public?: true,
            description: "Display label shown for the stage in the interface, separate from its name."
          )

          attribute(:stage_order, :integer,
            public?: true,
            default: 0,
            description: "Position of the stage in the pipeline; stages are shown in ascending order of this number."
          )

          attribute(:enabled, :boolean,
            public?: true,
            default: true,
            description: "A flag marking whether the stage is enabled; defaults to true. Nothing in the framework reads it, so a disabled stage still shows on the board and can be assigned to a deal."
          )

          # Bounded stage type: standard pipeline stages as config atoms.
          attribute(:stage_type, :atom,
            public?: true,
            default: :open,
            description: "Kind of stage in the deal lifecycle, restricted to a fixed list of values; defaults to open.",
            constraints: [one_of: [:open, :won, :lost, :qualified, :proposal]]
          )
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Opportunity — a deal/opportunity record. Belongs to company + pipeline stage.
  # Org-scoped. No PII (contact relationships are separate).
  # ---------------------------------------------------------------------------
  defmacro define_opportunity(module, otp_app, domain, repo, abbrev, company_mod, pipeline_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CRM.Opportunity — a deal/opportunity record (doc scope table `opportunity`).
        Belongs to a company and a pipeline stage. Org-scoped. No PII.

        ADR-040 §5.9 roster (T37c): `opportunity` adopts E6 soft-delete
        (`archivable true`). No cascade declared for CRM (§5.4) — archiving an
        opportunity leaves its linked attachment rows live (no PII on this
        resource, so INV-1 masking is not applicable here).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        resource do
          description(
            "A sales deal that can be tied to a company and a pipeline stage; its status is open, won, lost or on hold."
          )
        end

        meaning do
          synonyms(["deal"])
          field(:value, label: "Deal value", synonyms: ["amount", "deal size"])
          field(:probability, label: "Win probability")
        end

        postgres do
          table("#{unquote(abbrev)}_opportunity")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            description: "Short title of the deal as shown in lists; required."
          )

          # ADR-036 H1/D7: the paired `value_cents :integer` + `currency :string`
          # convention is replaced by ONE Money composite attribute (destructive,
          # pre-1.0, single data-copy migration — no deprecation window; T12).
          # Default $0.00 USD mirrors the prior pair's `default: 0` / `default: "USD"`.
          attribute(:value, Samen.Type.Money,
            public?: true,
            default: {Money, :new!, [:USD, 0]},
            description: "Expected value of the deal, stored as money with its own currency; defaults to zero US dollars."
          )

          attribute(:probability, :integer,
            public?: true,
            default: 0,
            description: "Estimated chance of winning the deal, stored as an integer; its unit and range are not enforced."
          )

          attribute(:status, :atom,
            public?: true,
            default: :open,
            constraints: [one_of: [:open, :won, :lost, :on_hold]],
            description: "Overall state of the deal, independent of its pipeline stage; defaults to open."
          )

          attribute(:close_date, :date,
            public?: true,
            description: "Calendar date associated with closing the deal; no rule ties it to the deal status."
          )

          attribute(:notes, :string,
            public?: true,
            description: "Free-text notes the team keeps about the deal."
          )

          # Tier-1 custom bag
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            description("The company this deal is with, if any.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :pipeline, unquote(pipeline_mod) do
            description("The pipeline stage the deal is currently in, if any.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: an opportunity may only reference same-org parents.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:company, :pipeline]})
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
  # Activity — REMOVED (ADR-041 §5, operator ruling M5). The CRM `Activity`
  # resource was destructively migrated into the canonical Work-scope `Task`
  # (`Samen.Scopes.Work.Task`) and dropped by T97. The former `define_activity/8`
  # macro lived here; every Activity row now lands on Task field-for-field
  # (ADR-041 §5.1), and the CRM timeline reads Task through the generic
  # `(subject_key, subject_id)` object-ref anchor. See ADR-041 + CHANGELOG.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Attachment — a file reference linked to any CRM object. Org-scoped. No PII
  # (the file name/path is metadata, not subject identity data).
  # ---------------------------------------------------------------------------
  defmacro define_attachment(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             company_mod,
             person_mod,
             opportunity_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        CRM.Attachment — a file reference attached to a CRM object (doc scope table
        `attachment`). Org-scoped. No PII (file_name and storage_key are metadata,
        not subject identity). Admin/member writes.

        ADR-040 §5.9 roster (T37c): `attachment` adopts E6 soft-delete
        (`archivable true`). No cascade declared for CRM (§5.4) — attachment is
        a cascade LEAF here (no PII on this resource, so INV-1 masking is not
        applicable here).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        resource do
          description("A reference to a stored file that can be linked to a company, a person or a deal; each link is optional.")
        end

        meaning do
          synonyms(["attached file"])
          field(:size_bytes, units: "bytes")
        end

        postgres do
          table("#{unquote(abbrev)}_attachment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:file_name, :string,
            public?: true,
            allow_nil?: false,
            description: "Name of the attached file; required."
          )

          attribute(:content_type, :string,
            public?: true,
            description: "Media type of the file as free text; no format is enforced."
          )

          attribute(:size_bytes, :integer,
            public?: true,
            description: "Size of the file as recorded on the reference; it is not checked against the stored file."
          )

          # Opaque storage key (object-store path / S3 key). Non-PII metadata.
          attribute(:storage_key, :string,
            public?: true,
            description: "Free-text key a host may use to locate the stored file; this reference neither mints nor checks it, and it is not meant to be read by people."
          )
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            description("The company the file is attached to, if any.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :person, unquote(person_mod) do
            description("The person the file is attached to, if any.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :opportunity, unquote(opportunity_mod) do
            description("The deal the file is attached to, if any.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        # F3.2 same-org FK: an attachment may only reference same-org parents.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:company, :person, :opportunity]})
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
