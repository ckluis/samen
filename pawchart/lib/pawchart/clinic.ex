defmodule PawChart.Clinic do
  @moduledoc """
  PawChart's Clinical domain — the VERTICAL-authored resources (the "20%").

  This is the doc's "two PII subjects, one relationship" shape (vision doc §core, the
  PawChart row: "the animal is the record, but you bill and message the human owner"):

    * `PawChart.Clinic.Patient` — the HUMAN OWNER. Composes `Samen.Fragments.CorePerson`
      via `base:`, so `full_name`/`emails`/`phones` are vault-routed (composite types,
      columns `own_full_name`/`own_emails`/`own_phones`) exactly like the CRM Person and
      the Driftwood Driver. The owner is a first-class PII subject with its own
      crypto-shred key. No `pii_` scalar of its own — the human's PII is the inherited
      CorePerson set.

    * `PawChart.Clinic.Pet` — the ANIMAL, and the actual clinical RECORD. Carries the
      SCALAR vault field `pii_pet_microchip` (the doc's `pii_pat_microchip`; PawChart
      names it `pii_pet_microchip` because the animal record is `Pet`/abbrev `pet`, and
      the storage transformer prefixes a scalar `pii_` field with the resource abbrev).
      A microchip UID is a globally-unique animal identifier that also fingerprints the
      owner's household — so it is vaulted, masked `••••` by default, plaintext only via
      `:reveal_pet` under a distinct-party grant, and crypto-shreddable with the pet.
      Plus non-PII clinical columns (species/breed/weight, Tier-0 temperament) and a
      `belongs_to :owner, Patient` FK (guarded by `Samen.Policy.SameOrgFk`).

  Both resources are Tier-3 code composition: they `use Samen.Resource` and inherit the
  ENTIRE substrate (abbrev storage, vault routing, masking, OrgScope, catalog parity,
  audit, crypto-shred) with no vertical infrastructure code. What PawChart AUTHORS is
  only the two nouns' domain shape — the calibrated "you inherit infrastructure, not a
  domain model" honest edge from the doc.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PawChart.Clinic.Patient)
    resource(PawChart.Clinic.Pet)
  end
end

# ---------------------------------------------------------------------------
# Patient — the HUMAN OWNER. Composes CorePerson (single-table) — the PII subject.
# ---------------------------------------------------------------------------
defmodule PawChart.Clinic.Patient do
  @moduledoc """
  A PawChart PATIENT = the human OWNER of the animals (the paying, messaged party).

  `use Samen.Resource, base: Samen.Fragments.CorePerson` folds the core-person columns
  (`full_name`/`emails`/`phones` vault-routed, `job_title`, `custom`, id/org_id/
  timestamps) into ONE physical table `own_patient`. The owner is a full PII subject:
  name/emails/phones live encrypted in the vault under the owner's per-subject key,
  render `••••` by default, and are crypto-shreddable — all inherited from CorePerson
  with ZERO vertical PII code.

  Named `Patient` per the task/doc (the clinic's word for the client account), abbrev
  `own` (the OWNER); its Pets FK back via `pet_owner_id`.
  """
  use Samen.Resource,
    otp_app: :pawchart,
    domain: PawChart.Clinic,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "own",
    base: Samen.Fragments.CorePerson

  postgres do
    table("own_patient")
    repo(PawChart.Repo)
  end

  attributes do
    # A non-PII marketing-consent flag (the clinic messages the owner) — Tier-0-ish
    # bounded boolean, authored domain field.
    attribute(:marketing_opt_in, :boolean, public?: true, default: false)
  end

  # The inherited two-key-class PII-resolution rule on all reads (same
  # `Samen.Api.PiiResolution` the substrate uses). Inert for plane-less internal reads
  # (leaves `%Masked{}` → ••••).
  preparations do
    prepare(Samen.Api.PiiResolution)
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
# Pet — the ANIMAL / the clinical RECORD. Scalar vault field pii_pet_microchip.
# ---------------------------------------------------------------------------
defmodule PawChart.Clinic.Pet do
  @moduledoc """
  A PawChart PET = the animal, and the actual clinical record. `use Samen.Resource`
  (abbrev `pet`) with:

    * `pii_pet_microchip` — the microchip UID, the SCALAR `pii_` vault field
      (`pii_attribute :microchip, :string, vault: :pii_microchip`). Masked `••••` by
      default; plaintext only via `:reveal_pet` under a distinct-party grant. The
      column name `pii_pet_microchip` is what the storage transformer produces from the
      resource abbrev + the `pii_` scalar rule — the doc's `pii_pat_microchip` idiom.
    * `species` / `breed` / `weight_kg` — plain non-PII clinical columns (an animal's
      species is not subject-identifying of the human owner).
    * `temperament` — a Tier-0 config enum (docile/anxious/aggressive/unknown).
    * `owner` — a `belongs_to` FK → the composed Patient table (`own_patient`), guarded
      by `Samen.Policy.SameOrgFk` (a pet may only reference a same-org owner).

  This is the doc's "two PII subjects, one relationship": the owner (Patient) is one
  PII subject with vaulted name/emails/phones; the pet's microchip is a SEPARATE
  vaulted secret on the animal record, keyed to the pet's own subject id. Erasing the
  owner and erasing the pet each shred their own vault key.
  """
  use Samen.Resource,
    otp_app: :pawchart,
    domain: PawChart.Clinic,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "pet"

  postgres do
    table("pet_pet")
    repo(PawChart.Repo)
  end

  attributes do
    attribute(:name, :string, public?: true)
    attribute(:species, :string, public?: true)
    attribute(:breed, :string, public?: true)
    attribute(:weight_kg, :decimal, public?: true)

    attribute(:temperament, :atom,
      public?: true,
      default: :unknown,
      constraints: [one_of: [:docile, :anxious, :aggressive, :unknown]]
    )
  end

  pii do
    vault(:pii_microchip)
    # Scalar pii_ field → column pii_pet_microchip (abbrev-prefixed scalar rule).
    pii_attribute(:microchip, :string, vault: :pii_microchip)
    reveal(:reveal_pet)
  end

  relationships do
    belongs_to :owner, PawChart.Clinic.Patient do
      public?(true)
      attribute_type(:uuid)
      allow_nil?(true)
    end
  end

  # Same-org FK: a pet may only reference a same-org owner.
  changes do
    change({Samen.Policy.SameOrgFk, relationships: [:owner]})
  end

  # The inherited two-key-class PII-resolution rule on all reads.
  preparations do
    prepare(Samen.Api.PiiResolution)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    action :reveal_pet, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: __MODULE__,
          action: :reveal_pet,
          label: :microchip
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

    policy action(:reveal_pet) do
      authorize_if(always())
    end
  end
end
