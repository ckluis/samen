defmodule SamenCore.CustomFieldsTest do
  @moduledoc """
  T3.8 — Tier-1 custom fields: `xxx_custom` jsonb bag + `tnt_field` metadata +
  validated-at-write + containment + catalog parity.

  Covers all four sub-deliverables:

    (a) the `xxx_custom` bag exists on the fixture resource and is abbrev-prefixed
        (`tcf_custom`), sealed (a plain `:map`, no FK from any system table into
        content).
    (b) `tnt_field` runtime metadata: define a field, write validated against it;
        an invalid *shape* (undefined key / wrong type / constraint) is REJECTED
        at write.
    (c) catalogued: custom fields appear in `tnt_field` (the tnt-namespaced
        surface) and `mix samen.verify.tnt_catalog` parity holds; an invisible
        custom field FAILS the parity check.
    (d) containment: a PII-shaped value on a non-PII-declared custom field is
        REJECTED (fail-closed); the jsonb zone is sealed.

  MANDATORY RED PATHS:
    1. invalid-shape write rejected (undefined key + wrong type + constraint).
    2. PII-shaped value in a plain custom field rejected.
    3. custom field invisible to catalog fails its parity check.
  """
  use ExUnit.Case, async: false

  alias Samen.CustomFields
  alias Samen.CustomFields.FieldRow
  alias SamenCore.Support.CustomFields.Widget
  alias SamenCore.TestRepo

  @table "tcf_widget"
  # ADR-046 §4.2 D3: a `pii_declared: true` define is refused unless a custom-bag
  # erasure spec covers the table (the fail-closed guard). This fixture wires it,
  # modeling a compliant host; the guard's refusal path is proven explicitly below.
  @erasure_spec %{
    table_name: @table,
    bag_column: "tcf_custom",
    subject_column: "tcf_id",
    org_column: "tcf_org_id"
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp org, do: Ash.UUID.generate()

  defp define!(org_id, field, type, opts \\ []) do
    {:ok, row} =
      CustomFields.define_field(
        Enum.into(opts, %{
          org_id: org_id,
          table_name: @table,
          field_name: field,
          type: type,
          erasure_specs: [@erasure_spec]
        }),
        TestRepo
      )

    row
  end

  defp create_widget(org_id, custom) do
    Widget
    |> Ash.Changeset.for_create(:create, %{name: "w", org_id: org_id, custom: custom},
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  # ==========================================================================
  # (a) the bag exists, is abbrev-prefixed, sealed
  # ==========================================================================

  describe "(a) xxx_custom bag" do
    test "the custom bag is materialized as tcf_custom (abbrev-prefixed :map)" do
      attr = Ash.Resource.Info.attribute(Widget, :custom)
      assert attr.source == :tcf_custom
      assert attr.type == Ash.Type.Map
    end

    test "the sealed jsonb zone: no system table has an FK into bag content" do
      # tnt_field describes bag *keys*, never references bag *values*; the bag is a
      # plain :map column. Assert no FK constraint anywhere targets tcf_custom.
      %{rows: rows} =
        TestRepo.query!("""
        SELECT 1
        FROM information_schema.constraint_column_usage ccu
        JOIN information_schema.table_constraints tc
          ON tc.constraint_name = ccu.constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND ccu.column_name = 'tcf_custom'
        """)

      assert rows == []
    end
  end

  # ==========================================================================
  # (b) define + validated-at-write happy path
  # ==========================================================================

  describe "(b) validated-at-write happy path" do
    test "a defined, well-typed, in-constraint bag write succeeds" do
      o = org()
      define!(o, "loyalty_tier", :enum, constraints: %{one_of: ["gold", "silver", "bronze"]})
      define!(o, "seats", :integer, constraints: %{min: 1, max: 100})
      define!(o, "active", :boolean)

      assert {:ok, widget} =
               create_widget(o, %{"loyalty_tier" => "gold", "seats" => 5, "active" => true})

      assert widget.custom["loyalty_tier"] == "gold"
      assert widget.custom["seats"] == 5
    end

    test "an untouched bag (no custom write) is unaffected" do
      o = org()
      assert {:ok, _} = create_widget(o, nil)
    end
  end

  # ==========================================================================
  # (b/RED 1) invalid-shape write REJECTED
  # ==========================================================================

  describe "RED 1 — invalid shape rejected at write" do
    test "undefined key is rejected (uncatalogued custom field)" do
      o = org()
      # no define! at all
      assert {:error, %Ash.Error.Invalid{} = err} =
               create_widget(o, %{"mystery" => "x"})

      assert error_msg(err) =~ "no tnt_field definition"
    end

    test "wrong type is rejected" do
      o = org()
      define!(o, "seats", :integer)

      assert {:error, err} = create_widget(o, %{"seats" => "not-an-int"})
      assert error_msg(err) =~ "not a integer"
    end

    test "constraint violation is rejected (enum one_of)" do
      o = org()
      define!(o, "loyalty_tier", :enum, constraints: %{one_of: ["gold", "silver"]})

      assert {:error, err} = create_widget(o, %{"loyalty_tier" => "platinum"})
      assert error_msg(err) =~ "constraint violated"
    end

    test "constraint violation is rejected (integer max)" do
      o = org()
      define!(o, "seats", :integer, constraints: %{max: 10})

      assert {:error, err} = create_widget(o, %{"seats" => 999})
      assert error_msg(err) =~ "constraint violated"
    end

    test "a defined field with a valid value is NOT rejected (anti-tautology: the rule discriminates)" do
      o = org()
      define!(o, "seats", :integer, constraints: %{max: 10})
      assert {:ok, _} = create_widget(o, %{"seats" => 3})
    end
  end

  # ==========================================================================
  # (d/RED 2) PII-shaped value in a plain custom field REJECTED
  # ==========================================================================

  describe "RED 2 — PII-shaped value in a plain custom field rejected (containment)" do
    test "an email-shaped value on a plain string field is rejected" do
      o = org()
      define!(o, "notes", :string)

      assert {:error, err} = create_widget(o, %{"notes" => "alice@example.com"})
      assert error_msg(err) =~ "PII-shaped"
      assert error_msg(err) =~ "vault bypass"
    end

    test "an SSN-shaped value is rejected" do
      o = org()
      define!(o, "notes", :string)
      assert {:error, err} = create_widget(o, %{"notes" => "123-45-6789"})
      assert error_msg(err) =~ "PII-shaped"
    end

    test "a name-shaped value is rejected" do
      o = org()
      define!(o, "notes", :string)
      assert {:error, err} = create_widget(o, %{"notes" => "Alice Anderson"})
      assert error_msg(err) =~ "PII-shaped"
    end

    test "the SAME PII-shaped value on a pii_declared field is ALLOWED (discriminating, not blanket-deny)" do
      o = org()
      define!(o, "care_note", :string, pii_declared: true)
      assert {:ok, widget} = create_widget(o, %{"care_note" => "alice@example.com"})
      # Contained, NOT vault-routed: the bag holds the plaintext (the honest seam).
      assert widget.custom["care_note"] == "alice@example.com"
    end

    test "a plain non-PII-shaped string is allowed (anti-tautology: containment isn't reject-all)" do
      o = org()
      define!(o, "notes", :string)
      assert {:ok, _} = create_widget(o, %{"notes" => "friendly-handle-42"})
    end
  end

  # ==========================================================================
  # (c) catalogued: tnt_field surface + parity
  # ==========================================================================

  describe "(c) catalogued in tnt_field" do
    test "defined fields are listed in the tnt catalog surface, org-scoped" do
      o1 = org()
      o2 = org()
      define!(o1, "seats", :integer)
      define!(o1, "tier", :enum, constraints: %{one_of: ["a", "b"]})
      define!(o2, "seats", :integer)

      names = CustomFields.list_fields(o1, @table, TestRepo) |> Enum.map(& &1.tnt_field_name)
      assert names == ["seats", "tier"]

      # org-scoped: o2's list does not leak o1's tier
      o2_names = CustomFields.list_fields(o2, @table, TestRepo) |> Enum.map(& &1.tnt_field_name)
      assert o2_names == ["seats"]
    end

    test "define is an upsert (re-defining updates type/constraints, no duplicate row)" do
      o = org()
      define!(o, "seats", :string)
      define!(o, "seats", :integer, constraints: %{max: 5})

      assert [%FieldRow{tnt_type: "integer", tnt_constraints: %{"max" => 5}}] =
               CustomFields.list_fields(o, @table, TestRepo)
    end

    test "tnt_field is the tnt-namespaced sibling of fld_field (distinct surfaces)" do
      # fld_field carries the SYSTEM column tcf_custom; tnt_field carries the
      # tenant field defined *inside* it. They describe different things.
      o = org()
      define!(o, "seats", :integer)

      %{rows: fld} =
        TestRepo.query!(
          "SELECT fld_column_name FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = 'tcf_custom'",
          [@table]
        )

      assert fld == [["tcf_custom"]]

      %{rows: tnt} =
        TestRepo.query!(
          "SELECT tnt_field_name FROM tnt_field WHERE tnt_table_name = $1 AND tnt_org_id = $2",
          [@table, Ecto.UUID.dump!(o)]
        )

      assert tnt == [["seats"]]
    end
  end

  # ==========================================================================
  # RED 3 — invisible custom field fails the parity check
  # ==========================================================================

  describe "RED 3 — invisible custom field fails tnt_catalog parity" do
    test "a bag key with no tnt_field row is caught by the parity verifier" do
      o = org()
      define!(o, "seats", :integer)
      # Persist a row whose bag has the DEFINED key (passes the write-path change)...
      {:ok, widget} = create_widget(o, %{"seats" => 3})

      # ...then SABOTAGE: inject an undefined bag key via raw SQL (simulating a
      # write that bypassed Ash), so a real catalog gap exists in the DB.
      TestRepo.query!(
        "UPDATE tcf_widget SET tcf_custom = tcf_custom || '{\"ghost_field\": \"x\"}'::jsonb WHERE tcf_id = $1",
        [Ecto.UUID.dump!(widget.id)]
      )

      violations = Mix.Tasks.Samen.Verify.TntCatalog.check(TestRepo)

      assert Enum.any?(violations, &(&1 =~ "uncatalogued custom field: tcf_widget.ghost_field"))
    end

    test "orphan tnt_field for a non-catalogued table is caught" do
      o = org()

      {:ok, _} =
        CustomFields.define_field(
          %{
            org_id: o,
            table_name: "nonexistent_table",
            field_name: "foo",
            type: :string
          },
          TestRepo
        )

      violations = Mix.Tasks.Samen.Verify.TntCatalog.check(TestRepo)
      assert Enum.any?(violations, &(&1 =~ "orphan tnt_field"))
    end

    test "with only well-catalogued fields, parity PASSES (anti-tautology: the check isn't always-fail)" do
      o = org()
      define!(o, "seats", :integer)
      {:ok, _} = create_widget(o, %{"seats" => 3})

      violations = Mix.Tasks.Samen.Verify.TntCatalog.check(TestRepo)
      # No uncatalogued/orphan among OUR fixture rows.
      refute Enum.any?(violations, &(&1 =~ "tcf_widget"))
    end
  end

  # ==========================================================================
  # define-time fail-closed
  # ==========================================================================

  describe "define_field fail-closed" do
    test "an unknown type is rejected at definition time" do
      assert {:error, {:unknown_type, :geopoint}} =
               CustomFields.define_field(
                 %{org_id: org(), table_name: @table, field_name: "loc", type: :geopoint},
                 TestRepo
               )
    end

    test "an enum with no one_of is rejected at definition time" do
      assert {:error, {:invalid_constraint, _}} =
               CustomFields.define_field(
                 %{org_id: org(), table_name: @table, field_name: "t", type: :enum},
                 TestRepo
               )
    end
  end

  # ==========================================================================
  # ADR-046 §4.2 D3 — the pii_declared erasability GUARD (fail-closed chokepoint)
  # ==========================================================================

  describe "pii_declared erasability guard (ADR-046 §4.2 D3)" do
    test "REFUSED: a pii_declared field on a table with NO custom-bag erasure spec is rejected" do
      # No :erasure_specs override, no configured spec → the bag would be unerasable,
      # so the define chokepoint refuses it (a live pii_declared bag can never exist
      # without a registered arm to erase it).
      assert {:error, {:pii_declared_unerasable, @table}} =
               CustomFields.define_field(
                 %{
                   org_id: org(),
                   table_name: @table,
                   field_name: "care_note",
                   type: :string,
                   pii_declared: true
                 },
                 TestRepo
               )
    end

    test "ALLOWED (positive control): the SAME define WITH an erasure spec succeeds" do
      # Anti-tautology: the guard discriminates — wiring the erasure arm lets the very
      # same pii_declared field through.
      assert {:ok, %FieldRow{tnt_pii_declared: true}} =
               CustomFields.define_field(
                 %{
                   org_id: org(),
                   table_name: @table,
                   field_name: "care_note",
                   type: :string,
                   pii_declared: true,
                   erasure_specs: [@erasure_spec]
                 },
                 TestRepo
               )
    end

    test "a NON-pii_declared field needs no erasure spec (the guard only gates pii_declared)" do
      assert {:ok, %FieldRow{tnt_pii_declared: false}} =
               CustomFields.define_field(
                 %{org_id: org(), table_name: @table, field_name: "seats", type: :integer},
                 TestRepo
               )
    end
  end

  defp error_msg(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&Exception.message/1) |> Enum.join(" | ")
  end

  defp error_msg(other), do: inspect(other)
end
