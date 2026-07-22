defmodule Samen.Type.PriorityTest do
  @moduledoc """
  H2 — `Samen.Type.Priority` (ADR-036 D2, ruling c15; T13 done-criteria 1 & 2):
  the ordered-enum scalar storing a RANK (not the atom) so `sort(priority: …)`
  is native and correct in `Ash.read` (a stored `:atom` sorts alphabetically —
  wrong).

  The `describe "ordering in a read query (done-criterion 2)"` block is the
  load-bearing proof: seeded rows in scrambled insertion order, sorted
  ascending/descending, must come back in spec rank order
  (`low < normal < high < urgent`).
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.Priority
  alias SamenCore.Support.RichTypes.OrgFixture
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  describe "Ash.Type contract" do
    test "storage_type is :integer (a RANK, not the atom)" do
      assert Priority.storage_type([]) == :integer
    end

    test "values/0 is the ordered enum, low → urgent" do
      assert Priority.values() == [:low, :normal, :high, :urgent]
    end

    test "rank/1 is strictly ascending low < normal < high < urgent" do
      assert Priority.rank(:low) < Priority.rank(:normal)
      assert Priority.rank(:normal) < Priority.rank(:high)
      assert Priority.rank(:high) < Priority.rank(:urgent)
    end

    test "ACCEPT: an enum atom, its string name, and its stored rank" do
      assert Priority.cast_input(:high, []) == {:ok, :high}
      assert Priority.cast_input("high", []) == {:ok, :high}
      assert Priority.cast_input(30, []) == {:ok, :high}
    end

    test "REJECT: an atom/string/rank outside the fixed enum, never coerced" do
      assert Priority.cast_input(:critical, []) == :error
      assert Priority.cast_input("critical", []) == :error
      assert Priority.cast_input(999, []) == :error
      assert Priority.cast_input(3.0, []) == :error
      assert Priority.cast_input(%{}, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert Priority.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored accepts the rank and returns the atom; rejects an out-of-enum rank" do
      assert Priority.cast_stored(10, []) == {:ok, :low}
      assert Priority.cast_stored(20, []) == {:ok, :normal}
      assert Priority.cast_stored(30, []) == {:ok, :high}
      assert Priority.cast_stored(40, []) == {:ok, :urgent}
      assert Priority.cast_stored(25, []) == :error
      assert Priority.cast_stored(nil, []) == {:ok, nil}
    end

    test "dump_to_native emits the rank, never the atom" do
      assert Priority.dump_to_native(:low, []) == {:ok, 10}
      assert Priority.dump_to_native(:normal, []) == {:ok, 20}
      assert Priority.dump_to_native(:high, []) == {:ok, 30}
      assert Priority.dump_to_native(:urgent, []) == {:ok, 40}
      assert Priority.dump_to_native(nil, []) == {:ok, nil}
      assert Priority.dump_to_native(:bogus, []) == :error
    end
  end

  describe "ordering in a read query (done-criterion 2)" do
    test "sort(priority: :asc) returns spec rank order regardless of insertion order" do
      org_id = Ash.UUID.generate()

      # Deliberately scrambled insertion order — the read's sort is what must
      # produce the spec order, not insertion order.
      for p <- [:urgent, :low, :high, :normal, :urgent, :low] do
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "seed", priority: p})
        |> Ash.create!()
      end

      ascending =
        OrgFixture
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.Query.sort(priority: :asc)
        |> Ash.read!()
        |> Enum.map(& &1.priority)

      assert ascending == [:low, :low, :normal, :high, :urgent, :urgent]

      descending =
        OrgFixture
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.Query.sort(priority: :desc)
        |> Ash.read!()
        |> Enum.map(& &1.priority)

      assert descending == [:urgent, :urgent, :high, :normal, :low, :low]
    end

    test "a filter on the atom face works (e.g. priority == :urgent), proving the atom " <>
           "read/write face round-trips through the integer rank storage" do
      org_id = Ash.UUID.generate()

      for p <- [:low, :urgent, :normal] do
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "seed", priority: p})
        |> Ash.create!()
      end

      urgent_only =
        OrgFixture
        |> Ash.Query.filter(org_id == ^org_id and priority == :urgent)
        |> Ash.read!()

      assert length(urgent_only) == 1
      assert hd(urgent_only).priority == :urgent
    end
  end

  describe "PII posture (ADR-036 D2 / ADR-034 gate)" do
    test "self-classifies :non_pii" do
      assert Priority.samen_pii_class() == :non_pii
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

      assert TypeClearance.cleared?(Priority)
      assert Classification.classify(Priority) == :non_pii
      assert Classification.classified?(Priority)
    end

    test "the shipped clearance is genuinely two-distinct-party (not self-reviewed)" do
      shipped = Enum.find(TypeClearance.clearances(), &(&1.type == Priority))

      refute is_nil(shipped)
      assert shipped.cleared_by != shipped.reviewed_by
      assert is_binary(shipped.reason) and String.trim(shipped.reason) != ""
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["priority"] == "Samen.Type.Priority"
    end
  end
end
