defmodule Samen.Web.ReadsTimelineTest do
  @moduledoc """
  The GENERIC timeline/Gantt read primitive (`Samen.Web.Reads.timeline_window!/3`, G3/WS-G) — the
  time-WINDOWED, start..end OVERLAP read a Gantt view consumes (lanes = groups, rows = bars). Each
  proof is anti-tautology (a positive control anchors every guard). The primitive is exercised
  against the Work `Task` using its two settable `:utc_datetime` fields (`:due_at` as START,
  `:completed_at` as END) so start/end/NULL-end are all deterministically controllable:

    * OVERLAP — a record whose start..end OVERLAPS the window is present (incl. one that STRADDLES
      an edge — starts before, ends inside); a record fully outside is absent (positive control).
    * NULL END — a record with a NULL end is a POINT at its start (present iff the start is in the
      window; a point BEFORE the window is absent — never an infinite bar reaching in).
    * BOUNDING — a lane over the per-lane cap returns cap + `has_more` + exact `count`, not the
      whole lane (positive control: an under-cap lane returns all).
    * WINDOW BOUND — an over-wide / inverted range is REFUSED (positive control: a bounded window).
    * ORG-SCOPE — a 2-org seed: org B's rows NEVER land in org A's lanes (sabotage-refutable —
      org B genuinely holds same-window rows, proven absent from org A's timeline).
    * SINGLE LANE — with no `:lane_field`, all in-window rows land in ONE bounded lane (key nil).
    * AXIS — a non-temporal axis is REFUSED (ArgumentError); a VAULTED axis is REFUSED
      (MaskedGroupKeyError) — anchored against a real vaulted sibling field, so the refusal is a
      live discriminator; the Task axis + bar fields are verified NON-vaulted.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Board
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.MaskedGroupKeyError
  alias Samen.Web.Reads.UnboundedTimelineRangeError

  @task Samen.WebTest.Work.Task
  @person Samen.WebTest.Crm.Person

  # A UTC DateTime window. START = :due_at, END = :completed_at (both settable). range_end excl.
  @ws ~U[2026-03-01 00:00:00Z]
  @we ~U[2026-03-31 00:00:00Z]

  defp seed_task(org_id, title, status, due_at, completed_at) do
    @task
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, title: title, status: status, due_at: due_at, completed_at: completed_at},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp tl(mount, scope, opts) do
    Mount.resource(mount, Task)
    |> Ash.Query.ensure_selected([:org_id, :title, :status, :due_at, :completed_at])
    |> Reads.timeline_window!(:due_at, [scope: scope, end_field: :completed_at, range: {@ws, @we}] ++ opts)
  end

  defp lane(%Board{groups: groups}, key), do: Enum.find(groups, &(&1.key == key))
  defp all_titles(%Board{groups: groups}), do: groups |> Enum.flat_map(& &1.rows) |> Enum.map(& &1.title)

  # -- OVERLAP -----------------------------------------------------------------

  test "OVERLAP: a record overlapping the window is present (incl. straddling an edge); outside is absent" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    seed_task(org_id, "INSIDE", :pending, ~U[2026-03-05 00:00:00Z], ~U[2026-03-10 00:00:00Z])
    seed_task(org_id, "STRADDLE", :pending, ~U[2026-02-20 00:00:00Z], ~U[2026-03-05 00:00:00Z])
    seed_task(org_id, "BEFORE", :pending, ~U[2026-01-01 00:00:00Z], ~U[2026-01-15 00:00:00Z])
    seed_task(org_id, "AFTER", :pending, ~U[2026-04-10 00:00:00Z], ~U[2026-04-20 00:00:00Z])

    board = tl(mount, scope, lane_field: :status)
    titles = all_titles(board)

    # OVERLAP, not containment: a record that STARTS BEFORE the window but ends inside is present.
    assert "INSIDE" in titles
    assert "STRADDLE" in titles
    # Fully-outside records (both endpoints before, or start after) are absent — the overlap
    # filter is a real window (positive controls above are present, so this isn't a dead read).
    refute "BEFORE" in titles
    refute "AFTER" in titles
  end

  # -- NULL END (point, never infinite) ----------------------------------------

  test "NULL END: a nil end is a POINT at start — present iff the start is in-window, never infinite" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    seed_task(org_id, "POINT-IN", :pending, ~U[2026-03-10 00:00:00Z], nil)
    seed_task(org_id, "POINT-BEFORE", :pending, ~U[2026-02-10 00:00:00Z], nil)

    titles = tl(mount, scope, lane_field: :status) |> all_titles()

    # A NULL-end point whose START is in the window is present …
    assert "POINT-IN" in titles
    # … but a NULL-end point BEFORE the window is ABSENT — a nil end is a point, NOT an infinite
    # bar that would reach forward into the window (the crash/infinite-bar failure mode).
    refute "POINT-BEFORE" in titles
  end

  # -- BOUNDING (per-lane cap) -------------------------------------------------

  test "BOUNDING: a lane over the cap returns cap + has_more + exact count, not the whole lane" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    for i <- 1..5, do: seed_task(org_id, "HOT-#{i}", :pending, ~U[2026-03-05 00:00:00Z], ~U[2026-03-08 00:00:00Z])
    for i <- 1..2, do: seed_task(org_id, "COLD-#{i}", :in_progress, ~U[2026-03-06 00:00:00Z], ~U[2026-03-09 00:00:00Z])

    board = tl(mount, scope, lane_field: :status, per_group_limit: 3)

    hot = lane(board, :pending)
    assert length(hot.rows) == 3
    assert hot.has_more == true
    assert hot.count == 5
    assert board.per_group_limit == 3

    # Positive control: an under-cap lane returns everything, has_more false.
    cold = lane(board, :in_progress)
    assert length(cold.rows) == 2
    assert cold.has_more == false
    assert cold.count == 2
  end

  # -- WINDOW BOUND (no unbounded span) ----------------------------------------

  test "WINDOW BOUND: an over-wide range is REFUSED; a bounded window reads fine" do
    mount = build_mount(:work)
    scope = Mount.scope(mount, Ash.UUID.generate())

    err =
      assert_raise UnboundedTimelineRangeError, fn ->
        Mount.resource(mount, Task)
        |> Reads.timeline_window!(:due_at,
          scope: scope,
          end_field: :completed_at,
          range: {~U[2020-01-01 00:00:00Z], ~U[2025-01-01 00:00:00Z]}
        )
      end

    assert err.message =~ "UNBOUNDED TIMELINE WINDOW"
    assert Reads.max_timeline_days() == 372

    # Positive control: a bounded window is fine — the bound is a live discriminator.
    assert %Board{} = tl(mount, scope, lane_field: :status)
  end

  test "WINDOW BOUND: an inverted/empty range is REFUSED (range_end is exclusive)" do
    mount = build_mount(:work)
    scope = Mount.scope(mount, Ash.UUID.generate())

    assert_raise UnboundedTimelineRangeError, fn ->
      Mount.resource(mount, Task)
      |> Reads.timeline_window!(:due_at, scope: scope, end_field: :completed_at, range: {@we, @ws})
    end
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B's rows NEVER land in org A's lanes" do
    mount = build_mount(:work)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope_a = Mount.scope(mount, org_a)
    scope_b = Mount.scope(mount, org_b)

    for i <- 1..2, do: seed_task(org_a, "A-#{i}", :pending, ~U[2026-03-05 00:00:00Z], ~U[2026-03-08 00:00:00Z])
    for i <- 1..5, do: seed_task(org_b, "B-#{i}", :pending, ~U[2026-03-05 00:00:00Z], ~U[2026-03-08 00:00:00Z])

    # Refutation setup: org B genuinely holds 5 same-window rows.
    b_ids =
      @task
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: scope_b)
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 5

    board = tl(mount, scope_a, lane_field: :status)
    pending = lane(board, :pending)

    # OrgScope narrows every lane: org A's 2 only, none of org B's 5 (no count leak either).
    assert pending.count == 2
    assert length(pending.rows) == 2
    assert Enum.all?(pending.rows, &(&1.org_id == org_a))
    assert MapSet.disjoint?(MapSet.new(pending.rows, & &1.id), b_ids)
  end

  # -- SINGLE LANE (no :lane_field) --------------------------------------------

  test "SINGLE LANE: with no lane_field, all in-window rows land in ONE bounded lane (key nil)" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    for i <- 1..4, do: seed_task(org_id, "T-#{i}", :pending, ~U[2026-03-05 00:00:00Z], ~U[2026-03-09 00:00:00Z])
    seed_task(org_id, "OUT", :pending, ~U[2026-04-15 00:00:00Z], ~U[2026-04-20 00:00:00Z])

    board = tl(mount, scope, [])
    assert board.group_field == nil
    assert length(board.groups) == 1

    only = hd(board.groups)
    assert only.key == nil
    assert only.count == 4
    assert length(only.rows) == 4
    refute "OUT" in Enum.map(only.rows, & &1.title)

    # Bounded: a cap smaller than the lane clips it (cap + has_more + exact count).
    capped = tl(mount, scope, per_group_limit: 2) |> then(&hd(&1.groups))
    assert length(capped.rows) == 2
    assert capped.has_more == true
    assert capped.count == 4
  end

  # -- AXIS (temporal + non-vaulted) -------------------------------------------

  test "AXIS: a non-temporal axis field is REFUSED; a temporal field reads fine" do
    mount = build_mount(:work)
    scope = Mount.scope(mount, Ash.UUID.generate())

    err =
      assert_raise ArgumentError, fn ->
        Mount.resource(mount, Task)
        |> Reads.timeline_window!(:title, scope: scope, range: {@ws, @we})
      end

    assert err.message =~ "requires a temporal"

    # GREEN control: the real temporal axis reads without raising (anti-tautology).
    assert %Board{} = tl(mount, scope, [])
  end

  test "AXIS: a VAULTED axis field is REFUSED (INV-1), anchored against a real vaulted sibling" do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, Ash.UUID.generate())

    # RED: positioning a bar by a vault-routed (🔒) field would leak — refused before the type
    # check (a secret axis is refused regardless of its declared type).
    err =
      assert_raise MaskedGroupKeyError, fn ->
        Mount.resource(mount, Person)
        |> Reads.timeline_window!(:full_name, scope: scope, range: {@ws, @we})
      end

    assert err.message =~ "vault-routed"
    # The refusal is a live discriminator: :full_name really is vaulted.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
  end

  test "MASKING POSTURE: the Task axis + bar fields are NON-vaulted, so no bar masks" do
    refute Samen.Pii.Info.vault_routed?(@task, :inserted_at)
    refute Samen.Pii.Info.vault_routed?(@task, :due_at)
    refute Samen.Pii.Info.vault_routed?(@task, :completed_at)
    refute Samen.Pii.Info.vault_routed?(@task, :title)
    refute Samen.Pii.Info.vault_routed?(@task, :status)
    refute Samen.Pii.Info.vault_routed?(@task, :priority)
    # … anchored against a REAL vaulted field on a sibling resource, so "non-vaulted" is a live
    # discriminator, not a predicate that returns false for everything.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
  end
end
