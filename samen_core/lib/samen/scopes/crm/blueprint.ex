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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_company")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:domain, :string, public?: true)
          attribute(:industry, :string, public?: true)
          attribute(:size, :string, public?: true)
          attribute(:website, :string, public?: true)
          attribute(:notes, :string, public?: true)
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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          base: Samen.Fragments.CorePerson

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
          attribute(:display_name, :string, public?: true)
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_pipeline")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:label, :string, public?: true)
          attribute(:stage_order, :integer, public?: true, default: 0)
          attribute(:enabled, :boolean, public?: true, default: true)
          # Bounded stage type: standard pipeline stages as config atoms.
          attribute(:stage_type, :atom,
            public?: true,
            default: :open,
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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_opportunity")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:value_cents, :integer, public?: true, default: 0)
          attribute(:currency, :string, public?: true, default: "USD")
          attribute(:probability, :integer, public?: true, default: 0)
          attribute(:status, :atom,
            public?: true,
            default: :open,
            constraints: [one_of: [:open, :won, :lost, :on_hold]]
          )
          attribute(:close_date, :date, public?: true)
          attribute(:notes, :string, public?: true)
          # Tier-1 custom bag
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :pipeline, unquote(pipeline_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
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
  # Activity — a CRM activity (call, email, note, meeting). Org-scoped. No PII
  # (person/company IDs are opaque IDs, not names).
  # ---------------------------------------------------------------------------
  defmacro define_activity(
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
        CRM.Activity — a CRM activity (call, email, meeting, note) linked to a
        company/person/opportunity (doc scope table `activity`). Org-scoped. No PII
        in the activity row itself — references are opaque IDs.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_activity")
          repo(unquote(repo))
        end

        attributes do
          attribute(:type, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:call, :email, :meeting, :note, :task]]
          )

          attribute(:subject, :string, public?: true)
          attribute(:body, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :pending,
            constraints: [one_of: [:pending, :completed, :cancelled]]
          )
          attribute(:due_at, :utc_datetime, public?: true)
          attribute(:completed_at, :utc_datetime, public?: true)
          # Tier-1 custom bag
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :person, unquote(person_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :opportunity, unquote(opportunity_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
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
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_attachment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:file_name, :string, public?: true, allow_nil?: false)
          attribute(:content_type, :string, public?: true)
          attribute(:size_bytes, :integer, public?: true)
          # Opaque storage key (object-store path / S3 key). Non-PII metadata.
          attribute(:storage_key, :string, public?: true)
        end

        relationships do
          belongs_to :company, unquote(company_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :person, unquote(person_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :opportunity, unquote(opportunity_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
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
end
