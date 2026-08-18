defmodule Samen.Type.PercentTest do
  @moduledoc """
  H2 — `Samen.Type.Percent` (ADR-036 D2, T13 done-criterion 1): a bounded,
  range-validating percent scalar (percent POINTS, not a fraction).

  Two halves, mirroring `Samen.Type.MoneyTest`'s style:

    * A pure `Ash.Type` unit suite — accept/reject cast vectors + round-trip.
    * A PII-posture suite proving the type self-classifies `:non_pii` and that
      classification is backed by the foundry-SHIPPED `TypeClearance` entry
      (no host config required).
  """
  use ExUnit.Case, async: true

  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.Percent
  alias SamenCore.Support.RichTypes.OrgFixture

  describe "Ash.Type contract" do
    test "storage_type is :decimal" do
      assert Percent.storage_type([]) == :decimal
    end

    test "ACCEPT: a decimal string, integer, float, and %Decimal{} within the default 0..100 range" do
      assert {:ok, v} = Percent.cast_input("42.5", [])
      assert Decimal.equal?(v, Decimal.new("42.5"))

      assert {:ok, v} = Percent.cast_input(50, [])
      assert Decimal.equal?(v, Decimal.new(50))

      assert {:ok, v} = Percent.cast_input(12.25, [])
      assert Decimal.equal?(v, Decimal.new("12.25"))

      assert {:ok, v} = Percent.cast_input(Decimal.new("0"), [])
      assert Decimal.equal?(v, Decimal.new(0))

      assert {:ok, v} = Percent.cast_input(Decimal.new("100"), [])
      assert Decimal.equal?(v, Decimal.new(100))
    end

    test "ACCEPT: rounds to the :decimals constraint" do
      assert {:ok, v} = Percent.cast_input("42.567", decimals: 1)
      assert Decimal.equal?(v, Decimal.new("42.6"))
    end

    test "ACCEPT: custom :min/:max constraints widen the allowed range" do
      assert {:ok, v} = Percent.cast_input("150", min: 0, max: 200)
      assert Decimal.equal?(v, Decimal.new(150))
    end

    test "REJECT: out-of-range (below default min, above default max)" do
      assert Percent.cast_input("-0.01", []) == :error
      assert Percent.cast_input("100.01", []) == :error
      assert Percent.cast_input(-5, []) == :error
      assert Percent.cast_input(101, []) == :error
    end

    test "REJECT: out-of-range against custom constraints" do
      assert Percent.cast_input("60", min: 0, max: 50) == :error
    end

    test "REJECT: garbage input never coerced" do
      assert Percent.cast_input("not a number", []) == :error
      assert Percent.cast_input(%{}, []) == :error
      assert Percent.cast_input([], []) == :error
      assert Percent.cast_input(:atom, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert Percent.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored → dump_to_native round-trips" do
      {:ok, v} = Percent.cast_input("42.50", [])
      {:ok, native} = Percent.dump_to_native(v, [])
      assert Decimal.equal?(native, Decimal.new("42.50"))
      assert {:ok, reloaded} = Percent.cast_stored(native, [])
      assert Decimal.equal?(reloaded, v)
    end

    test "dump_to_native(nil) is nil; a non-decimal is :error" do
      assert Percent.dump_to_native(nil, []) == {:ok, nil}
      assert Percent.dump_to_native("42.5", []) == :error
    end
  end

  describe "PII posture (ADR-036 D2 / ADR-034 gate)" do
    test "self-classifies :non_pii" do
      assert Percent.samen_pii_class() == :non_pii
    end

    test "GREEN: classifies :non_pii on a FRESH host with NO configured clearances — " <>
           "the ADR-036 clearance is foundry-SHIPPED, not host-config-dependent" do
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      Application.put_env(:samen_core, :non_pii_type_clearances, [])

      assert TypeClearance.cleared?(Percent)
      assert Classification.classify(Percent) == :non_pii
      assert Classification.classified?(Percent)
    end

    test "the shipped clearance is genuinely two-distinct-party (not self-reviewed)" do
      shipped = Enum.find(TypeClearance.clearances(), &(&1.type == Percent))

      refute is_nil(shipped)
      assert shipped.cleared_by != shipped.reviewed_by
      assert is_binary(shipped.reason) and String.trim(shipped.reason) != ""
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["percent"] == "Samen.Type.Percent"
    end
  end
end
