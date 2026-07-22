defmodule Samen.Type.DurationTest do
  @moduledoc """
  H2 — `Samen.Type.Duration` (ADR-036 D2, T13 done-criterion 1): a
  non-negative-seconds scalar accepting bare seconds, ISO-8601 duration
  strings, and the Elixir stdlib `%Duration{}` struct.
  """
  use ExUnit.Case, async: true

  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.Duration, as: SamenDuration
  alias SamenCore.Support.RichTypes.OrgFixture

  describe "Ash.Type contract" do
    test "storage_type is :integer" do
      assert SamenDuration.storage_type([]) == :integer
    end

    test "ACCEPT: a bare non-negative integer (seconds)" do
      assert SamenDuration.cast_input(0, []) == {:ok, 0}
      assert SamenDuration.cast_input(5400, []) == {:ok, 5400}
    end

    test "ACCEPT: a numeric string is parsed as seconds" do
      assert SamenDuration.cast_input("5400", []) == {:ok, 5400}
    end

    test "ACCEPT: an ISO-8601 duration string reduces to total seconds" do
      assert SamenDuration.cast_input("PT1H30M", []) == {:ok, 5400}
      assert SamenDuration.cast_input("PT45S", []) == {:ok, 45}
      assert SamenDuration.cast_input("P1DT2H", []) == {:ok, 86_400 + 7_200}
    end

    test "ACCEPT: a %Duration{} struct (day/hour/minute/second/week components)" do
      assert SamenDuration.cast_input(%Duration{hour: 1, minute: 30}, []) == {:ok, 5400}
      assert SamenDuration.cast_input(%Duration{week: 1}, []) == {:ok, 604_800}
    end

    test "REJECT: a %Duration{} with a year/month component (calendar-relative, ambiguous)" do
      assert SamenDuration.cast_input(%Duration{year: 1}, []) == :error
      assert SamenDuration.cast_input(%Duration{month: 3}, []) == :error
    end

    test "REJECT: a negative integer is refused regardless of :min/:max" do
      assert SamenDuration.cast_input(-1, []) == :error
      assert SamenDuration.cast_input(-1, min: -100) == :error
    end

    test "REJECT: out-of-range against :min/:max constraints" do
      assert SamenDuration.cast_input(30, min: 60) == :error
      assert SamenDuration.cast_input(120, max: 60) == :error
    end

    test "ACCEPT: within :min/:max constraints" do
      assert SamenDuration.cast_input(90, min: 60, max: 120) == {:ok, 90}
    end

    test "REJECT: garbage input never coerced" do
      assert SamenDuration.cast_input("not a duration", []) == :error
      assert SamenDuration.cast_input(%{}, []) == :error
      assert SamenDuration.cast_input(3.5, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert SamenDuration.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored → dump_to_native round-trips" do
      {:ok, v} = SamenDuration.cast_input("PT1H30M", [])
      {:ok, native} = SamenDuration.dump_to_native(v, [])
      assert native == 5400
      assert SamenDuration.cast_stored(native, []) == {:ok, 5400}
    end

    test "dump_to_native(nil) is nil; a negative/non-integer is :error" do
      assert SamenDuration.dump_to_native(nil, []) == {:ok, nil}
      assert SamenDuration.dump_to_native(-1, []) == :error
      assert SamenDuration.dump_to_native("5400", []) == :error
    end
  end

  describe "PII posture (ADR-036 D2 / ADR-034 gate)" do
    test "self-classifies :non_pii" do
      assert SamenDuration.samen_pii_class() == :non_pii
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

      assert TypeClearance.cleared?(SamenDuration)
      assert Classification.classify(SamenDuration) == :non_pii
      assert Classification.classified?(SamenDuration)
    end

    test "the shipped clearance is genuinely two-distinct-party (not self-reviewed)" do
      shipped = Enum.find(TypeClearance.clearances(), &(&1.type == SamenDuration))

      refute is_nil(shipped)
      assert shipped.cleared_by != shipped.reviewed_by
      assert is_binary(shipped.reason) and String.trim(shipped.reason) != ""
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["duration"] == "Samen.Type.Duration"
    end
  end
end
