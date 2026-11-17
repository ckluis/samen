defmodule Demo.MovementContinuityTest do
  @moduledoc """
  Kernel phase C review S4: a skipped `mov` row (a failed price read makes `SubscriptionMovement` write no row and
  report) leaves a hole the ledger-continuity check FINDS. Each case pairs a healthy ledger (clean) with a skipped
  movement (found) through the same seam, so the check cannot be a tautology. The skip is the REAL change code run with a
  price resource that does not exist, on a changeset whose own movement hook is removed.

  It also measures which failures roll the subscription write back (N1): a failure that sends no SQL leaves the write
  standing; a failing SQL statement inside the write's transaction aborts it, and the write is lost with it.
  """
  use Demo.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  require Ash.Query

  alias Demo.BillingScope.{Customer, Plan, Price, Subscription, SubscriptionEvent}
  alias Demo.Identity.Org
  alias Mix.Tasks.Samen.Verify.MovementContinuity, as: Task
  alias Samen.Billing.{MovementContinuity, SubscriptionMovement}

  defp fixture(name) do
    {:ok, org} = Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

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

    {:ok, sub} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, customer_id: cust.id, plan_id: plan.id, status: :active})
      |> Ash.create(authorize?: false)

    {org, sub}
  end

  defp check(org),
    do:
      MovementContinuity.violations(
        subscription_resource: Subscription,
        event_resource: SubscriptionEvent,
        price_resource: Price,
        org_id: org.id
      )

  defp rows(sub_id),
    do: SubscriptionEvent |> Ash.Query.filter(subscription_id == ^sub_id) |> Ash.read!(authorize?: false)

  # An update whose OWN movement hook is dropped and replaced by the real change run against `price_resource`.
  defp update_with_movement(sub, attrs, price_resource) do
    sub
    |> Ash.Changeset.for_update(:update, attrs)
    |> then(&%{&1 | after_action: []})
    |> then(&SubscriptionMovement.change(&1, [event_resource: SubscriptionEvent, price_resource: price_resource], %{}))
    |> Ash.update(authorize?: false)
  end

  describe "MovementContinuity.violations/1" do
    test "POSITIVE CONTROL: a healthy ledger (create, cancel, reactivate) is clean" do
      {org, sub} = fixture("mc-healthy")
      assert {:ok, sub} = update_with_movement(sub, %{status: :cancelled}, Price)
      assert {:ok, _} = update_with_movement(sub, %{status: :active}, Price)

      assert length(rows(sub.id)) == 3
      assert check(org) == []
    end

    test "RED: a skipped movement (the price read fails once) is FOUND as a stale tail; the write stands" do
      {org, sub} = fixture("mc-skip")

      log =
        capture_log(fn ->
          assert {:ok, %{status: :cancelled}} = update_with_movement(sub, %{status: :cancelled}, Demo.NoSuchPrice)
        end)

      assert log =~ "write=subscription_movement_append"
      assert length(rows(sub.id)) == 1
      assert [violation] = check(org)
      assert violation =~ sub.id and violation =~ "stale_tail"
    end

    test "RED: a movement skipped in the middle breaks the chain at the row after it" do
      {org, sub} = fixture("mc-skip-middle")

      capture_log(fn -> assert {:ok, _} = update_with_movement(sub, %{status: :cancelled}, Demo.NoSuchPrice) end)
      sub = Ash.get!(Subscription, sub.id, authorize?: false)
      assert {:ok, _} = update_with_movement(sub, %{status: :active}, Price)

      assert Enum.any?(check(org), &(&1 =~ "chain_break at row 2"))
    end

    test "RED: a revenue-active subscription with no row at all is unseeded; the same sub, seeded, is clean" do
      {org, sub} = fixture("mc-unseeded")
      Repo.delete_all(from(e in "mov_subscription_event", where: e.mov_org_id == type(^org.id, Ecto.UUID)))

      assert [violation] = check(org)
      assert violation =~ sub.id and violation =~ "unseeded"

      assert {:ok, %{seeded: 1}} =
               Samen.Billing.MovementBackfill.from_snapshot(
                 org_id: org.id,
                 subscription_resource: Subscription,
                 event_resource: SubscriptionEvent,
                 price_resource: Price
               )

      assert check(org) == []
    end

    test "output carries ids, classes and cents only" do
      {org, sub} = fixture("mc-output")
      capture_log(fn -> update_with_movement(sub, %{status: :cancelled}, Demo.NoSuchPrice) end)
      assert [violation] = check(org)
      refute violation =~ org.name
    end
  end

  describe "mix samen.verify.movement_continuity discovery" do
    test "finds the demo subscription resource with its ledger and price resources" do
      assert [[subscription_resource: Subscription, event_resource: SubscriptionEvent, price_resource: Price]] =
               Task.targets([Subscription, Customer])

      assert Task.targets([Customer]) == []
    end
  end

  describe "which failures roll the subscription write back (N1)" do
    test "a failure that sends no SQL (an unresolvable price resource) leaves the subscription write standing" do
      {_org, sub} = fixture("mc-n1-nosql")
      capture_log(fn -> assert {:ok, _} = update_with_movement(sub, %{status: :cancelled}, Demo.NoSuchPrice) end)
      assert Ash.get!(Subscription, sub.id, authorize?: false).status == :cancelled
    end

    test "a failing SQL statement inside the write's transaction aborts the transaction, and the write is lost" do
      {_org, sub} = fixture("mc-n1-sql")
      Repo.query!("ALTER TABLE bpr_price RENAME TO bpr_price_gone")

      capture_log(fn -> assert {:error, _} = update_with_movement(sub, %{status: :cancelled}, Price) end)

      Repo.query!("ALTER TABLE bpr_price_gone RENAME TO bpr_price")
      assert Ash.get!(Subscription, sub.id, authorize?: false).status == :active
    end
  end
end
