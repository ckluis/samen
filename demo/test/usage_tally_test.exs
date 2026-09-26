defmodule Demo.UsageTallyTest do
  @moduledoc """
  T163 (ADR-051 P2) on the DEMO host's real Postgres: the `Usage` tally is DERIVED
  from the insert-only `UsageEvent` ledger by `Samen.Billing.UsageTally.rebuild/5`,
  and never written directly.

    * R4 — the tally is a recompute of the ledger, not an increment: a rebuild is
      idempotent, and a late capture grows it on the next rebuild.
    * The period is half-open, `[start, end)`, and scoped to one org + subscription.
    * A direct tally write is refused; `:mark_reported` only moves forward.
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.{Customer, Plan, Subscription, Usage, UsageEvent}
  alias Demo.Identity.Org
  alias Samen.Billing.{Meter, UsageTally}

  require Ash.Query

  @start ~U[2026-07-01 00:00:00Z]
  @stop ~U[2026-08-01 00:00:00Z]

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_subscription(org_id) do
    {:ok, c} =
      Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, status: :active})
      |> Ash.create(authorize?: false)

    {:ok, p} =
      Plan
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "metered", interval: :monthly})
      |> Ash.create(authorize?: false)

    {:ok, s} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: c.id,
        plan_id: p.id,
        status: :active
      })
      |> Ash.create(authorize?: false)

    s
  end

  defp setup_sub(name) do
    org = mk_org(name)
    %{org_id: org.id, sub_id: mk_subscription(org.id).id}
  end

  defp capture(org_id, sub_id, ref, attrs) do
    event =
      Map.merge(
        %{metric: :api_calls, quantity: 1, source_ref: ref, subscription_id: sub_id,
          occurred_at: ~U[2026-07-15 12:00:00Z]},
        attrs
      )

    assert {:ok, :recorded} = Meter.record(org_id, event, resource: UsageEvent)
  end

  defp rebuild(%{org_id: o, sub_id: s}),
    do: UsageTally.rebuild(o, s, @start, @stop, usage: Usage, usage_event: UsageEvent)

  defp tallies(org_id) do
    Usage
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.metric, &1})
  end

  describe "R4 — the tally is derived from the ledger" do
    test "rebuild sums the ledger per metric inside [start, end), for this subscription only" do
      %{org_id: o, sub_id: s} = ctx = setup_sub("tally-derive")
      other = mk_subscription(o).id

      capture(o, s, "a", %{quantity: 1})
      capture(o, s, "b", %{quantity: 2})
      capture(o, s, "c", %{quantity: 4})
      capture(o, s, "m", %{metric: :messages, quantity: 5})
      # Outside the half-open period: at exactly `end`, and before `start`.
      capture(o, s, "at-end", %{quantity: 100, occurred_at: @stop})
      capture(o, s, "before", %{quantity: 100, occurred_at: ~U[2026-06-30 23:59:59Z]})
      # Another subscription, and no subscription at all.
      capture(o, other, "other-sub", %{quantity: 100})
      capture(o, nil, "no-sub", %{quantity: 100})

      assert {:ok, %{api_calls: 7, messages: 5} = totals} = rebuild(ctx)
      assert map_size(totals) == 2

      t = tallies(o)
      assert t[:api_calls].quantity == 7
      assert t[:messages].quantity == 5
      assert t[:api_calls].reported_quantity == 0
      assert map_size(t) == 2
    end

    test "a rebuild is idempotent — running it again recomputes the same total, one row per metric" do
      %{org_id: o, sub_id: s} = ctx = setup_sub("tally-idem")
      capture(o, s, "a", %{quantity: 3})

      assert {:ok, %{api_calls: 3}} = rebuild(ctx)
      assert {:ok, %{api_calls: 3}} = rebuild(ctx)

      assert %{api_calls: %{quantity: 3}} = tallies(o)
      assert Usage |> Ash.Query.filter(org_id == ^o) |> Ash.count!(authorize?: false) == 1
    end

    test "a late capture grows the tally on the next rebuild; what was reported is untouched" do
      %{org_id: o, sub_id: s} = ctx = setup_sub("tally-late")
      capture(o, s, "a", %{quantity: 7})
      {:ok, _} = rebuild(ctx)

      tally = tallies(o)[:api_calls]

      {:ok, _} =
        tally
        |> Ash.Changeset.for_update(:mark_reported, %{
          reported_quantity: 7,
          reported_at: DateTime.utc_now()
        })
        |> Ash.update(authorize?: false)

      capture(o, s, "late", %{quantity: 3})
      assert {:ok, %{api_calls: 10}} = rebuild(ctx)

      assert %{quantity: 10, reported_quantity: 7} = tallies(o)[:api_calls]
    end
  end

  describe "a tally is never written directly" do
    test "a direct :rebuild_tally create is refused and writes nothing" do
      %{org_id: o, sub_id: s} = setup_sub("tally-direct")

      assert {:error, error} =
               Usage
               |> Ash.Changeset.for_create(:rebuild_tally, %{
                 org_id: o,
                 subscription_id: s,
                 metric: :api_calls,
                 quantity: 999,
                 period_start: @start,
                 period_end: @stop
               })
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "underived-usage-tally"
      assert tallies(o) == %{}
    end

    test "Usage exposes read, the rebuild upsert and mark_reported — no generic create/update/destroy" do
      names = Usage |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:mark_reported, :read, :rebuild_tally]
    end
  end

  describe ":mark_reported is forward-only and bounded by quantity" do
    setup do
      %{org_id: o, sub_id: s} = ctx = setup_sub("tally-mark")
      capture(o, s, "a", %{quantity: 10})
      {:ok, _} = rebuild(ctx)
      %{tally: tallies(o)[:api_calls]}
    end

    defp mark(tally, n) do
      tally
      |> Ash.Changeset.for_update(:mark_reported, %{reported_quantity: n, reported_at: DateTime.utc_now()})
      |> Ash.update(authorize?: false)
    end

    test "forward to at most quantity succeeds (positive control)", %{tally: t} do
      assert {:ok, %{reported_quantity: 6} = t2} = mark(t, 6)
      assert {:ok, %{reported_quantity: 10}} = mark(t2, 10)
    end

    test "backwards is refused (it would re-report usage the provider already has)", %{tally: t} do
      {:ok, t2} = mark(t, 6)
      assert {:error, error} = mark(t2, 5)
      assert Exception.message(error) =~ "may only move forward"
    end

    test "past quantity is refused (it would claim usage that was never captured)", %{tally: t} do
      assert {:error, error} = mark(t, 11)
      assert Exception.message(error) =~ "may not exceed"
    end
  end
end
