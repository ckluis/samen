defmodule Driftwood.LoadBoardFilterTest do
  @moduledoc """
  T158 — the REAL filtered `Driftwood.Reads.load_board/2` (T148 removed the dead
  "Filter" button; this is the working read it needed). Proves three things:

    1. The filter is REAL — it narrows the result set by status and free-text
       query, not a UI decoration over the unfiltered list.
    2. HONEST empty — a filter that matches nothing returns `[]`, never a
       fabricated/sample row.
    3. ORG-SCOPE PIN (load-bearing) — a filter can NEVER surface another org's
       loads, even when the filter criteria would also match a foreign-org row.
       `"drop-filter-flips-a-named-test"`: the org-scope-drop sabotage patch
       (149) targets the ONE place this guarantee is enforced in the new code —
       the `scope:` argument passed to the underlying `Ash.read!` call — and
       flips this exact test.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org_a "c1230000-0000-4000-8000-0000000000f1"
  @org_b "c1230000-0000-4000-8000-0000000000f2"

  defp seed_load(org, name, lane, status) do
    {:ok, load} =
      BrokerLive.create_load(org, %{
        "name" => name,
        "lane" => lane,
        "rate" => "1000.00",
        "status" => status
      })

    load
  end

  test "REAL filter: status narrows the result set" do
    scope = BrokerLive.broker_scope(@org_a)
    seed_load(@org_a, "BRL-1 open", "TX->CA", "open")
    seed_load(@org_a, "BRL-2 won", "TX->CA", "won")

    open_only = Reads.load_board(scope, %{status: "open"})
    assert length(open_only) == 1
    assert hd(open_only).name == "BRL-1 open"

    all = Reads.load_board(scope, %{})
    assert length(all) == 2
  end

  test "REAL filter: free-text q narrows by load reference or lane (case-insensitive)" do
    scope = BrokerLive.broker_scope(@org_a)
    seed_load(@org_a, "BRL-CHI-4805", "IL->TX", "open")
    seed_load(@org_a, "BRL-DAL-2201", "TX->CA", "open")

    by_name = Reads.load_board(scope, %{q: "chi"})
    assert length(by_name) == 1
    assert hd(by_name).name == "BRL-CHI-4805"

    by_lane = Reads.load_board(scope, %{q: "il->tx"})
    assert length(by_lane) == 1
    assert hd(by_lane).name == "BRL-CHI-4805"
  end

  test "HONEST empty: a filter matching nothing returns [] — never a fabricated row" do
    scope = BrokerLive.broker_scope(@org_a)
    seed_load(@org_a, "BRL-REAL-1", "TX->CA", "open")

    assert Reads.load_board(scope, %{q: "no-such-load-reference-at-all"}) == []
    assert Reads.load_board(scope, %{status: "lost"}) == []
  end

  test "a malformed/forged status value is IGNORED (no 500, no fabricated filter match)" do
    scope = BrokerLive.broker_scope(@org_a)
    seed_load(@org_a, "BRL-SAFE-1", "TX->CA", "open")

    # Not one of the bounded enum values — must not raise, must not silently match
    # everything either; it degrades to "no status filter" (documented behaviour).
    result = Reads.load_board(scope, %{status: "'; DROP TABLE fop_opportunity; --"})
    assert Enum.any?(result, &(&1.name == "BRL-SAFE-1"))
  end

  # ==========================================================================
  # ORG-SCOPE PIN — the load-bearing guarantee (sabotage patch 149 target).
  # ==========================================================================

  test "ORG-SCOPE PIN: a filter matching BOTH orgs' loads never surfaces the other org's rows" do
    scope_a = BrokerLive.broker_scope(@org_a)

    # Same status, same lane substring, in TWO DIFFERENT orgs — a filter that (if the
    # org boundary broke) would happily match both.
    seed_load(@org_a, "BRL-SHARED-A", "TX->CA", "open")
    seed_load(@org_b, "BRL-SHARED-B", "TX->CA", "open")

    result = Reads.load_board(scope_a, %{status: "open", q: "tx->ca"})

    assert Enum.any?(result, &(&1.name == "BRL-SHARED-A")), "org A's own matching load must be present (non-vacuous control)"
    refute Enum.any?(result, &(&1.name == "BRL-SHARED-B")), "org B's load leaked across the org boundary via the filter"
  end

  test "ORG-SCOPE PIN: an unfiltered board for org A never includes org B's loads either (control)" do
    scope_a = BrokerLive.broker_scope(@org_a)
    seed_load(@org_a, "BRL-CTRL-A", "TX->CA", "open")
    seed_load(@org_b, "BRL-CTRL-B", "TX->CA", "open")

    result = Reads.load_board(scope_a)
    assert Enum.any?(result, &(&1.name == "BRL-CTRL-A"))
    refute Enum.any?(result, &(&1.name == "BRL-CTRL-B"))
  end
end
