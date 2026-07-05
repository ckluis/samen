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
  use Ash.Domain, validate_config_inclusion?: false

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
    abbrev: "cnt"

  postgres do
    table("cnt_contact")
    repo(Demo.Repo)
  end

  attributes do
    # Plain non-PII string (not flagged by pii_classify — not a known PII name).
    attribute(:display_name, :string, public?: true, allow_nil?: false)

    # A non-PII boolean — not a pii_ column, not a PII name. Proves pii_classify
    # does not flag everything.
    attribute(:active, :boolean, public?: true, default: true)
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

        if Samen.Reveal.granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end
end
