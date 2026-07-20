defmodule Samen.Web.CsvTest do
  @moduledoc """
  WS-E E3.1/E3.3/E3.4-adjacent functional suite for `Samen.Web.Csv` (ADR-028):

    * AC-G15-1 — export+import round-trip on TWO different resources (Company,
      Person) with no per-resource CSV code.
    * AC-G15-4 / RP-CSV-3 — export reads ONLY keyset pages; the bounded-read probe
      (`Reads.bounded!/4`) exercises the `Csv.page/4` seam directly.
    * AC-G15-3 — tenant import vault-routes PII (`vt_*` at rest, plaintext nowhere);
      operator import is refused ROW-BY-ROW by the governed chokepoint.
    * AC-G15-5 / RP-CSV-4 — bad mapping (`org_id`/`id`/unknown column) rejects the
      whole file fail-closed; a policy-violating row fails THAT row only.

  The per-plane export masking red-path (AC-G15-2) lives in `csv_masking_test.exs`.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Factory
  alias Samen.Masked
  alias Samen.Web.Csv
  alias Samen.Web.Csv.Report
  alias Samen.Web.ListState
  alias Samen.Web.Plane
  alias Samen.Web.Reads

  alias Samen.WebTest.Crm.Company
  alias Samen.WebTest.Crm.Person

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "csv-test-session"), org_id)

  defp seed_company!(%Samen.Scope{actor: %{org_id: org_id}} = scope, name, attrs \\ %{}) do
    Company
    |> Ash.Changeset.for_create(:create, Map.merge(%{name: name, org_id: org_id}, attrs))
    |> Ash.create!(scope: scope)
  end

  defp seed_person!(%Samen.Scope{actor: %{org_id: org_id}} = scope, first, last, attrs) do
    Factory.create!(
      Person,
      Factory.person(first, last) |> Map.merge(%{org_id: org_id}) |> Map.merge(attrs),
      scope
    )
  end

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

  # ==========================================================================
  # RFC 4180 (the ship-note decision: hand-rolled, no dependency)
  # ==========================================================================

  describe "RFC 4180 serialize/parse" do
    test "round-trips quoting, embedded commas, quotes, and newlines" do
      rows = [
        ["name", "notes"],
        ["Acme, Inc.", ~s(said "hi"\nthen left)],
        ["plain", ""]
      ]

      csv = Csv.serialize(rows)

      # Quoted where needed, CRLF row endings (RFC 4180).
      assert csv =~ ~s("Acme, Inc.")
      assert csv =~ "\r\n"
      assert Csv.parse(csv) == rows
    end

    test "parses LF-only input and escaped quotes" do
      assert Csv.parse("a,b\n\"x\"\"y\",z\n") == [["a", "b"], [~s(x"y), "z"]]
    end
  end

  # ==========================================================================
  # CSV formula injection (WS-F1 / F1.4, OWASP "CSV Injection")
  # RFC-4180 quoting alone does NOT stop a spreadsheet from EVALUATING a cell whose
  # first character is `= + - @` (or a leading TAB/CR shifting the payload). Export
  # cells must be defanged to literal text at the serialization chokepoint.
  # ==========================================================================

  # The single serialized field for a one-cell row, minus RFC-4180 quoting — so the
  # assertion inspects exactly what a spreadsheet would first see (independent of parse).
  defp exported_cell(payload) do
    Csv.serialize([[payload]]) |> String.trim_trailing("\r\n") |> unquote_field()
  end

  defp unquote_field("\"" <> rest),
    do: rest |> String.trim_trailing("\"") |> String.replace("\"\"", "\"")

  defp unquote_field(field), do: field

  describe "CSV formula-injection neutralization (WS-F1 / F1.4)" do
    test "neutralizes every formula-injection lead char on export" do
      payloads = [
        "=SUM(A1:A9)",
        "+1+1",
        "-2+3+cmd",
        "@SUM(1)",
        "\tcmd",
        "\rcmd",
        "=cmd|'/C calc'!A1",
        "=HYPERLINK(\"http://evil\",\"click\")"
      ]

      for payload <- payloads do
        cell = exported_cell(payload)

        assert String.starts_with?(cell, "'"),
               "expected #{inspect(payload)} to be neutralized, got #{inspect(cell)}"

        refute String.first(cell) in ["=", "+", "-", "@", "\t", "\r"],
               "a live-formula lead leaked for #{inspect(payload)}: #{inspect(cell)}"
      end
    end

    test "positive control: safe cells and plain negative numbers pass through verbatim" do
      # Anti-tautology — the neutralization DISCRIMINATES; it is not a blanket prefix.
      assert exported_cell("Acme") == "Acme"
      assert exported_cell("-5") == "-5"
      assert exported_cell("-42.5") == "-42.5"
      assert exported_cell("0") == "0"
    end

    test "export path: a formula payload in a record field is neutralized in the CSV" do
      org = Ash.UUID.generate()
      seed_company!(tenant_scope(org), "=HYPERLINK(\"http://evil.test\",\"click\")")

      csv = export!(Company, tenant_scope(org))
      idx = column_index(csv, "name")
      [row] = data_rows(csv)
      cell = Enum.at(row, idx)

      assert String.starts_with?(cell, "'")
      refute String.starts_with?(cell, "=")
    end
  end

  # ==========================================================================
  # AC-G15-1 — round-trip on TWO resources, zero per-resource CSV code
  # ==========================================================================

  describe "export+import round-trip (AC-G15-1)" do
    test "Company: export from one org, import into another — same generic calls" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      seed_company!(tenant_scope(org_a), "Acme, Inc.", %{domain: "acme.test", industry: "mfg"})
      seed_company!(tenant_scope(org_a), "Borealis", %{website: "https://borealis.test"})

      csv = export!(Company, tenant_scope(org_a))
      assert length(data_rows(csv)) == 2
      # The header is the catalog-derived logical column set — never id/org_id.
      [header | _] = Csv.parse(csv)
      refute "id" in header
      refute "org_id" in header

      {:ok, %Report{} = report} = Csv.import(Company, tenant_scope(org_b), csv: csv)
      assert report.created == 2
      assert report.errors == []

      names =
        Company
        |> Ash.Query.sort(:name)
        |> Ash.read!(scope: tenant_scope(org_b))
        |> Enum.map(& &1.name)

      assert names == ["Acme, Inc.", "Borealis"]
    end

    test "Person (vaulted composites): full_name survives the round trip" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      seed_person!(tenant_scope(org_a), "Ada", "Lovelace", %{display_name: "Ada L"})

      csv = export!(Person, tenant_scope(org_a))
      # Tenant-plane export carries the composite as JSON (plaintext — own org).
      assert csv =~ "Ada"

      {:ok, %Report{created: 1, errors: []}} = Csv.import(Person, tenant_scope(org_b), csv: csv)

      [imported] =
        Person
        |> Ash.Query.ensure_selected([:full_name, :display_name])
        |> Ash.read!(scope: tenant_scope(org_b))

      # Read back on the owning tenant plane → plaintext composite round-tripped.
      [resolved] =
        Samen.Api.PiiResolution.resolve([imported], Person, %{plane: :tenant},
          repo: Samen.WebTest.Repo
        )

      assert resolved.display_name == "Ada L"
      assert %{first: "Ada", last: "Lovelace"} = struct_or_map(resolved.full_name)
    end
  end

  # The revealed composite plaintext may come back as the struct, a map, or its
  # JSON-serialized form (the vault stores the composite serialized) — normalize.
  defp struct_or_map(%_{} = s), do: Map.from_struct(s)

  defp struct_or_map(%{} = m),
    do: Map.new(m, fn {k, v} -> {if(is_binary(k), do: String.to_existing_atom(k), else: k), v} end)

  defp struct_or_map(json) when is_binary(json), do: json |> Jason.decode!() |> struct_or_map()

  # ==========================================================================
  # AC-G15-4 / RP-CSV-3 — bounded keyset export
  # ==========================================================================

  describe "bounded export (AC-G15-4)" do
    test "export pages through the keyset — 25 rows at page_size 10, all present once" do
      org_id = Ash.UUID.generate()
      scope = tenant_scope(org_id)

      for n <- 1..25, do: seed_company!(scope, "co-#{String.pad_leading("#{n}", 2, "0")}")

      csv = export!(Company, scope, page_size: 10)
      rows = data_rows(csv)
      name_idx = column_index(csv, "name")

      names = Enum.map(rows, &Enum.at(&1, name_idx))
      assert length(names) == 25
      # Keyset iteration: no duplicates, no skips.
      assert Enum.sort(names) == Enum.sort(Enum.uniq(names))
    end

    test "RP-CSV-3: the export read seam is BOUNDED (the bounded-read probe)" do
      org_id = Ash.UUID.generate()
      scope = tenant_scope(org_id)
      for n <- 1..15, do: seed_company!(scope, "probe-#{n}")

      # The probe seeds > page_size rows and PROVES the seam cannot return the
      # full set. Sabotaging Csv.page/4 to a raw unbounded Ash.read! raises
      # UnboundedReadError here — the RP-CSV-3 named test.
      assert :ok ==
               Reads.bounded!(
                 fn _mount, probe_scope, %ListState{} = state ->
                   Csv.page(Company, probe_scope, state)
                 end,
                 nil,
                 scope,
                 page_size: 10
               )
    end
  end

  # ==========================================================================
  # AC-G15-3 — import through the governed chokepoint (vault-routing + plane)
  # ==========================================================================

  describe "governed import (AC-G15-3)" do
    test "tenant import vault-routes PII: vt_* at rest, plaintext NOWHERE in the row" do
      org_id = Ash.UUID.generate()

      csv =
        Csv.serialize([
          ["display_name", "full_name"],
          ["Row One", ~s({"first":"Vaultina","last":"Csv-Secret"})]
        ])

      {:ok, %Report{created: 1, errors: []}} = Csv.import(Person, tenant_scope(org_id), csv: csv)

      [person] =
        Person
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read!(scope: tenant_scope(org_id))

      # At rest the composite is the vault token wrapper — never plaintext.
      assert %Masked{token: "vt_" <> _} = person.full_name

      # The RAW physical row: vault token present, plaintext absent (RP-CSV-2's
      # named scan — an insert_all sabotage lands plaintext here and FAILS this).
      %{rows: [[raw_row]]} =
        Samen.WebTest.Repo.query!(
          "SELECT to_jsonb(t)::text FROM swp_person t WHERE swp_id = $1",
          [Ecto.UUID.dump!(person.id)]
        )

      assert raw_row =~ "vt_"
      refute raw_row =~ "Vaultina"
      refute raw_row =~ "Csv-Secret"
    end

    test "operator import is refused ROW-BY-ROW (the chokepoint, not a bulk gate)" do
      org_id = Ash.UUID.generate()

      csv =
        Csv.serialize([
          ["display_name", "full_name"],
          ["Op Row 1", ~s({"first":"Nope","last":"One"})],
          ["Op Row 2", ~s({"first":"Nope","last":"Two"})]
        ])

      {:ok, %Report{} = report} = Csv.import(Person, operator_scope(org_id), csv: csv)

      # Every row individually refused by the same guard that refuses the form;
      # nothing written.
      assert report.created == 0
      assert length(report.errors) == 2
      assert Enum.map(report.errors, & &1.row) == [1, 2]

      assert [] == Ash.read!(Person, scope: tenant_scope(org_id))
    end
  end

  # ==========================================================================
  # AC-G15-5 / RP-CSV-4 — fail-closed mapping + per-row policy failure
  # ==========================================================================

  describe "fail-closed mapping (AC-G15-5)" do
    test "a column mapped to org_id rejects the WHOLE file before any write (RP-CSV-4)" do
      org_id = Ash.UUID.generate()
      other_org = Ash.UUID.generate()

      csv =
        Csv.serialize([
          ["name", "org_id"],
          ["Smuggler Corp", other_org]
        ])

      # The cross-org org_id write is refused at the MAPPING, fail-closed —
      # sabotaging validate_mapping to allow it FAILS this named test.
      assert {:error, {:bad_mapping, ["org_id"]}} =
               Csv.import(Company, tenant_scope(org_id), csv: csv)

      assert [] == Ash.read!(Company, scope: tenant_scope(org_id))
    end

    test "id and unknown/private columns are equally rejected" do
      org_id = Ash.UUID.generate()

      assert {:error, {:bad_mapping, ["id"]}} =
               Csv.import(Company, tenant_scope(org_id),
                 csv: Csv.serialize([["id", "name"], ["x", "y"]])
               )

      assert {:error, {:bad_mapping, ["shoe_size"]}} =
               Csv.import(Company, tenant_scope(org_id),
                 csv: Csv.serialize([["name", "shoe_size"], ["x", "9"]])
               )
    end

    test "a policy-violating row fails THAT row; valid rows still import" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      # A company in ANOTHER org — referencing it violates SameOrgFk for org_a.
      foreign_company = seed_company!(tenant_scope(org_b), "Foreign Co")

      csv =
        Csv.serialize([
          ["display_name", "company_id"],
          ["Good Row", ""],
          ["Bad Row", foreign_company.id]
        ])

      {:ok, %Report{} = report} = Csv.import(Person, tenant_scope(org_a), csv: csv)

      assert report.created == 1
      assert [%{row: 2}] = report.errors

      assert ["Good Row"] ==
               Person |> Ash.read!(scope: tenant_scope(org_a)) |> Enum.map(& &1.display_name)
    end
  end
end
