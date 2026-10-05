defmodule Demo.UsageQuotaTest do
  @moduledoc """
  T163 (ADR-051 P3) on the DEMO host's real Postgres: `Samen.Billing.Quota.within_limit?/4`
  reads the per-period `limit` mirrored onto an `Entitlement` row and the usage the
  insert-only ledger holds for the subscription's current period.

    * Within / at / over the limit, with the prospective `quantity` counted.
    * The period is the subscription's `[current_period_start, current_period_end)`;
      another subscription's events never count, the org's unsubscribed ones do.
    * `nil` is an explicit unlimited.
    * R6 — fail closed: an absent limit row or an unreadable period is
      `{:error, _}`, never `{:ok, true}`.
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.{Customer, Entitlement, Plan, Subscription, UsageEvent}
  alias Demo.Identity.Org
  alias Samen.Billing.{Meter, Quota}

  @start ~U[2026-07-01 00:00:00Z]
  @stop ~U[2026-08-01 00:00:00Z]
  @at ~U[2026-07-20 12:00:00Z]

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_subscription(org_id, period \\ {@start, @stop}) do
    {:ok, c} =
      Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, status: :active})
      |> Ash.create(authorize?: false)

    {:ok, p} =
      Plan
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "metered", interval: :monthly})
      |> Ash.create(authorize?: false)

    {period_start, period_end} = period

    {:ok, s} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: c.id,
        plan_id: p.id,
        status: :active,
        current_period_start: period_start,
        current_period_end: period_end
      })
      |> Ash.create(authorize?: false)

    s
  end

  defp grant(org_id, sub_id, attrs) do
    {:ok, e} =
      Entitlement
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{org_id: org_id, subscription_id: sub_id, feature: :api_access, metric: :api_calls},
          attrs
        )
      )
      |> Ash.create(authorize?: false)

    e
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

  defp check(org_id, quantity, opts \\ []) do
    check(org_id, :api_calls, quantity, opts)
  end

  defp check(org_id, metric, quantity, opts) do
    Quota.within_limit?(
      org_id,
      metric,
      quantity,
      Keyword.merge(
        [entitlement: Entitlement, subscription: Subscription, usage_event: UsageEvent, at: @at],
        opts
      )
    )
  end

  defp setup_limited(name, limit) do
    org = mk_org(name)
    sub = mk_subscription(org.id)
    grant(org.id, sub.id, %{limit: limit})
    %{org_id: org.id, sub_id: sub.id}
  end

  describe "within the limit" do
    test "under, at, and over the limit, counting the prospective quantity" do
      %{org_id: o, sub_id: s} = setup_limited("quota-basic", 10)
      capture(o, s, "a", %{quantity: 6})
      capture(o, s, "b", %{quantity: 2})

      assert {:ok, true} = check(o, 0)
      assert {:ok, true} = check(o, 2)
      assert {:ok, false} = check(o, 3)

      capture(o, s, "c", %{quantity: 2})
      assert {:ok, true} = check(o, 0)
      assert {:ok, false} = check(o, 1)
    end

    test "an org with no usage yet is within its limit; a zero limit admits nothing more" do
      %{org_id: o} = setup_limited("quota-empty", 5)
      assert {:ok, true} = check(o, 5)
      assert {:ok, false} = check(o, 6)

      %{org_id: z} = setup_limited("quota-zero", 0)
      assert {:ok, true} = check(z, 0)
      assert {:ok, false} = check(z, 1)
    end

    test "only the current period counts; another subscription's events never do; unsubscribed ones do" do
      %{org_id: o, sub_id: s} = setup_limited("quota-period", 10)
      other = mk_subscription(o).id

      capture(o, s, "in", %{quantity: 4})
      capture(o, s, "at-end", %{quantity: 100, occurred_at: @stop})
      capture(o, s, "before", %{quantity: 100, occurred_at: ~U[2026-06-30 23:59:59Z]})
      capture(o, s, "messages", %{metric: :messages, quantity: 100})
      capture(o, other, "other-sub", %{quantity: 100})
      capture(o, nil, "no-sub", %{quantity: 3})

      # 4 (this subscription) + 3 (unsubscribed) = 7 used of 10.
      assert {:ok, true} = check(o, 3)
      assert {:ok, false} = check(o, 4)
    end

    test "another org's usage never counts against this org" do
      %{org_id: o} = setup_limited("quota-org-a", 10)
      %{org_id: b, sub_id: bs} = setup_limited("quota-org-b", 10)
      capture(b, bs, "b-usage", %{quantity: 10})

      assert {:ok, true} = check(o, 10)
      assert {:ok, false} = check(b, 1)
    end

    test "a nil limit is an explicit unlimited" do
      %{org_id: o, sub_id: s} = setup_limited("quota-unlimited", nil)
      capture(o, s, "lots", %{quantity: 1_000_000})

      assert {:ok, true} = check(o, 1_000_000)
    end

    test "the check is a read: an over-limit org can still capture usage" do
      %{org_id: o, sub_id: s} = setup_limited("quota-read-only", 1)
      capture(o, s, "a", %{quantity: 1})
      assert {:ok, false} = check(o, 1)

      capture(o, s, "b", %{quantity: 1})
      assert {:ok, false} = check(o, 0)
    end
  end

  describe "R6 — the limit check fails closed" do
    test "no entitlement row carrying the metric is an error, never {:ok, true}" do
      org = mk_org("quota-no-row")
      sub = mk_subscription(org.id)
      assert {:error, :no_limit} = check(org.id, 0)

      # A plain feature grant (no metric), a row for another metric, a revoked row, an
      # expired row, and another org's row are all still no limit for :api_calls.
      grant(org.id, sub.id, %{feature: :sso, metric: nil, limit: nil})
      grant(org.id, sub.id, %{metric: :messages, limit: nil})
      grant(org.id, sub.id, %{limit: nil, granted: false})
      grant(org.id, sub.id, %{limit: nil, expires_at: ~U[2026-07-10 00:00:00Z]})
      %{org_id: other_org} = setup_limited("quota-no-row-other", nil)
      assert other_org != org.id

      assert {:error, :no_limit} = check(org.id, 0)

      # Positive control: the same org with a row for the metric answers.
      grant(org.id, sub.id, %{limit: nil})
      assert {:ok, true} = check(org.id, 0)
    end

    test "an unreadable period is an error: none, ended, or not started" do
      org = mk_org("quota-no-period")
      no_period = mk_subscription(org.id, {nil, nil})
      grant(org.id, no_period.id, %{limit: 10})
      assert {:error, :no_current_period} = check(org.id, 0)

      ended = mk_org("quota-ended")
      ended_sub = mk_subscription(ended.id, {~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z]})
      grant(ended.id, ended_sub.id, %{limit: 10})
      assert {:error, :no_current_period} = check(ended.id, 0)

      # The period end is exclusive: at exactly `end` the period is over.
      %{org_id: o} = setup_limited("quota-at-end", 10)
      assert {:error, :no_current_period} = check(o, 0, at: @stop)
      assert {:ok, true} = check(o, 0, at: @start)
    end

    test "several subscriptions limiting the same metric are ambiguous until one is picked" do
      %{org_id: o, sub_id: s} = setup_limited("quota-ambiguous", 10)
      second = mk_subscription(o).id
      grant(o, second, %{limit: 1})
      capture(o, s, "a", %{quantity: 5})

      assert {:error, :ambiguous_limit} = check(o, 0)
      assert {:ok, true} = check(o, 5, subscription_id: s)
      # The second subscription counts only its own events plus unsubscribed ones:
      # 0 used of 1.
      assert {:ok, true} = check(o, 1, subscription_id: second)
      assert {:ok, false} = check(o, 2, subscription_id: second)
    end

    test "invalid input is an error" do
      %{org_id: o} = setup_limited("quota-invalid", 10)

      assert {:error, :invalid_org_id} = check("not-a-uuid", 0)
      assert {:error, :invalid_metric} = check(o, :dollars, 0, [])
      assert {:error, :invalid_quantity} = check(o, -1)
      assert {:error, :invalid_quantity} = check(o, 1.5)
    end
  end

  test "the Entitlement table refuses a negative limit" do
    org = mk_org("quota-negative")
    sub = mk_subscription(org.id)

    assert {:error, _} =
             Entitlement
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               subscription_id: sub.id,
               feature: :api_access,
               metric: :api_calls,
               limit: -1
             })
             |> Ash.create(authorize?: false)
  end
end
