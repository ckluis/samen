defmodule PawChart.VaccineLotTier2Test do
  @moduledoc """
  RED-PATH test: the Tier-2 `VaccineLot` custom object clinics define themselves — the
  vision doc's CANONICAL Tier-2 example ("a VaccineLot object clinics define themselves",
  §core; malleability ladder rung 3). Proves, end-to-end against the real PawChart DB:

    * a clinic defines a custom OBJECT (`tnt_object`) + its fields (`tnt_field`) → the
      object + fields are catalogued and ORG-SCOPED (a second clinic sees nothing);
    * an attribute bag is validated-at-write against the object's fields — an undefined
      key / wrong type / PII-shaped value is REJECTED (CONTAINMENT);
    * a `tnt_record` VaccineLot row is created and read back ORG-SCOPED; a cross-org
      read returns `[]`;
    * the ONE-WAY BOUNDARY holds: no PawChart system resource references INTO
      `tnt_record`, and no FK targets a tenant-regime table (`mix samen.verify.tnt_boundary`).

  Every mechanism is inherited T3.9 substrate (`Samen.CustomObjects` + `Samen.CustomFields`)
  — PawChart authors NO Tier-2 machinery. It just calls `define_object` with the vet's
  own noun.
  """
  use PawChart.DataCase, async: false

  alias Samen.CustomFields
  alias Samen.CustomObjects

  @clinic_a "00000000-0000-0000-0000-0000000000a1"
  @clinic_b "00000000-0000-0000-0000-0000000000b1"

  defp scope(org), do: %Samen.Scope{actor: %{org_id: org, role: :member}}

  defp define_object!(org_id, key, opts \\ []) do
    {:ok, row} =
      CustomObjects.define_object(Enum.into(opts, %{org_id: org_id, object_key: key}), PawChart.Repo)

    row
  end

  defp define_field!(org_id, key, field, type, opts \\ []) do
    {:ok, row} =
      CustomObjects.define_object_field(
        Enum.into(opts, %{org_id: org_id, object_key: key, field_name: field, type: type}),
        PawChart.Repo
      )

    row
  end

  defp validate_attrs(org_id, key, bag) do
    CustomFields.validate_bag(org_id, CustomObjects.object_table(key), bag, PawChart.Repo)
  end

  test "a clinic defines the VaccineLot object + fields — catalogued and ORG-SCOPED" do
    define_object!(@clinic_a, "vaccine_lot", label: "Vaccine Lot")
    define_field!(@clinic_a, "vaccine_lot", "lot_number", :string, constraints: %{max_length: 40})
    define_field!(@clinic_a, "vaccine_lot", "doses", :integer, constraints: %{min: 0})
    define_field!(@clinic_a, "vaccine_lot", "expires_on", :date)

    # Catalogued for clinic A.
    assert [obj] = CustomObjects.list_objects(@clinic_a, PawChart.Repo)
    assert obj.tnt_object_key == "vaccine_lot"
    assert length(CustomObjects.list_object_fields(@clinic_a, "vaccine_lot", PawChart.Repo)) == 3

    # ORG-SCOPED: clinic B sees nothing (the object is clinic A's, not global).
    assert CustomObjects.list_objects(@clinic_b, PawChart.Repo) == []
  end

  test "VaccineLot bag validated-at-write — undefined key / wrong type / constraint REJECTED" do
    define_object!(@clinic_a, "vaccine_lot")
    define_field!(@clinic_a, "vaccine_lot", "doses", :integer, constraints: %{min: 0, max: 1000})

    # Happy path.
    assert :ok = validate_attrs(@clinic_a, "vaccine_lot", %{"doses" => 500})

    # RED — undefined key.
    assert {:error, v1} = validate_attrs(@clinic_a, "vaccine_lot", %{"nope" => 1})
    assert Enum.any?(v1, fn {_f, r} -> match?({:undefined, _}, r) end)

    # RED — wrong type.
    assert {:error, v2} = validate_attrs(@clinic_a, "vaccine_lot", %{"doses" => "lots"})
    assert Enum.any?(v2, fn {_f, r} -> match?({:type, _}, r) end)

    # RED — constraint.
    assert {:error, v3} = validate_attrs(@clinic_a, "vaccine_lot", %{"doses" => 99_999})
    assert Enum.any?(v3, fn {_f, r} -> match?({:constraint, _}, r) end)
  end

  test "RED — a PII-shaped VaccineLot value is rejected (containment)" do
    define_object!(@clinic_a, "vaccine_lot")
    define_field!(@clinic_a, "vaccine_lot", "note", :string)

    assert {:error, v} = validate_attrs(@clinic_a, "vaccine_lot", %{"note" => "owner@example.com"})
    assert Enum.any?(v, fn {_f, r} -> match?({:pii_shaped, _}, r) end)
  end

  test "a VaccineLot tnt_record is created + read back ORG-SCOPED; cross-org read is []" do
    define_object!(@clinic_a, "vaccine_lot")
    define_field!(@clinic_a, "vaccine_lot", "lot_number", :string)

    {:ok, _record} =
      CustomObjects.create_record(scope(@clinic_a), "vaccine_lot", %{"lot_number" => "LOT-9001"})

    # Clinic A sees its own record.
    {:ok, a_records} = CustomObjects.list_records(scope(@clinic_a), "vaccine_lot")
    assert length(a_records) == 1
    assert hd(a_records).attributes["lot_number"] == "LOT-9001"

    # RED — clinic B reads its own vaccine_lot records: ZERO (org-scope contains the row).
    {:ok, b_records} = CustomObjects.list_records(scope(@clinic_b), "vaccine_lot")
    assert b_records == []
  end

  test "the one-way boundary holds — no PawChart system resource references INTO tnt_record" do
    # Sweep PawChart's real scope domains (registered under :samen_core :ash_domains).
    assert Mix.Tasks.Samen.Verify.TntBoundary.relationship_violations([]) == []
    # Structural half: no FK targets a tenant-regime table on the PawChart DB.
    assert Mix.Tasks.Samen.Verify.TntBoundary.fk_violations(repo: "PawChart.Repo") == []
  end
end
