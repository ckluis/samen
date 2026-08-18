defmodule Samen.Web.RichTypesRoundTripTest do
  @moduledoc """
  ADR-036 H7 (T15 done-criteria 3/4): the round-trip matrix proving `Samen.Catalog.
  fields/1`, the per-plane masked render, and `Samen.Web.Csv` honor EVERY new
  rich type "by construction" — the ADR's own H7 claim once T12/T13/T14's D5
  clauses land. `Samen.WebTest.RichTypes.Item` (`test/support/rich_types.ex`)
  carries every H1-H4 type, split the same non-PII/PII-by-type way T13/T14's
  samen_core fixtures do.

  Two table-driven matrices (done-criterion 3: "ONE table-driven test, one row
  per type"):

    * `"non-PII-by-type matrix"` — money/percent/score/duration/priority/url
      (ADR-036 D1/D2): catalog dump entry + NEVER masked on ANY plane (the
      correct "masked render" proof for a type that isn't PII) + CSV
      export→import value-exact round trip.
    * `"PII-by-type matrix"` — email/phone/address (ADR-036 D3/D4): catalog
      dump entry + the FULL `Samen.MaskingCase` 3-proof (tenant clear /
      operator `••••` / sabotage-twin leak-detection) + CSV export→import.

  Done-criterion 4 (INV-1, house masking watch-list, CSV named explicitly) gets
  its OWN dedicated describe block below: the operator-plane CSV export of the
  vaulted Address field renders the mask glyph — NEVER plaintext, NEVER a
  `vt_*` token — while the tenant-plane export resolves plaintext (control),
  per the ADR-028 mask-by-omission precedent `Samen.Web.CsvMaskingTest`
  already proves for `Person.full_name`.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Web.Csv
  alias Samen.Web.Plane
  alias Samen.WebTest.RichTypes.Item

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "rich-types-session"), org_id)

  # `pii_attribute`s (and, like any Ash attribute, an attribute set on THIS
  # create) are not automatically selected on the returned struct — explicitly
  # load the whole rich-type surface so every field is readable right after
  # create (mirrors the generator's `--live` show/form screens' own
  # `ensure_selected/2` discipline for the one 🔒 field).
  @all_fields ~w(money percent score duration priority website contact_email
                 contact_phone mailing_address email phone address)a

  defp create!(attrs, org_id) do
    Item
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :org_id, org_id),
      scope: tenant_scope(org_id)
    )
    |> Ash.create!()
    |> Ash.load!(@all_fields, scope: tenant_scope(org_id))
  end

  # This fixture carries no RBAC/OrgScope policies (it exists purely to prove
  # catalog/CSV/masking behavior, not multi-tenant read authorization — the
  # samen_core T13/T14 rich-type fixtures are un-policied for the same reason),
  # so every read/export in this test explicitly scopes by `org_id` itself
  # rather than relying on ambient policy filtering — the shared sandbox
  # transaction accumulates rows across the table-driven loop's iterations.
  defp org_query(org_id), do: Item |> Ash.Query.filter(org_id == ^org_id)

  defp export!(scope, org_id, cols) do
    {:ok, csv} =
      Csv.export(Item, scope, repo: Samen.WebTest.Repo, columns: cols, query: org_query(org_id))

    csv
  end

  defp cell_of(csv, col_name) do
    [header | rows] = Csv.parse(csv)
    idx = Enum.find_index(header, &(&1 == col_name))
    assert idx, "#{col_name} missing from export header: #{inspect(header)}"
    [row] = rows
    Enum.at(row, idx)
  end

  defp import_and_read!(csv, org_id, name) do
    {:ok, report} = Csv.import(Item, tenant_scope(org_id), csv: csv)
    assert report.errors == [], "unexpected import errors: #{inspect(report.errors)}"
    assert report.created == 1

    [record] =
      org_id
      |> org_query()
      |> Ash.Query.filter(name == ^name)
      |> Ash.Query.ensure_selected(@all_fields)
      |> Ash.read!(scope: tenant_scope(org_id))

    record
  end

  # ==========================================================================
  # Catalog dump — every new type dumps its OWN module name (D5)
  # ==========================================================================

  describe "catalog dump entry (H7 done-criterion 3, column 1)" do
    test "every new rich-type attribute dumps its own Samen.Type module name" do
      fields = Item |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})

      assert fields["money"] == "Samen.Type.Money"
      assert fields["percent"] == "Samen.Type.Percent"
      assert fields["score"] == "Samen.Type.Score"
      assert fields["duration"] == "Samen.Type.Duration"
      assert fields["priority"] == "Samen.Type.Priority"
      assert fields["website"] == "Samen.Type.URL"
      # The PII-by-type trio's catalog identity is proven via their PLAIN twins
      # (see moduledoc): `email`/`phone`/`address` are VAULTED, so they
      # correctly dump "Samen.Type.VaultField" (the materialized storage type,
      # not the declared logical type) — proven separately below.
      assert fields["contact_email"] == "Samen.Type.EmailAddress"
      assert fields["contact_phone"] == "Samen.Type.PhoneNumber"
      assert fields["mailing_address"] == "Samen.Type.Address"
    end

    test "a VAULTED pii_attribute dumps Samen.Type.VaultField — the materialized storage type, not the declared logical type (documented, not a bug)" do
      fields = Item |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})

      assert fields["email"] == "Samen.Type.VaultField"
      assert fields["phone"] == "Samen.Type.VaultField"
      assert fields["address"] == "Samen.Type.VaultField"
    end
  end

  # ==========================================================================
  # NON-PII-by-type matrix (money/percent/score/duration/priority/url)
  # ==========================================================================

  describe "H7 round-trip matrix — non-PII-by-type (ADR-036 D1/D2)" do
    test "ONE table-driven test: never masked on any plane + CSV export/import round-trip" do
      table = [
        {:money, Money.new!(:USD, "1234.50"), "USD 1234.50", &Money.equal?/2},
        {:percent, Decimal.new("42.50"), "42.50", &Decimal.equal?/2},
        {:score, Decimal.new("87"), "87", &Decimal.equal?/2},
        {:duration, 5400, "PT5400S", &Kernel.==/2},
        {:priority, :high, "high", &Kernel.==/2},
        {:website, "https://example.test/x", "https://example.test/x", &Kernel.==/2}
      ]

      for {field, value, expected_cell, equal?} <- table do
        org_id = Ash.UUID.generate()
        name = "rt-#{field}-#{System.unique_integer([:positive])}"
        record = create!(%{field => value, name: name}, org_id)

        got = Map.fetch!(record, field)

        assert equal?.(got, value),
               "#{field}: expected #{inspect(value)}, got #{inspect(got)} (tenant plane, clear control)"

        # MASKED RENDER — the correct proof for a type that is NOT PII: it stays
        # clear on the operator plane too (never masked, on ANY plane).
        operator_resolved =
          resolve_on_plane(record, Item, :operator, repo: Samen.WebTest.Repo)

        operator_value = Map.fetch!(operator_resolved, field)
        refute match?(%Samen.Masked{}, operator_value), "#{field} must NEVER mask (non-PII-by-type)"
        assert equal?.(operator_value, value), "#{field} must render CLEAR on the operator plane too"

        # CSV round-trip — the canonical export cell, then export→import equality.
        csv = export!(tenant_scope(org_id), org_id, [:name, field])
        assert cell_of(csv, Atom.to_string(field)) == expected_cell

        reimported = import_and_read!(csv, Ash.UUID.generate(), name)
        assert equal?.(Map.fetch!(reimported, field), value), "#{field} import round-trip mismatch"
      end
    end
  end

  # ==========================================================================
  # PII-by-type matrix (email/phone/address) — the FULL MaskingCase 3-proof
  # ==========================================================================

  describe "H7 round-trip matrix — PII-by-type (ADR-036 D3/D4): the MaskingCase 3-proof" do
    test "ONE table-driven test: tenant clear / operator masked / sabotage-twin leak-detection + CSV" do
      table = [
        {:email, "secret-#{System.unique_integer([:positive])}@example.test"},
        {:phone, "+15550100100"},
        {:address,
         %Samen.Type.Address{
           line1: "123 Secret Ave",
           city: "Cryptoville",
           region: "CV",
           postal_code: "00000",
           country: "US"
         }}
      ]

      for {field, value} <- table do
        org_id = Ash.UUID.generate()
        name = "rt-#{field}-#{System.unique_integer([:positive])}"
        record = create!(%{field => value, name: name}, org_id)

        # GREEN — tenant plane resolves CLEAR. A vaulted SCALAR (email/phone)
        # reveals as the re-cast logical value; a vaulted COMPOSITE (address)
        # reveals as the raw JSON string `Samen.Vault.reveal/2` itself returns
        # (`Samen.Type.Address.cast_input`'s target is the write path, not an
        # automatic read-side re-cast — proven directly in
        # `samen_core/test/type/address_test.exs`'s own reveal assertion) —
        # `assert_resolved_matches!/2` compares the RIGHT shape per field.
        tenant_resolved = resolve_on_plane(record, Item, :tenant, repo: Samen.WebTest.Repo)
        tenant_value = Map.fetch!(tenant_resolved, field)
        refute match?(%Samen.Masked{}, tenant_value)
        assert_resolved_matches!(tenant_value, value)

        # RED — operator (impersonation, no grant) resolves MASKED.
        operator_resolved = resolve_on_plane(record, Item, :operator, repo: Samen.WebTest.Repo)
        operator_value = assert_plane_masked!(Map.fetch!(operator_resolved, field), value)
        assert to_string(operator_value) == Samen.MaskingCase.mask()

        # SABOTAGE TWIN — the mask scan is refutable: a modeled render fed the
        # leaked plaintext IS caught by the same scan the red half relies on.
        leaked_html = "<td>#{inspect(value)}</td>"
        assert_leak_detected!(leaked_html, plaintext_needle(value))

        # CSV — tenant export is plaintext; operator export is the mask glyph,
        # never plaintext, never a vt_* token (done-criterion 4, folded in here
        # for email/phone; Address gets its OWN dedicated proof below).
        tenant_csv = export!(tenant_scope(org_id), org_id, [:name, field])
        assert_csv_cell_matches!(cell_of(tenant_csv, Atom.to_string(field)), csv_cell(value))

        operator_csv = export!(operator_scope(org_id), org_id, [:name, field])
        assert cell_of(operator_csv, Atom.to_string(field)) == Samen.MaskingCase.mask()
        refute operator_csv =~ "vt_"
        refute_leaks(operator_csv, value)

        # CSV import round-trip (tenant plane, plaintext exported → plaintext imported).
        reimported = import_and_read!(tenant_csv, Ash.UUID.generate(), name)
        reimported_resolved = resolve_on_plane(reimported, Item, :tenant, repo: Samen.WebTest.Repo)
        assert_resolved_matches!(Map.fetch!(reimported_resolved, field), value)
      end
    end
  end

  defp plaintext_needle("+" <> _ = phone), do: phone
  defp plaintext_needle(email) when is_binary(email), do: email
  defp plaintext_needle(%Samen.Type.Address{line1: line1}), do: line1

  # The resolved-clear comparison per field shape (see the GREEN comment above).
  defp assert_resolved_matches!(resolved, expected) when is_binary(expected) do
    assert resolved == expected
  end

  defp assert_resolved_matches!(resolved, %Samen.Type.Address{} = expected) do
    assert is_binary(resolved), "expected the revealed Address to be the raw JSON string, got: #{inspect(resolved)}"
    assert {:ok, decoded} = Jason.decode(resolved)
    # The vault's own reveal JSON keeps nil-valued fields (see
    # `address_test.exs`'s reveal assertion); the CSV export path strips them
    # (`compact/1`). Reject nils on both sides so this ONE helper serves both
    # the direct-resolve comparison and the CSV-cell comparison below.
    normalized = decoded |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    assert normalized == csv_cell(expected)
  end

  defp csv_cell(email) when is_binary(email), do: email

  defp csv_cell(%Samen.Type.Address{} = addr) do
    addr
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # For a string cell (email/phone), the real export cell must equal the plain
  # string exactly. For an Address cell, compare the DECODED JSON objects (not
  # the raw bytes) — Jason's map key order is deterministic for a given key set
  # but this keeps the assertion robust to that implementation detail either way.
  defp assert_csv_cell_matches!(actual, expected) when is_binary(expected) do
    assert actual == expected
  end

  defp assert_csv_cell_matches!(actual, %{} = expected) do
    assert {:ok, decoded} = Jason.decode(actual)
    # The vaulted Address's tenant-plane cell is the raw REVEALED JSON (nils
    # kept, see `assert_resolved_matches!/2`'s comment) — reject nils before
    # comparing to the nil-stripped `csv_cell/1` expectation.
    normalized = decoded |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    assert normalized == expected
  end

  defp refute_leaks(csv, %Samen.Type.Address{} = addr) do
    for {_k, v} <- Map.from_struct(addr), is_binary(v) do
      refute csv =~ v, "address field #{inspect(v)} leaked into the operator CSV export"
    end
  end

  defp refute_leaks(csv, plaintext) when is_binary(plaintext) do
    refute csv =~ plaintext, "plaintext #{inspect(plaintext)} leaked into the operator CSV export"
  end

  # ==========================================================================
  # Done-criterion 4 (INV-1) — the DEDICATED Address CSV masking proof, mirroring
  # `Samen.Web.CsvMaskingTest`'s green/red/sabotage shape exactly.
  # ==========================================================================

  describe "masked CSV (INV-1, done-criterion 4) — Address, the house masking watch-list" do
    @addr %Samen.Type.Address{
      line1: "999 Vault Blvd",
      city: "Cipherton",
      region: "CT",
      postal_code: "99999",
      country: "US"
    }

    test "GREEN: tenant own-org export carries the vaulted Address in the CLEAR" do
      org_id = Ash.UUID.generate()
      create!(%{name: "addr-green", address: @addr}, org_id)

      csv = export!(tenant_scope(org_id), org_id, [:name, :address])
      assert csv =~ "999 Vault Blvd"
      assert csv =~ "Cipherton"
      refute csv =~ "vt_"
    end

    test "RED: operator export cell is •••• — NEVER plaintext, NEVER a vt_ token (ADR-028 precedent)" do
      org_id = Ash.UUID.generate()
      create!(%{name: "addr-red", address: @addr}, org_id)

      csv = export!(operator_scope(org_id), org_id, [:name, :address])

      assert_masked_dom!(csv, ["999 Vault Blvd", "Cipherton"])
      assert cell_of(csv, "address") == Samen.MaskingCase.mask()
    end

    test "ANTI-TAUTOLOGY: the SAME row exported on the tenant plane goes CLEAR (plane flip)" do
      org_id = Ash.UUID.generate()
      create!(%{name: "addr-flip", address: @addr}, org_id)

      operator_csv = export!(operator_scope(org_id), org_id, [:name, :address])
      assert_masked_dom!(operator_csv, ["999 Vault Blvd"])

      tenant_csv = export!(tenant_scope(org_id), org_id, [:name, :address])
      assert tenant_csv =~ "999 Vault Blvd"
      refute tenant_csv =~ Samen.MaskingCase.mask()
    end

    test "ANTI-TAUTOLOGY: a modeled raw vt_ token export IS caught by the leak scan" do
      leaked_csv = Csv.serialize([["address"], ["vt_deadbeef1234"]])
      assert_leak_detected!(leaked_csv, "vt_")
    end
  end
end
