defmodule Samen.Web.ReadsCalendarTest do
  @moduledoc """
  The GENERIC calendar read primitive (`Samen.Web.Reads.calendar_by_day!/3`, G2/WS-G) — the
  time-WINDOWED specialization of `group_by!/3` a calendar view consumes (columns = days).
  Each proof is anti-tautology (a positive control anchors every guard):

    * WINDOWING — a seeded month buckets rows into day-keyed columns; a row OUTSIDE the window
      is absent (positive control: an in-window row on the same day IS present).
    * BOUNDING — a day over the per-cell cap returns the cap + `has_more` + the exact `count`
      (the "+N more"), NEVER the whole day (positive control: an under-cap day returns all).
    * WINDOW BOUND — an over-wide range is REFUSED (raises), never an unbounded per-day scan
      (positive control: a one-month window reads fine).
    * ORG-SCOPE — a 2-org seed: org B's rows NEVER land in org A's cells (sabotage-refutable —
      org B genuinely holds same-DAY rows, proven absent from org A's calendar).
    * FACET — a non-`:date` facet is REFUSED (positive control: `:close_date` groups fine);
      `:close_date` is verified NON-vaulted, so no event field masks (T51-style refutable
      assertion, anchored against a real vaulted sibling field).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Board
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.UnboundedCalendarRangeError

  @opportunity Samen.WebTest.Crm.Opportunity
  @person Samen.WebTest.Crm.Person

  defp seed_opp(org_id, name, close_date) do
    @opportunity
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        name: name,
        value: Samen.Type.Money.from_cents(100_000, :USD),
        status: :open,
        close_date: close_date
      },
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp cal(mount, scope, month, opts \\ []) do
    Mount.resource(mount, Opportunity)
    |> Ash.Query.ensure_selected([:org_id, :close_date, :name])
    |> Reads.calendar_by_day!(:close_date, [scope: scope, month: month] ++ opts)
  end

  defp group(%Board{groups: groups}, key), do: Enum.find(groups, &(&1.key == key))

  # -- WINDOWING ---------------------------------------------------------------

  test "WINDOWING: rows bucket into the correct day cells; an out-of-window row is absent" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    seed_opp(org_id, "MAR-5-A", ~D[2026-03-05])
    seed_opp(org_id, "MAR-5-B", ~D[2026-03-05])
    seed_opp(org_id, "MAR-6", ~D[2026-03-06])
    out_next = seed_opp(org_id, "APR-2", ~D[2026-04-02])
    out_prev = seed_opp(org_id, "FEB-27", ~D[2026-02-27])

    board = cal(mount, scope, ~D[2026-03-15])

    # One day-keyed column per day of March (a full-month window).
    assert length(board.groups) == 31
    assert Enum.map(board.groups, & &1.key) == Enum.to_list(Date.range(~D[2026-03-01], ~D[2026-03-31]))
    assert board.group_field == :close_date

    # Rows land in the exact day cell, with an exact per-day count.
    mar5 = group(board, ~D[2026-03-05])
    assert mar5.count == 2
    assert Enum.map(mar5.rows, & &1.name) |> Enum.sort() == ["MAR-5-A", "MAR-5-B"]
    assert group(board, ~D[2026-03-06]).count == 1

    # An empty in-window day is still a present (renderable) cell.
    assert group(board, ~D[2026-03-20]).count == 0
    assert group(board, ~D[2026-03-20]).rows == []

    # Out-of-window rows are ABSENT — no cell holds them, and no adjacent-month column exists.
    all_ids = board.groups |> Enum.flat_map(& &1.rows) |> MapSet.new(& &1.id)
    refute MapSet.member?(all_ids, out_next.id)
    refute MapSet.member?(all_ids, out_prev.id)
    assert is_nil(group(board, ~D[2026-04-02]))
    assert is_nil(group(board, ~D[2026-02-27]))
  end

  # -- BOUNDING (per-cell cap) -------------------------------------------------

  test "BOUNDING: a day over the cap returns cap + has_more + exact count, not the whole day" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    for i <- 1..5, do: seed_opp(org_id, "HOT-#{i}", ~D[2026-03-10])
    for i <- 1..2, do: seed_opp(org_id, "COLD-#{i}", ~D[2026-03-11])

    board = cal(mount, scope, ~D[2026-03-01], per_group_limit: 3)

    hot = group(board, ~D[2026-03-10])
    # Bounded: at most `cap` rows, NOT all 5 — the cell did not leak the whole day.
    assert length(hot.rows) == 3
    assert hot.has_more == true
    # But the exact total is still known (aggregate count — no row transfer): the "+N more".
    assert hot.count == 5
    assert board.per_group_limit == 3

    # Positive control: an under-cap day returns everything, has_more false.
    cold = group(board, ~D[2026-03-11])
    assert length(cold.rows) == 2
    assert cold.has_more == false
    assert cold.count == 2
  end

  # -- WINDOW BOUND (no unbounded per-day scan) --------------------------------

  test "WINDOW BOUND: an over-wide range is REFUSED; a one-month window reads fine" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    # A year-wide window would fan out into 365 per-day column reads — refused loudly.
    err =
      assert_raise UnboundedCalendarRangeError, fn ->
        Mount.resource(mount, Opportunity)
        |> Reads.calendar_by_day!(:close_date, scope: scope, range: {~D[2026-01-01], ~D[2027-01-01]})
      end

    assert err.message =~ "UNBOUNDED CALENDAR WINDOW"
    assert Reads.max_calendar_days() == 62

    # Positive control: a bounded (one-month) window is fine — the bound is a live discriminator.
    board = cal(mount, scope, ~D[2026-03-15])
    assert %Board{} = board
    assert length(board.groups) == 31
  end

  test "WINDOW BOUND: an inverted/empty range is REFUSED (range_end is exclusive)" do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, Ash.UUID.generate())

    assert_raise UnboundedCalendarRangeError, fn ->
      Mount.resource(mount, Opportunity)
      |> Reads.calendar_by_day!(:close_date, scope: scope, range: {~D[2026-03-10], ~D[2026-03-10]})
    end
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B's rows NEVER land in org A's cells" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope_a = Mount.scope(mount, org_a)
    scope_b = Mount.scope(mount, org_b)

    for i <- 1..2, do: seed_opp(org_a, "A-#{i}", ~D[2026-03-05])
    for i <- 1..5, do: seed_opp(org_b, "B-#{i}", ~D[2026-03-05])

    # Refutation setup: org B genuinely holds 5 same-DAY rows.
    b_ids =
      @opportunity
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: scope_b)
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 5

    board = cal(mount, scope_a, ~D[2026-03-01])
    mar5 = group(board, ~D[2026-03-05])

    # OrgScope narrows every cell: org A's 2 only, none of org B's 5 (no count leak either).
    assert mar5.count == 2
    assert length(mar5.rows) == 2
    assert Enum.all?(mar5.rows, &(&1.org_id == org_a))
    assert MapSet.disjoint?(MapSet.new(mar5.rows, & &1.id), b_ids)
  end

  # -- FACET (date-only; masking posture) --------------------------------------

  test "FACET: a non-:date facet is REFUSED; :close_date groups fine" do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, Ash.UUID.generate())

    # RED: a :string facet cannot be day-bucketed — refused (never a silent per-value grouping).
    err =
      assert_raise ArgumentError, fn ->
        Mount.resource(mount, Person)
        |> Reads.calendar_by_day!(:job_title, scope: scope, month: ~D[2026-03-01])
      end

    assert err.message =~ "requires a :date field"

    # GREEN control: the real :date facet reads without raising (anti-tautology).
    assert %Board{} = cal(mount, scope, ~D[2026-03-01])
  end

  test "MASKING POSTURE: :close_date and every event field are NON-vaulted, so no event masks" do
    # The date facet and every rendered event field are non-vaulted …
    refute Samen.Pii.Info.vault_routed?(@opportunity, :close_date)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :name)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :value)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :status)
    # … anchored against a REAL vaulted field on a sibling CRM resource, so "non-vaulted" is a
    # live discriminator, not a predicate that returns false for everything. (Grouping/
    # positioning by a vaulted facet is refused by group_by!/3 — see reads_group_by_test.)
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
  end
end
