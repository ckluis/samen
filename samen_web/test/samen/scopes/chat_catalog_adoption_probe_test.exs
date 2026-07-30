defmodule Samen.Scopes.ChatCatalogAdoptionProbeTest do
  @moduledoc """
  T37h — the Chat half of the catalog-driven E6 adoption probe (ADR-040 §5.9's T37h
  split, T37 c1). Companion to `demo/test/e6_catalog_adoption_probe_test.exs`, which
  scans demo's eight §5.9-classified domains but does NOT mount Chat (`samen_web`'s
  T37e rider — ADR-040 §5.9's "primitives+chat" row).

  Same three guarantees, scoped to `Samen.WebTest.Chat`:

    1. Every roster-archivable Chat resource (`ChatThread` cascade parent,
       `ChatParticipant`/`ChatMessage` cascade children) IS `archivable?/1 == true`.
    2. The roster's one named Chat exclusion (`ChatDisclosureSetting` — a live per-org
       config row, "delete is delete") is NOT archivable.
    3. Nothing falls through: the LIVE catalog walk of `Samen.WebTest.Chat` is set-
       equal to `archivable ∪ excluded` — a Chat resource added tomorrow with neither
       flag nor an exclusion entry here fails immediately.
  """
  use Samen.WebTest.DataCase, async: true

  @roster [
    {Samen.WebTest.Chat.ChatThread, :archivable},
    {Samen.WebTest.Chat.ChatParticipant, :archivable},
    {Samen.WebTest.Chat.ChatMessage, :archivable},
    {Samen.WebTest.Chat.ChatDisclosureSetting, {:excluded, :settings}}
  ]

  describe "§5.9 roster (Chat) — archivable-listed resources are archivable?/1 == true" do
    for {resource, :archivable} <- @roster do
      test "#{inspect(resource)} is archivable" do
        assert Samen.Info.archivable?(unquote(resource)) == true
      end
    end
  end

  describe "§5.9 roster (Chat) — excluded-listed resource is NOT archivable" do
    for {resource, {:excluded, class}} <- @roster do
      test "#{inspect(resource)} is excluded (class #{class}) and NOT archivable" do
        assert Samen.Info.archivable?(unquote(resource)) == false
      end
    end
  end

  describe "nothing falls through the Chat roster (T37 c1 — the structural guarantee)" do
    test "the live Chat catalog is set-equal to (archivable ∪ excluded)" do
      live = Samen.WebTest.Chat |> Samen.Catalog.resource_modules() |> MapSet.new()
      accounted = @roster |> Enum.map(fn {r, _s} -> r end) |> MapSet.new()

      missing_from_roster = MapSet.difference(live, accounted)
      stale_in_roster = MapSet.difference(accounted, live)

      assert MapSet.size(missing_from_roster) == 0,
             "catalogued but UNCLASSIFIED by @roster — #{inspect(MapSet.to_list(missing_from_roster))}"

      assert MapSet.size(stale_in_roster) == 0,
             "@roster names a resource no longer in the live catalog — #{inspect(MapSet.to_list(stale_in_roster))}"
    end
  end

  describe "anti-tautology: the accounting is non-vacuous" do
    test "dropping ChatThread from the fixture is CAUGHT by the set-equality check" do
      live = Samen.WebTest.Chat |> Samen.Catalog.resource_modules() |> MapSet.new()

      incomplete_accounted =
        @roster
        |> Enum.reject(fn {r, _s} -> r == Samen.WebTest.Chat.ChatThread end)
        |> Enum.map(fn {r, _s} -> r end)
        |> MapSet.new()

      missing = MapSet.difference(live, incomplete_accounted)

      assert MapSet.member?(missing, Samen.WebTest.Chat.ChatThread)
      refute MapSet.size(missing) == 0
    end
  end
end
