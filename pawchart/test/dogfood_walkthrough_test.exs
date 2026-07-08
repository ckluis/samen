defmodule PawChart.DogfoodWalkthroughTest do
  @moduledoc """
  End-to-end dogfood: a vet clinic runs on PawChart. Proves the "two PII subjects, one
  relationship" shape and the additive-reuse thesis in ONE walkthrough:

    1. the clinic onboards an OWNER (Patient, composes CorePerson — PII vaulted);
    2. registers a PET (Pet, microchip vaulted, FK → owner);
    3. bills the clinic a plain monthly SUBSCRIPTION (Billing scope reused as-is);
    4. defines its own Tier-2 VaccineLot object and logs a lot.

  Nothing here is PawChart infrastructure code — the whole flow is inherited substrate
  driven by two authored nouns and one mounted scope.
  """
  use PawChart.DataCase, async: false
  require Ash.Query

  alias Samen.CustomObjects

  @org "00000000-0000-0000-0000-00000000da01"

  test "a clinic onboards an owner + pet, subscribes, and logs a VaccineLot" do
    # 1. Owner (human PII subject).
    owner =
      PawChart.Clinic.Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        full_name: %{first: "Dana", last: "Doghouse"},
        emails: ["dana@example.com"],
        phones: ["+15551234567"],
        marketing_opt_in: true
      })
      |> Ash.create!(authorize?: false)

    # 2. Pet (animal record, microchip vaulted, FK → owner).
    pet =
      PawChart.Clinic.Pet
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        name: "Biscuit",
        species: "canine",
        breed: "beagle",
        weight_kg: Decimal.new("12.4"),
        microchip: "985-000-111-222",
        temperament: :docile,
        owner_id: owner.id
      })
      |> Ash.create!(authorize?: false)

    assert pet.owner_id == owner.id
    # Both PII subjects are masked by default.
    reloaded_pet =
      PawChart.Clinic.Pet
      |> Ash.Query.filter(id == ^pet.id)
      |> Ash.Query.ensure_selected([:microchip])
      |> Ash.read_one!(authorize?: false)

    assert match?(%Samen.Masked{}, reloaded_pet.microchip)

    # 3. Plain subscription (Billing reused as-is).
    customer =
      PawChart.Billing.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        billing_name: %{first: "Happy", last: "Paws"},
        billing_email: ["billing@happypaws.example.com"]
      })
      |> Ash.create!(authorize?: false)

    plan =
      PawChart.Billing.Plan
      |> Ash.Changeset.for_create(:create, %{org_id: @org, name: "clinic_pro", interval: :monthly})
      |> Ash.create!(authorize?: false)

    subscription =
      PawChart.Billing.Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        customer_id: customer.id,
        plan_id: plan.id,
        status: :active
      })
      |> Ash.create!(authorize?: false)

    assert subscription.status == :active

    # 4. Tier-2 VaccineLot the clinic defines itself.
    {:ok, _obj} =
      CustomObjects.define_object(%{org_id: @org, object_key: "vaccine_lot", label: "Vaccine Lot"}, PawChart.Repo)

    {:ok, _f1} =
      CustomObjects.define_object_field(
        %{org_id: @org, object_key: "vaccine_lot", field_name: "lot_number", type: :string},
        PawChart.Repo
      )

    scope = %Samen.Scope{actor: %{org_id: @org, role: :member}}

    {:ok, _lot} =
      CustomObjects.create_record(scope, "vaccine_lot", %{"lot_number" => "RAB-2026-004"})

    {:ok, lots} = CustomObjects.list_records(scope, "vaccine_lot")
    assert length(lots) == 1
    assert hd(lots).attributes["lot_number"] == "RAB-2026-004"
  end
end
