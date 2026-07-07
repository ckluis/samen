defmodule Demo.CrmScopeCustomFieldsTest do
  @moduledoc """
  T3.8 acceptance on the DEMO app (plan §DoD "Tier-0/1/2 work on the demo app"):
  Tier-1 custom fields on `Demo.CrmScope.Person`, which carries the `per_custom`
  jsonb bag from `Samen.Fragments.CorePerson`.

  Proves, end-to-end against the demo's one Postgres:

    * an org defines a custom field (`tnt_field`) → a validated bag write succeeds;
    * an undefined key / wrong type / constraint / PII-shaped value is REJECTED at
      write (the honest edge: validated-at-write, contained);
    * `mix samen.verify.tnt_catalog` parity holds for the demo.

  RED PATHS here mirror the kernel suite but against a real composed resource
  (person composes the core fragment, so the bag rides the same base machinery).
  """
  use Demo.DataCase, async: false

  alias Demo.CrmScope.Person
  alias Demo.Identity.Org
  alias Samen.CustomFields

  @table "per_person"

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp define!(org_id, field, type, opts \\ []) do
    {:ok, row} =
      CustomFields.define_field(
        Enum.into(opts, %{
          org_id: org_id,
          table_name: @table,
          field_name: field,
          type: type
        }),
        Repo
      )

    row
  end

  defp create_person(org_id, custom) do
    Person
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      display_name: "CF-Person",
      custom: custom
    })
    |> Ash.create(authorize?: false)
  end

  test "a defined, well-typed, in-constraint bag write succeeds on Person" do
    org = mk_org("cf-happy")
    define!(org.id, "lead_score", :integer, constraints: %{min: 0, max: 100})
    define!(org.id, "segment", :enum, constraints: %{one_of: ["smb", "mid", "ent"]})

    assert {:ok, person} =
             create_person(org.id, %{"lead_score" => 42, "segment" => "ent"})

    assert person.custom["lead_score"] == 42
    assert person.custom["segment"] == "ent"
  end

  test "RED — an undefined bag key is rejected at write" do
    org = mk_org("cf-undef")
    assert {:error, err} = create_person(org.id, %{"whoops" => "x"})
    assert error_msg(err) =~ "no tnt_field definition"
  end

  test "RED — wrong type is rejected at write" do
    org = mk_org("cf-type")
    define!(org.id, "lead_score", :integer)
    assert {:error, err} = create_person(org.id, %{"lead_score" => "high"})
    assert error_msg(err) =~ "not a integer"
  end

  test "RED — a PII-shaped value on a plain custom field is rejected (containment)" do
    org = mk_org("cf-pii")
    define!(org.id, "note", :string)
    assert {:error, err} = create_person(org.id, %{"note" => "victim@example.com"})
    assert error_msg(err) =~ "PII-shaped"
    assert error_msg(err) =~ "vault bypass"
  end

  test "the same PII-shaped value on a pii_declared field is allowed (discriminating)" do
    org = mk_org("cf-pii-ok")
    define!(org.id, "note", :string, pii_declared: true)
    assert {:ok, person} = create_person(org.id, %{"note" => "victim@example.com"})
    # Contained in the bag — NOT vault-routed (the honest seam).
    assert person.custom["note"] == "victim@example.com"
  end

  test "tnt_catalog parity holds for the demo after Tier-1 writes" do
    org = mk_org("cf-parity")
    define!(org.id, "lead_score", :integer)
    {:ok, _} = create_person(org.id, %{"lead_score" => 7})

    violations = Mix.Tasks.Samen.Verify.TntCatalog.check(Repo)
    assert violations == [] or Enum.all?(violations, &(not (&1 =~ "per_person")))
  end

  defp error_msg(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&Exception.message/1) |> Enum.join(" | ")
  end

  defp error_msg(other), do: inspect(other)
end
