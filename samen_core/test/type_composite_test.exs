defmodule Samen.TypeCompositeTest do
  @moduledoc """
  T1.3 (b) — the composite Ash types `Samen.Type.FullName / Emails / Phones`
  (plan D1; Twenty CRM shapes as SPEC only: first/last for FullName; label+list
  for Emails/Phones).

  These are pure `Ash.Type` unit tests: `cast_input` (user/map/struct forms),
  `cast_stored` / `dump_to_native` round-trip through the jsonb representation, and
  the `samen_pii_class/0` self-classification the registry keys on. Persistence
  through a real prefixed column is proven separately in `Samen.ResourceTest`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Samen.Type.{Emails, FullName, Phones}

  # ==========================================================================
  # FullName — {first, last}
  # ==========================================================================

  describe "FullName" do
    test "storage is :map and it self-classifies :pii" do
      assert FullName.storage_type([]) == :map
      assert FullName.samen_pii_class() == :pii
    end

    test "cast_input accepts a struct, an atom-keyed map, and a string-keyed map" do
      v = %FullName{first: "Grace", last: "Hopper"}
      assert FullName.cast_input(v, []) == {:ok, v}
      assert FullName.cast_input(%{first: "Grace", last: "Hopper"}, []) == {:ok, v}
      assert FullName.cast_input(%{"first" => "Grace", "last" => "Hopper"}, []) == {:ok, v}
    end

    test "cast_input(nil) is nil; a non-map is :error" do
      assert FullName.cast_input(nil, []) == {:ok, nil}
      assert FullName.cast_input("Grace Hopper", []) == :error
      assert FullName.cast_input(42, []) == :error
    end

    test "dump → cast_stored round-trips" do
      v = %FullName{first: "Ada", last: "Lovelace"}
      {:ok, native} = FullName.dump_to_native(v, [])
      assert native == %{"first" => "Ada", "last" => "Lovelace"}
      assert FullName.cast_stored(native, []) == {:ok, v}
    end
  end

  # ==========================================================================
  # Emails — label + address list
  # ==========================================================================

  describe "Emails" do
    test "storage is :map and it self-classifies :pii" do
      assert Emails.storage_type([]) == :map
      assert Emails.samen_pii_class() == :pii
    end

    test "cast_input accepts a bare entry list (label+address)" do
      {:ok, v} =
        Emails.cast_input(
          [%{label: "work", address: "g@ex.com"}, %{"label" => "home", "address" => "g@home"}],
          []
        )

      assert v == %Emails{
               entries: [
                 %{label: "work", address: "g@ex.com"},
                 %{label: "home", address: "g@home"}
               ]
             }
    end

    test "cast_input accepts an entries-wrapped map and a struct" do
      list = [%{label: "work", address: "g@ex.com"}]
      {:ok, from_list} = Emails.cast_input(list, [])
      assert Emails.cast_input(%{entries: list}, []) == {:ok, from_list}
      assert Emails.cast_input(from_list, []) == {:ok, from_list}
    end

    test "an entry missing the required address is :error" do
      assert Emails.cast_input([%{label: "work"}], []) == :error
      assert Emails.cast_input([%{label: "work", address: 123}], []) == :error
    end

    test "dump → cast_stored round-trips" do
      v = %Emails{entries: [%{label: "work", address: "g@ex.com"}]}
      {:ok, native} = Emails.dump_to_native(v, [])
      assert native == %{"entries" => [%{"label" => "work", "address" => "g@ex.com"}]}
      assert Emails.cast_stored(native, []) == {:ok, v}
    end
  end

  # ==========================================================================
  # Phones — label + number list
  # ==========================================================================

  describe "Phones" do
    test "storage is :map and it self-classifies :pii" do
      assert Phones.storage_type([]) == :map
      assert Phones.samen_pii_class() == :pii
    end

    test "cast_input accepts a label+number list; missing number is :error" do
      {:ok, v} = Phones.cast_input([%{label: "mobile", number: "+1-555-0100"}], [])
      assert v == %Phones{entries: [%{label: "mobile", number: "+1-555-0100"}]}
      assert Phones.cast_input([%{label: "mobile"}], []) == :error
    end

    test "dump → cast_stored round-trips" do
      v = %Phones{entries: [%{label: "mobile", number: "+1-555-0100"}]}
      {:ok, native} = Phones.dump_to_native(v, [])
      assert native == %{"entries" => [%{"label" => "mobile", "number" => "+1-555-0100"}]}
      assert Phones.cast_stored(native, []) == {:ok, v}
    end
  end

  # ==========================================================================
  # Properties: arbitrary values survive cast → dump → cast_stored
  # ==========================================================================

  property "FullName round-trips arbitrary first/last through the native map" do
    check all(
            first <- StreamData.string(:alphanumeric, min_length: 1, max_length: 30),
            last <- StreamData.string(:alphanumeric, min_length: 1, max_length: 30)
          ) do
      {:ok, v} = FullName.cast_input(%{first: first, last: last}, [])
      {:ok, native} = FullName.dump_to_native(v, [])
      assert FullName.cast_stored(native, []) == {:ok, v}
    end
  end

  property "Emails round-trips an arbitrary label+address list" do
    entry_gen =
      StreamData.fixed_map(%{
        label: StreamData.string(:alphanumeric, min_length: 0, max_length: 12),
        address: StreamData.string(:alphanumeric, min_length: 1, max_length: 40)
      })

    check all(entries <- StreamData.list_of(entry_gen, min_length: 0, max_length: 5)) do
      {:ok, v} = Emails.cast_input(entries, [])
      {:ok, native} = Emails.dump_to_native(v, [])
      assert Emails.cast_stored(native, []) == {:ok, v}
    end
  end

  property "Phones round-trips an arbitrary label+number list" do
    entry_gen =
      StreamData.fixed_map(%{
        label: StreamData.string(:alphanumeric, min_length: 0, max_length: 12),
        number: StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
      })

    check all(entries <- StreamData.list_of(entry_gen, min_length: 0, max_length: 5)) do
      {:ok, v} = Phones.cast_input(entries, [])
      {:ok, native} = Phones.dump_to_native(v, [])
      assert Phones.cast_stored(native, []) == {:ok, v}
    end
  end
end
