defmodule PawChart.CrossOrgTest do
  @moduledoc """
  RED-PATH test: cross-org isolation on the PawChart resources. An actor scoped to
  clinic A cannot read clinic B's Patient (owner) / Pet — the kernel `OrgScope` policy
  (inherited unchanged, ZERO PawChart code) makes foreign-org rows NOT EXIST for the
  actor. Also proves the same-org-FK guard refuses a cross-org owner→pet link.
  """
  use PawChart.DataCase, async: false
  require Ash.Query

  @org_a "00000000-0000-0000-0000-00000000000a"
  @org_b "00000000-0000-0000-0000-00000000000b"

  defp scope(org), do: %{org_id: org, role: :member}

  defp owner(org, first) do
    PawChart.Clinic.Patient
    |> Ash.Changeset.for_create(:create, %{org_id: org, full_name: %{first: first, last: "X"}},
      actor: scope(org)
    )
    |> Ash.create!()
  end

  defp pet(org, name, owner_id \\ nil) do
    PawChart.Clinic.Pet
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: name, species: "canine", owner_id: owner_id},
      actor: scope(org),
      authorize?: false
    )
    |> Ash.create!()
  end

  test "actor in clinic A cannot READ clinic B's Patient (kernel OrgScope, inherited)" do
    _b_owner = owner(@org_b, "SecretOwnerB")

    a_view =
      PawChart.Clinic.Patient
      |> Ash.Query.for_read(:read, %{}, actor: scope(@org_a))
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: true)

    assert Enum.all?(a_view, &(&1.org_id == @org_a))
    # No B-org patients visible to the A actor.
    refute Enum.any?(a_view, &(&1.org_id == @org_b))
  end

  test "actor in clinic A cannot READ clinic B's Pet" do
    _b_pet = pet(@org_b, "SecretPetB")

    a_view =
      PawChart.Clinic.Pet
      |> Ash.Query.for_read(:read, %{}, actor: scope(@org_a))
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: true)

    refute Enum.any?(a_view, &(&1.name == "SecretPetB"))
    assert Enum.all?(a_view, &(&1.org_id == @org_a))
  end

  test "the same-org-FK guard REFUSES a pet in clinic A pointing at a clinic-B owner" do
    b_owner = owner(@org_b, "OwnerB")

    result =
      PawChart.Clinic.Pet
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @org_a, name: "CrossPet", species: "feline", owner_id: b_owner.id},
        actor: scope(@org_a),
        authorize?: true
      )
      |> Ash.create()

    assert {:error, _err} = result

    # No pet row references that cross-org owner.
    count =
      PawChart.Clinic.Pet
      |> Ash.Query.filter(owner_id == ^b_owner.id)
      |> Ash.read!(authorize?: false)
      |> length()

    assert count == 0
  end
end
