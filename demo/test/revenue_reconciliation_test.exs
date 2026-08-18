defmodule Demo.RevenueReconciliationTest do
  @moduledoc """
  WS-B / Phase B2 (ADR-017/018) — the LOAD-BEARING reconciliation proof, Invariant R1.

  R1: for any period, `opening_mrr + Σ(mov_mrr_delta_cents) == closing_mrr`, where
  opening/closing are the INDEPENDENTLY-computed live snapshot MRRs at the period
  boundaries (sum of active subscriptions × their plan's monthly price — the SAME
  logic `Operator.Reads.platform_billing/2` uses, not derived from the ledger).

  The chain under test end-to-end:

      subscription lifecycle → SubscriptionMovement change → `mov` ledger
        → `revenue_rollup` (:source :domain) refresh → `mrr_revenue_rollup` rows
        → `Samen.Revenue.Metrics.waterfall/1` → closing_cents

  and asserts `waterfall.closing_cents == independent snapshot closing MRR` TO THE
  CENT. This is the reconciliation the whole G7 tier rests on: the ledger is only
  trustworthy because it reconciles, and the waterfall's `closing` is not read from
  the ledger — it is `opening + Σdelta`, checked against a number computed a
  different way.

  RED PATH (AC-G7-5, anti-tautology): a misclassified movement (an expansion
  captured as a `:noop`, delta 0 — the exact failure the classifier would produce)
  makes the rollup net diverge from the snapshot delta → the reconciliation FAILS.
  We simulate the misclassification by rewriting one ledger row's delta (a
  classifier that misattributed would have written that wrong delta), re-refresh the
  rollup, show the SAME assertion now FAILS, then RESTORE the correct delta and show
  it passes again — proving the reconciliation is load-bearing, not tautological.
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.{Customer, Subscription, Plan, Price}
  alias Demo.Identity.Org
  alias Samen.Revenue.Metrics
  alias Samen.Rollup

  require Ash.Query

  # ---- fixtures (mirror the B1 ledger test's helpers) ------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_customer(org_id) do
    {:ok, c} =
      Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, status: :active})
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_plan(org_id, name) do
    {:ok, p} =
      Plan
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, interval: :monthly})
      |> Ash.create(authorize?: false)

    p
  end

  defp mk_price(org_id, plan_id, cents) do
    {:ok, pr} =
      Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        plan_id: plan_id,
        # ADR-036 §4.5: unit_amount_cents/currency dropped by the H1 Money migration.
        unit_amount: Samen.Type.Money.from_cents(cents, :USD),
        interval: :monthly,
        active: true
      })
      |> Ash.create(authorize?: false)

    pr
  end

  defp mk_subscription(org_id, customer_id, plan_id, status) do
    {:ok, s} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: customer_id,
        plan_id: plan_id,
        status: status
      })
      |> Ash.create(authorize?: false)

    s
  end

  defp update_sub(sub, attrs) do
    {:ok, s} = sub |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(authorize?: false)
    s
  end

  # ---- the INDEPENDENT snapshot MRR (NOT derived from the ledger) ------------

  # The live snapshot MRR for an org: Σ over ACTIVE subscriptions of the plan's
  # monthly active price. This is the SAME shape as Operator.Reads.platform_billing/2
  # — computed straight from the current subscription/price rows, entirely
  # independent of the `mov` ledger and the rollup.
  defp snapshot_mrr_cents(org_id) do
    prices = monthly_prices_by_plan(org_id)

    Subscription
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.ensure_selected([:status, :plan_id, :org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn s, acc ->
      if s.status == :active, do: acc + Map.get(prices, s.plan_id, 0), else: acc
    end)
  end

  # ADR-036 §4.5: unit_amount_cents dropped by the H1 Money migration; unit_amount
  # is now the Money composite — extract minor units.
  defp monthly_prices_by_plan(org_id) do
    Price
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval, :active, :org_id])
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.plan_id, Samen.Type.Money.cents(&1.unit_amount)})
  end

  # ---- read the rollup (what the dashboard reads — NEVER a live movement scan) --

  # The by-kind rollup rows for one org across ALL periods (a single test's
  # movements all land in the current month, so this covers the period).
  defp rollup_rows(org_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT mrr_kind, mrr_delta_cents, mrr_count
        FROM mrr_revenue_rollup
        WHERE mrr_org_id = $1
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    Enum.map(rows, fn [kind, delta, count] -> %{kind: kind, delta_cents: delta, count: count} end)
  end

  defp waterfall_for(org_id, opening_cents) do
    org_id
    |> rollup_rows()
    |> Metrics.movement_sums_from_rollup_rows(opening_cents: opening_cents)
    |> Metrics.waterfall()
  end

  # ---- AC-G7-4: the reconciliation invariant R1 (green) ----------------------

  describe "AC-G7-4 — the MRR waterfall reconciles to the snapshot delta to the cent" do
    test "a full lifecycle: opening + Σmov_delta == closing snapshot MRR" do
      org = mk_org("recon")
      cust = mk_customer(org.id)
      pro = mk_plan(org.id, "Pro")
      biz = mk_plan(org.id, "Business")
      mk_price(org.id, pro.id, 9_900)
      mk_price(org.id, biz.id, 19_900)

      # Opening MRR (before any subscription exists) is 0 — the independent snapshot.
      opening = snapshot_mrr_cents(org.id)
      assert opening == 0

      # new(9900) → upgrade(19900) → downgrade(9900) → cancel(0) → reactivate(9900).
      sub = mk_subscription(org.id, cust.id, pro.id, :active)
      sub = update_sub(sub, %{plan_id: biz.id})
      sub = update_sub(sub, %{plan_id: pro.id})
      sub = update_sub(sub, %{status: :cancelled})
      _sub = update_sub(sub, %{status: :active})

      # Closing MRR — computed INDEPENDENTLY from the current subscription/price rows.
      closing_snapshot = snapshot_mrr_cents(org.id)
      assert closing_snapshot == 9_900

      # Refresh the domain-sourced rollup (the dashboard's data source), then run the
      # waterfall over the ROLLUP rows — never a live movement scan.
      {:ok, _} = Rollup.rebuild_all(Repo)
      w = waterfall_for(org.id, opening)

      # R1: the waterfall's closing (opening + Σsigned deltas from the rollup) equals
      # the independently-computed snapshot MRR — TO THE CENT.
      assert w.closing_cents == closing_snapshot
      assert w.net_change_cents == closing_snapshot - opening
    end

    test "a multi-customer book reconciles (sum of independent per-sub deltas)" do
      org = mk_org("recon-multi")
      pro = mk_plan(org.id, "Pro")
      biz = mk_plan(org.id, "Business")
      mk_price(org.id, pro.id, 9_900)
      mk_price(org.id, biz.id, 19_900)

      opening = snapshot_mrr_cents(org.id)

      # Cust A: new @ 9900, upgrade to 19900 (net +19900).
      a = mk_customer(org.id)
      sa = mk_subscription(org.id, a.id, pro.id, :active)
      _sa = update_sub(sa, %{plan_id: biz.id})

      # Cust B: new @ 9900, then cancel (net 0).
      b = mk_customer(org.id)
      sb = mk_subscription(org.id, b.id, pro.id, :active)
      _sb = update_sub(sb, %{status: :cancelled})

      # Cust C: new @ 19900, stays (net +19900).
      c = mk_customer(org.id)
      _sc = mk_subscription(org.id, c.id, biz.id, :active)

      closing_snapshot = snapshot_mrr_cents(org.id)
      # A(19900) + B(0) + C(19900) = 39800
      assert closing_snapshot == 39_800

      {:ok, _} = Rollup.rebuild_all(Repo)
      w = waterfall_for(org.id, opening)

      assert w.closing_cents == closing_snapshot
    end
  end

  # ---- AC-G7-5: the reconciliation RED PATH (anti-tautology) -----------------

  describe "AC-G7-5 (RECONCILIATION RED-PATH) — a misclassified movement breaks R1" do
    test "sabotage (expansion→noop, delta 0) diverges → FAILS; restore → reconciles" do
      org = mk_org("recon-redpath")
      cust = mk_customer(org.id)
      pro = mk_plan(org.id, "Pro")
      biz = mk_plan(org.id, "Business")
      mk_price(org.id, pro.id, 9_900)
      mk_price(org.id, biz.id, 19_900)

      opening = snapshot_mrr_cents(org.id)

      # new(9900) → upgrade(19900). The upgrade is an :expansion, delta +10_000.
      sub = mk_subscription(org.id, cust.id, pro.id, :active)
      _sub = update_sub(sub, %{plan_id: biz.id})

      closing_snapshot = snapshot_mrr_cents(org.id)
      assert closing_snapshot == 19_900

      # GREEN baseline: reconciles.
      {:ok, _} = Rollup.rebuild_all(Repo)
      good = waterfall_for(org.id, opening)
      assert good.closing_cents == closing_snapshot

      # Capture the correct expansion row so we can restore it byte-exact.
      %{rows: [[exp_id, correct_delta]]} =
        Repo.query!(
          """
          SELECT mov_id, mov_mrr_delta_cents
          FROM mov_subscription_event
          WHERE mov_org_id = $1 AND mov_kind = 'expansion'
          """,
          [Ecto.UUID.dump!(org.id)]
        )

      assert correct_delta == 10_000

      # SABOTAGE: a classifier that misattributed this expansion as a :noop would have
      # written kind=noop, delta=0. Rewrite the ledger row to simulate exactly that
      # misclassification (the classifier is the source of these values).
      {:ok, _} =
        Repo.query(
          """
          UPDATE mov_subscription_event
          SET mov_kind = 'noop', mov_mrr_delta_cents = 0
          WHERE mov_id = $1
          """,
          [exp_id]
        )

      # Re-refresh the rollup from the SABOTAGED ledger; the net now loses +10_000.
      {:ok, _} = Rollup.rebuild_all(Repo)
      sabotaged = waterfall_for(org.id, opening)

      # The RED PATH: reconciliation is now BROKEN. The waterfall closing diverges
      # from the independent snapshot by exactly the misattributed delta ($100).
      refute sabotaged.closing_cents == closing_snapshot
      assert closing_snapshot - sabotaged.closing_cents == 10_000

      # An `assert` on R1 (as AC-G7-4 makes) would FAIL here — prove it does, so the
      # reconciliation is demonstrably load-bearing (not a tautology that passes
      # regardless of the ledger).
      assert_raise ExUnit.AssertionError, fn ->
        assert sabotaged.closing_cents == closing_snapshot
      end

      # RESTORE the correct delta (byte-exact) and re-refresh; R1 holds again.
      {:ok, _} =
        Repo.query(
          """
          UPDATE mov_subscription_event
          SET mov_kind = 'expansion', mov_mrr_delta_cents = $2
          WHERE mov_id = $1
          """,
          [exp_id, correct_delta]
        )

      {:ok, _} = Rollup.rebuild_all(Repo)
      restored = waterfall_for(org.id, opening)
      assert restored.closing_cents == closing_snapshot
    end
  end

  # ---- AC-G7-6: the dashboard reads the rollup, never a live movement scan ---

  describe "AC-G7-6 — RevenueRollup is a :source :domain spec refreshed by the worker" do
    test "revenue_rollup registers as :source :domain and materialises from the mov ledger" do
      spec = Rollup.spec(:revenue_rollup)
      assert spec.source == :domain
      assert spec.table == "mrr_revenue_rollup"
      assert is_binary(spec.subject_delete_sql)

      org = mk_org("recon-rollup")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      mk_price(org.id, plan.id, 9_900)
      _sub = mk_subscription(org.id, cust.id, plan.id, :active)

      # The refresh worker's rebuild materialises the rollup from mov (a DOMAIN table).
      {:ok, results} = Rollup.rebuild_all(Repo)
      assert Map.has_key?(results, :revenue_rollup)

      # The dashboard reads the ROLLUP table (never a live movement scan) and sees the
      # new row.
      rows = rollup_rows(org.id)
      new_row = Enum.find(rows, &(&1.kind == "new"))
      assert new_row.delta_cents == 9_900
      assert new_row.count == 1
    end
  end
end
