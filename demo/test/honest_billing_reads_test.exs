defmodule Demo.HonestBillingReadsTest do
  @moduledoc """
  Honest reads, kernel phase C (billing): a failed price / prior-movement read is never recorded as a zero-MRR
  movement, a `:new` that was a reactivation, or a "nothing to backfill" success. Each case fails the REAL read
  (a price resource that does not exist, so `Ash.read!` raises) and pairs it with a positive control through the same
  seam, so the assertion cannot be a tautology.
  """
  use Demo.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  require Ash.Query

  alias Demo.BillingScope.{Customer, Plan, Price, Subscription, SubscriptionEvent}
  alias Demo.Identity.Org
  alias Samen.Billing.{MovementBackfill, SubscriptionMovement}

  defp mk_org(name) do
    {:ok, org} = Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org
  end

  defp fixture(name) do
    org = mk_org(name)

    {:ok, cust} =
      Customer |> Ash.Changeset.for_create(:create, %{org_id: org.id, status: :active}) |> Ash.create(authorize?: false)

    {:ok, plan} =
      Plan |> Ash.Changeset.for_create(:create, %{org_id: org.id, name: "Pro", interval: :monthly}) |> Ash.create(authorize?: false)

    {:ok, _} =
      Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        plan_id: plan.id,
        unit_amount: Samen.Type.Money.from_cents(9_900, :USD),
        interval: :monthly,
        active: true
      })
      |> Ash.create(authorize?: false)

    {org, cust, plan}
  end

  defp mk_sub(org, cust, plan) do
    {:ok, s} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, customer_id: cust.id, plan_id: plan.id, status: :active})
      |> Ash.create(authorize?: false)

    s
  end

  defp rows(sub_id),
    do: SubscriptionEvent |> Ash.Query.filter(subscription_id == ^sub_id) |> Ash.read!(authorize?: false)

  defp wipe(org_id),
    do: Repo.delete_all(from(e in "mov_subscription_event", where: e.mov_org_id == type(^org_id, Ecto.UUID)))

  defp backfill(org, price_resource) do
    MovementBackfill.from_snapshot(
      org_id: org.id,
      subscription_resource: Subscription,
      event_resource: SubscriptionEvent,
      price_resource: price_resource
    )
  end

  describe "MovementBackfill — a failed price read is not a zero summary or a zero-MRR seed" do
    test "RED: the price read fails -> {:error, :unavailable}, nothing seeded, reported by name" do
      {org, cust, plan} = fixture("hb-backfill-red")
      sub = mk_sub(org, cust, plan)
      wipe(org.id)

      log = capture_log(fn -> assert {:error, :unavailable} = backfill(org, Demo.NoSuchPrice) end)

      assert log =~ "write=movement_backfill"
      assert rows(sub.id) == []
    end

    test "POSITIVE CONTROL: the same run with a readable price resource seeds the real MRR" do
      {org, cust, plan} = fixture("hb-backfill-green")
      sub = mk_sub(org, cust, plan)
      wipe(org.id)

      assert {:ok, %{seeded: 1}} = backfill(org, Price)
      assert [%{mrr_delta_cents: 9_900, reason: :backfill_snapshot}] = rows(sub.id)
    end
  end

  describe "SubscriptionMovement — a failed price read records no wrong-MRR movement, and says so" do
    # The Subscription's own change already appends the real row; a SECOND change instance with an unreadable
    # price resource is run on the same write, so a swallow would add a zero-MRR second row.
    defp create_with_extra_movement(org, cust, plan, opts) do
      Subscription
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, customer_id: cust.id, plan_id: plan.id, status: :active})
      |> then(&SubscriptionMovement.change(&1, [event_resource: SubscriptionEvent] ++ opts, %{}))
      |> Ash.create(authorize?: false)
    end

    test "RED: the price read fails -> the subscription write stands, no extra row, reported" do
      {org, cust, plan} = fixture("hb-move-red")

      log =
        capture_log(fn ->
          assert {:ok, sub} = create_with_extra_movement(org, cust, plan, price_resource: Demo.NoSuchPrice)
          # only the real change's row: the failed one must not add a zero-MRR movement
          assert [%{mrr_delta_cents: 9_900}] = rows(sub.id)
        end)

      assert log =~ "write=subscription_movement_append"
    end

    test "POSITIVE CONTROL: a readable price resource appends its row (two, one per change instance)" do
      {org, cust, plan} = fixture("hb-move-green")

      log =
        capture_log(fn ->
          assert {:ok, sub} = create_with_extra_movement(org, cust, plan, price_resource: Price)
          assert length(rows(sub.id)) == 2
        end)

      refute log =~ "subscription_movement_append"
    end
  end
end
