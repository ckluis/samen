defmodule Samen.Web.CsvMoneyTest do
  @moduledoc """
  ADR-036 D5/H7 (H1 done-criterion 3, T12): the `Samen.Web.Csv` `cell/1` clause for
  `Samen.Type.Money` — export renders the canonical `"CUR 12.34"` ISO-4217 cell
  string, and import parses that SAME string back into the identical Money value
  through the governed create action's `cast_input` (no new dependency, no data
  layer — extends the existing masked CSV surface per ADR-037 §5.11 REJECT
  ash_csv).

  Uses the CRM `Opportunity` resource's nullable `:value` Money attribute (no
  vault involvement — Money is non-PII, ADR-036 D1) mounted via the samen_web
  test-support host, mirroring `Samen.Web.CsvTest`'s Company/Person round-trip.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Csv
  alias Samen.Web.Plane

  alias Samen.WebTest.Crm.Opportunity

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp export!(resource, scope, opts \\ []) do
    {:ok, csv} = Csv.export(resource, scope, Keyword.put_new(opts, :repo, Samen.WebTest.Repo))
    csv
  end

  defp data_rows(csv) do
    [_header | rows] = Csv.parse(csv)
    rows
  end

  defp column_index(csv, name) do
    [header | _] = Csv.parse(csv)
    Enum.find_index(header, &(&1 == name))
  end

  describe "Catalog dump shows the money type (done-criterion 3, first half)" do
    test "Samen.Catalog.fields/1 reports the Opportunity :value column as \"Samen.Type.Money\"" do
      field =
        Opportunity
        |> Samen.Catalog.fields()
        |> Enum.find(&(&1.logical_name == "value"))

      refute is_nil(field)
      assert field.type == "Samen.Type.Money"
    end
  end

  describe "Money CSV export (the canonical cell)" do
    test "exports a Money attribute as \"CUR 12.34\" (ISO-4217 space amount)" do
      org_id = Ash.UUID.generate()
      scope = tenant_scope(org_id)

      Opportunity
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        name: "Acme renewal",
        value: Money.new!(:USD, "1234.50")
      })
      |> Ash.create!(scope: scope)

      csv = export!(Opportunity, scope)
      idx = column_index(csv, "value")
      [row] = data_rows(csv)

      assert Enum.at(row, idx) == "USD 1234.50"
    end

    test "a nil Money attribute exports as an empty cell" do
      org_id = Ash.UUID.generate()
      scope = tenant_scope(org_id)

      Opportunity
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "No value yet", value: nil})
      |> Ash.create!(scope: scope)

      csv = export!(Opportunity, scope)
      idx = column_index(csv, "value")
      [row] = data_rows(csv)

      assert Enum.at(row, idx) == ""
    end
  end

  describe "Money CSV import (round-trip through the governed create action)" do
    test "the exported \"CUR 12.34\" cell imports back to the IDENTICAL Money value" do
      org_id = Ash.UUID.generate()
      scope = tenant_scope(org_id)

      csv =
        "name,value\r\n" <>
          "Imported deal,EUR 999.01\r\n"

      {:ok, report} = Csv.import(Opportunity, scope, csv: csv)

      assert report.created == 1
      assert report.errors == []

      [record] =
        Opportunity
        |> Ash.Query.filter(name == "Imported deal")
        |> Ash.read!(scope: scope)

      assert Money.equal?(record.value, Money.new!(:EUR, "999.01"))
    end

    test "export → import is a value-exact round trip" do
      org_id = Ash.UUID.generate()
      scope = tenant_scope(org_id)

      Opportunity
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        name: "Round-trip deal",
        value: Money.new!(:GBP, "42.07")
      })
      |> Ash.create!(scope: scope)

      csv = export!(Opportunity, scope)

      other_org_id = Ash.UUID.generate()
      other_scope = tenant_scope(other_org_id)
      {:ok, report} = Csv.import(Opportunity, other_scope, csv: csv)

      assert report.created == 1
      assert report.errors == []

      [record] =
        Opportunity
        |> Ash.Query.filter(name == "Round-trip deal")
        |> Ash.read!(scope: other_scope)

      assert Money.equal?(record.value, Money.new!(:GBP, "42.07"))
    end
  end
end
