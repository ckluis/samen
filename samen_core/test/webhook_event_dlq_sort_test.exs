defmodule Samen.Webhook.EventDlqSortTest do
  @moduledoc """
  T114/R5 — regression for the DLQ dead-first sort bug (`_orch/ux/dogfood-report.md`
  R5): `Samen.Webhook.Event.list_for_operator/2`'s docstring promises "`:dead`
  first, then recent envelopes" but the ORDER BY inverted its own case fragment
  (`desc` on a `dead -> 0, else -> 1` mapping sorts non-dead FIRST). This test is
  RED against the pre-fix `desc` ordering (a dead row inserted before several
  non-dead rows would NOT come first) and GREEN against the fix (`asc` on that
  fragment) — a genuine regression proof, not a tautology: reverting the one-line
  `asc` -> `desc` flip in `event.ex` fails this test.
  """
  use ExUnit.Case, async: false

  alias Samen.Webhook.Event
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp insert(status, provider_suffix) do
    {:ok, :inserted, row} =
      Event.insert_received(TestRepo, %{
        provider: "dlqsort",
        event_id: "evt_#{provider_suffix}_#{System.unique_integer([:positive])}",
        kind: "test_kind",
        domain: "delivery",
        occurred_at: DateTime.utc_now()
      })

    row = if status == "dead", do: elem(Event.mark_dead(TestRepo, row, "boom"), 1), else: row
    row
  end

  test "a DEAD row sorts FIRST even when several non-dead rows are more recent" do
    # Insert the dead row FIRST (older `inserted_at`), then three fresher
    # non-dead (`received`) rows — the naive "most-recent first, no dead
    # priority" ordering would put all three non-dead rows ahead of it.
    dead = insert("dead", "old")
    _r1 = insert("received", "r1")
    _r2 = insert("received", "r2")
    _r3 = insert("received", "r3")

    [first | _rest] = Event.list_for_operator(TestRepo, limit: 10)

    assert first.id == dead.id, "the DLQ listing must surface :dead rows FIRST, per its own docstring"
    assert first.status == "dead"
  end

  test "positive control: with NO dead rows, plain most-recent-first ordering holds" do
    _r1 = insert("received", "c1")
    _r2 = insert("received", "c2")
    r3 = insert("received", "c3")

    [first | _] = Event.list_for_operator(TestRepo, limit: 10)

    # No dead row exists — the tiebreak (`desc: inserted_at`) alone decides, so
    # the LAST-inserted row (r3) is first. Proves the fix didn't break the
    # ordinary "most recent first" behaviour for the no-dead-rows case.
    assert first.id == r3.id
  end

  test "MULTIPLE dead rows: all dead rows precede all non-dead, tiebroken by recency" do
    dead_old = insert("dead", "d-old")
    _live = insert("received", "live")
    dead_new = insert("dead", "d-new")

    rows = Event.list_for_operator(TestRepo, limit: 10)
    dead_ids = MapSet.new([dead_old.id, dead_new.id])

    {leading_dead, rest} = Enum.split_while(rows, &MapSet.member?(dead_ids, &1.id))

    assert length(leading_dead) == 2, "both dead rows must lead the listing"
    assert Enum.all?(rest, &(&1.status != "dead"))
    # Within the dead group, most-recent first (the SEPARATE tiebreak term).
    assert Enum.map(leading_dead, & &1.id) == [dead_new.id, dead_old.id]
  end
end
