defmodule Samen.Type.ScoreTest do
  @moduledoc """
  H2 — `Samen.Type.Score` (ADR-036 D2, T13 done-criterion 1): a bounded,
  range-validating numeric score, default `0..100`, whole-number by default
  (`decimals: 0`) unlike `Percent`.
  """
  use ExUnit.Case, async: true

  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.Score
  alias SamenCore.Support.RichTypes.OrgFixture

  describe "Ash.Type contract" do
    test "storage_type is :decimal" do
      assert Score.storage_type([]) == :decimal
    end

    test "ACCEPT: an integer/decimal-string within the default 0..100 range, rounded whole" do
      assert {:ok, v} = Score.cast_input(87, [])
      assert Decimal.equal?(v, Decimal.new(87))

      assert {:ok, v} = Score.cast_input("42.6", [])
      assert Decimal.equal?(v, Decimal.new(43))

      assert {:ok, v} = Score.cast_input(Decimal.new("0"), [])
      assert Decimal.equal?(v, Decimal.new(0))

      assert {:ok, v} = Score.cast_input(Decimal.new("100"), [])
      assert Decimal.equal?(v, Decimal.new(100))
    end

    test "ACCEPT: a :decimals constraint preserves fractional scores" do
      assert {:ok, v} = Score.cast_input("87.25", decimals: 2)
      assert Decimal.equal?(v, Decimal.new("87.25"))
    end

    test "ACCEPT: custom :min/:max widen the allowed range (e.g. an NPS-style -100..100)" do
      assert {:ok, v} = Score.cast_input(-50, min: -100, max: 100)
      assert Decimal.equal?(v, Decimal.new(-50))
    end

    test "REJECT: out-of-range against the default 0..100" do
      assert Score.cast_input(-1, []) == :error
      assert Score.cast_input(101, []) == :error
    end

    test "REJECT: out-of-range against custom constraints" do
      assert Score.cast_input(-101, min: -100, max: 100) == :error
    end

    test "REJECT: garbage input never coerced" do
      assert Score.cast_input("not a number", []) == :error
      assert Score.cast_input(%{}, []) == :error
      assert Score.cast_input(true, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert Score.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored → dump_to_native round-trips" do
      {:ok, v} = Score.cast_input(87, [])
      {:ok, native} = Score.dump_to_native(v, [])
      assert Decimal.equal?(native, Decimal.new(87))
      assert {:ok, reloaded} = Score.cast_stored(native, [])
      assert Decimal.equal?(reloaded, v)
    end

    test "dump_to_native(nil) is nil; a non-decimal is :error" do
      assert Score.dump_to_native(nil, []) == {:ok, nil}
      assert Score.dump_to_native(87, []) == :error
    end
  end

  describe "PII posture (ADR-036 D2 / ADR-034 gate)" do
    test "self-classifies :non_pii" do
      assert Score.samen_pii_class() == :non_pii
    end

    test "GREEN: classifies :non_pii on a FRESH host with NO configured clearances" do
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      Application.put_env(:samen_core, :non_pii_type_clearances, [])

      assert TypeClearance.cleared?(Score)
      assert Classification.classify(Score) == :non_pii
      assert Classification.classified?(Score)
    end

    test "the shipped clearance is genuinely two-distinct-party (not self-reviewed)" do
      shipped = Enum.find(TypeClearance.clearances(), &(&1.type == Score))

      refute is_nil(shipped)
      assert shipped.cleared_by != shipped.reviewed_by
      assert is_binary(shipped.reason) and String.trim(shipped.reason) != ""
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["score"] == "Samen.Type.Score"
    end
  end
end
