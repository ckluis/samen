defmodule Demo.TntObjectScopeTest do
  @moduledoc """
  T3.9 acceptance on the DEMO app (plan §DoD "Tier-0/1/2 work on the demo app"):
  Tier-2 custom objects dogfooded against the demo's one Postgres (`Demo.Repo`).

  Proves, end-to-end against a real DB:

    * an org defines a custom OBJECT (`tnt_object`) + its fields (`tnt_field`,
      shared with Tier-1) → the object + fields are catalogued and org-scoped;
    * an attribute bag validates against the object's fields (the SAME
      validated-at-write engine as Tier-1) — an undefined key / wrong type /
      PII-shaped value is REJECTED;
    * the ONE-WAY BOUNDARY holds on the demo: `mix samen.verify.tnt_boundary`
      finds no demo scope resource referencing INTO `tnt_record`, and no FK targets
      a tenant-regime table;
    * `mix samen.verify.tnt_catalog` parity holds for the demo's Tier-2 data.

  Note (R11 minimal-viable seam): the `Samen.CustomObjects.Record` Ash resource is
  a kernel resource whose backing repo is compile-bound in samen_core; the demo
  dogfoods the object/field-definition + validation + catalog + boundary machinery
  (all repo-parametric at runtime) against `Demo.Repo`. Record-row CRUD through the
  Ash resource is proven end-to-end in the kernel suite (`custom_objects_test.exs`).
  """
  use Demo.DataCase, async: false

  alias Demo.Identity.Org
  alias Samen.CustomFields
  alias Samen.CustomObjects

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp define_object!(org_id, key, opts \\ []) do
    {:ok, row} =
      CustomObjects.define_object(Enum.into(opts, %{org_id: org_id, object_key: key}), Repo)

    row
  end

  defp define_field!(org_id, key, field, type, opts \\ []) do
    {:ok, row} =
      CustomObjects.define_object_field(
        Enum.into(opts, %{org_id: org_id, object_key: key, field_name: field, type: type}),
        Repo
      )

    row
  end

  # A custom object's attribute bag validates through the SAME Tier-1 engine, keyed
  # on the object's synthetic table name.
  defp validate_attrs(org_id, key, bag) do
    CustomFields.validate_bag(org_id, CustomObjects.object_table(key), bag, Repo)
  end

  test "an org defines a custom object + fields — catalogued and org-scoped" do
    a = mk_org("clinic-a")
    b = mk_org("clinic-b")

    define_object!(a.id, "vaccine_lot", label: "Vaccine Lot")
    define_field!(a.id, "vaccine_lot", "lot_number", :string, constraints: %{max_length: 40})
    define_field!(a.id, "vaccine_lot", "doses", :integer, constraints: %{min: 0})

    # Catalogued for org A.
    assert [obj] = CustomObjects.list_objects(a.id, Repo)
    assert obj.tnt_object_key == "vaccine_lot"
    assert length(CustomObjects.list_object_fields(a.id, "vaccine_lot", Repo)) == 2

    # Org-scoped: org B sees nothing.
    assert CustomObjects.list_objects(b.id, Repo) == []
  end

  test "attribute bag validated-at-write against the object's fields" do
    a = mk_org("clinic-validate")
    define_object!(a.id, "vaccine_lot")
    define_field!(a.id, "vaccine_lot", "doses", :integer, constraints: %{min: 0, max: 1000})

    # Happy path.
    assert :ok = validate_attrs(a.id, "vaccine_lot", %{"doses" => 500})

    # RED — undefined key.
    assert {:error, v1} = validate_attrs(a.id, "vaccine_lot", %{"nope" => 1})
    assert Enum.any?(v1, fn {_f, r} -> match?({:undefined, _}, r) end)

    # RED — wrong type.
    assert {:error, v2} = validate_attrs(a.id, "vaccine_lot", %{"doses" => "lots"})
    assert Enum.any?(v2, fn {_f, r} -> match?({:type, _}, r) end)

    # RED — constraint.
    assert {:error, v3} = validate_attrs(a.id, "vaccine_lot", %{"doses" => 99_999})
    assert Enum.any?(v3, fn {_f, r} -> match?({:constraint, _}, r) end)
  end

  test "RED — a PII-shaped attribute value is rejected (containment, same as Tier-1)" do
    a = mk_org("clinic-pii")
    define_object!(a.id, "note_object")
    define_field!(a.id, "note_object", "note", :string)

    assert {:error, v} = validate_attrs(a.id, "note_object", %{"note" => "victim@example.com"})
    assert Enum.any?(v, fn {_f, r} -> match?({:pii_shaped, _}, r) end)
  end

  test "the one-way boundary holds on the demo (no scope resource references tnt_record)" do
    # Sweep the demo's real scope domains (registered under :samen_core :ash_domains).
    assert Mix.Tasks.Samen.Verify.TntBoundary.relationship_violations([]) == []
    # Structural half: no FK targets a tenant-regime table on the demo DB.
    assert Mix.Tasks.Samen.Verify.TntBoundary.fk_violations(repo: "Demo.Repo") == []
  end

  test "tnt_catalog parity holds for the demo's Tier-2 objects/fields" do
    a = mk_org("clinic-parity")
    define_object!(a.id, "vaccine_lot")
    define_field!(a.id, "vaccine_lot", "lot", :string)

    violations = Mix.Tasks.Samen.Verify.TntCatalog.check(Repo)
    # No Tier-2 orphan (every object field references a defined tnt_object).
    assert Enum.all?(violations, &(not (&1 =~ "orphan custom-object field")))
    assert Enum.all?(violations, &(not (&1 =~ "orphan tnt_record")))
  end
end
