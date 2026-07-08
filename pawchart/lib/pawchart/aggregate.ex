defmodule PawChart.Aggregate do
  @moduledoc """
  PawChart's **token-blind aggregate plane** domain (doc §control "Cross-tenant views
  run on a separate token-blind actor"). Mounted here so the C7 `no_pii_columns` and
  the T4.5 `aggregate_privacy` verifiers have a real aggregate plane to scan on the
  PawChart app (the full gate is uniform across every vertical).

  This is the SEPARATE, DEFAULT-DENY Ash domain whose only admissible actor is the
  singleton `Samen.Aggregate.Actor` (`operator_aggregate`, no `org_id`). Every resource
  carries `policy always() do authorize_if Samen.Policy.AggregateActorOnly end` (default
  deny, no fallthrough). It is inherited machinery — PawChart writes no aggregate
  infrastructure, only declares the vet-shaped projection.

  ## Cross-tenant projection (vault-excluded, no pii_ columns)

    * `PawChart.Aggregate.PatientVolumeBySpecies` (`pag_patient_volume_by_species`) —
      cross-tenant PET/patient VOLUME by species, rolled up across every clinic tenant.
      Columns: `species` (bounded cohort key), `clinic_count` (int — the cohort size,
      k-anon), `pet_count` (int). Counts and numbers, never a subject. A count-of-one
      clinic on a rare species suppresses (a single clinic's exact caseload is never
      released).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PawChart.Aggregate.PatientVolumeBySpecies)
  end
end

defmodule PawChart.Aggregate.PatientVolumeBySpecies do
  @moduledoc """
  Cross-tenant PET VOLUME by species. A `use Samen.Aggregate.Resource` projection over
  the vault-excluded `pag_patient_volume_by_species` summary table.

  Every column is bounded / non-PII: `species` (a coarse animal-type bucket, NOT a
  subject), `clinic_count` (a count — the cohort size for k-anon), `pet_count` (a
  count). NO `pii_attribute`, NO vault, NO relationship to a PII-bearing resource — the
  C7 verifier enforces this at compile time. Cross-tenant (no org boundary).
  """
  use Samen.Aggregate.Resource,
    otp_app: :pawchart,
    domain: PawChart.Aggregate,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "pag"

  postgres do
    table("pag_patient_volume_by_species")
    repo(PawChart.Repo)
  end

  attributes do
    # Cross-tenant aggregate: NO single org. Declared nullable to opt out of the
    # universal non-null org_id injection — a per-species volume spans ALL clinics.
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    # The species bucket (e.g. "canine"). The COHORT key. Non-PII.
    attribute(:species, :string, public?: true, allow_nil?: false)
    # Number of distinct clinic tenants seeing this species (cohort SIZE — k-anon).
    attribute(:clinic_count, :integer, public?: true, default: 0)
    # Number of pets of this species across all clinics (a count). Non-PII.
    attribute(:pet_count, :integer, public?: true, default: 0)
    attribute(:refreshed_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])
  end

  # DEFAULT DENY. Only the token-blind aggregate actor is admitted. No fallthrough.
  policies do
    policy always() do
      authorize_if(Samen.Policy.AggregateActorOnly)
    end
  end

  @doc """
  The T4.5 cohort spec: the species cohort's SIZE (for k-anonymity) is `clinic_count`.
  The RELEASABLE value `pet_count` is suppressed when `clinic_count < k` (including a
  count-of-one species, which would let an operator read one clinic's exact caseload).
  """
  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:species],
      cohort_count_column: :clinic_count,
      distinct_sensitive_column: nil,
      value_columns: [:pet_count],
      sensitive_attribute: nil
    }
  end
end
