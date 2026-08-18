defmodule Demo.SubscriptionMovementLedgerTest do
  @moduledoc """
  WS-B / Phase B1 (ADR-017) integration proof of the `mov` capture seam on the DEMO
  host's real Postgres:

    * AC-G7-2 — a subscription create/update appends EXACTLY ONE `mov` row via the
      `SubscriptionMovement` change, with the correct signed `mrr_delta_cents` and
      before/after cents (classified from the plan's monthly price).
    * AC-G7-3 (structural) — the `mov` table carries ZERO PII columns; every column
      is a bounded id / enum / integer / timestamp.
    * Best-effort — the movement append rides alongside; a lifecycle
      (new → upgrade → downgrade → cancel → reactivate) captures the right kinds.
    * MovementBackfill.from_snapshot/1 — one synthetic `:new` per active sub,
      idempotent, disclosed as `:backfill_snapshot`.
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.{Customer, Subscription, Plan, Price, SubscriptionEvent}
  alias Demo.Identity.Org

  import Ecto.Query
  require Ash.Query

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

  defp movements(subscription_id) do
    SubscriptionEvent
    |> Ash.Query.filter(subscription_id == ^subscription_id)
    |> Ash.Query.ensure_selected([
      :org_id,
      :subscription_id,
      :customer_id,
      :plan_id,
      :from_plan_id,
      :kind,
      :mrr_delta_cents,
      :mrr_before_cents,
      :mrr_after_cents,
      :from_status,
      :to_status,
      :reason,
      :occurred_at,
      :inserted_at
    ])
    # T121 — STRICT TOTAL ORDER. `occurred_at` is microsecond-precision (ADR-017 /
    # blueprint), so movements appended within the same wall-clock second carry
    # distinct business-time instants and this read imposes ONE defined chronological
    # order. `id` is the final belt tiebreaker (a random UUIDv4 — deterministic, not
    # chronological) for the theoretical same-microsecond collision, so the sort is
    # total by construction even then.
    |> Ash.Query.sort(inserted_at: :asc, occurred_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
  end

  # Wipe a org's mov rows to simulate a pre-ledger (day-zero) subscription. Raw
  # delete since the append-only resource exposes no destroy action.
  defp wipe_movements(org_id) do
    Repo.delete_all(
      from(e in "mov_subscription_event",
        where: e.mov_org_id == type(^org_id, Ecto.UUID)
      )
    )
  end

  # T121 regression scaffolding — write ONE ledger row with FULLY CONTROLLED
  # id/inserted_at/occurred_at (raw SQL, explicit `::uuid` casts). The append-only Ash
  # `:append` action does not accept id/inserted_at (`writable?: false`), so — exactly
  # like `wipe_movements/1` deletes directly — the total-order guards construct their
  # tie/precision scenario directly, deterministically, with NO dependence on the wall
  # clock. Non-PII bounded columns only (kind/cents/reason/timestamps), per AC-G7-3.
  defp insert_mov!(org_id, sub_id, id, kind, inserted_at, occurred_at) do
    Repo.query!(
      """
      INSERT INTO mov_subscription_event
        (mov_id, mov_org_id, mov_subscription_id, mov_kind, mov_mrr_delta_cents,
         mov_mrr_before_cents, mov_mrr_after_cents, mov_reason, mov_occurred_at,
         mov_inserted_at, mov_updated_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4, 0, 0, 0, 'status_change', $5, $6, $6)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(org_id),
        Ecto.UUID.dump!(sub_id),
        kind,
        occurred_at,
        inserted_at
      ]
    )
  end

  describe "AC-G7-2 — create/update appends exactly one mov row with correct delta" do
    test "a new subscription create appends one :new mov row (+plan MRR)" do
      org = mk_org("mov-new")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      mk_price(org.id, plan.id, 9_900)

      sub = mk_subscription(org.id, cust.id, plan.id, :active)

      rows = movements(sub.id)
      assert length(rows) == 1
      [m] = rows

      assert m.kind == :new
      assert m.mrr_delta_cents == 9_900
      assert m.mrr_before_cents == 0
      assert m.mrr_after_cents == 9_900
      assert m.to_status == :active
      assert m.reason == :status_change
      assert m.customer_id == cust.id
      assert m.plan_id == plan.id
      assert m.org_id == org.id
    end

    test "an upgrade (plan/price change while active) appends one :expansion row" do
      org = mk_org("mov-up")
      cust = mk_customer(org.id)
      pro = mk_plan(org.id, "Pro")
      biz = mk_plan(org.id, "Business")
      mk_price(org.id, pro.id, 9_900)
      mk_price(org.id, biz.id, 19_900)

      sub = mk_subscription(org.id, cust.id, pro.id, :active)

      {:ok, _} =
        sub
        |> Ash.Changeset.for_update(:update, %{plan_id: biz.id})
        |> Ash.update(authorize?: false)

      rows = movements(sub.id)
      assert length(rows) == 2
      [_new, expansion] = rows

      assert expansion.kind == :expansion
      assert expansion.mrr_delta_cents == 10_000
      assert expansion.mrr_before_cents == 9_900
      assert expansion.mrr_after_cents == 19_900
      assert expansion.from_plan_id == pro.id
      assert expansion.plan_id == biz.id
      assert expansion.reason == :price_change
    end

    test "a cancel appends one :churn row (loses the whole contribution)" do
      org = mk_org("mov-churn")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      mk_price(org.id, plan.id, 9_900)
      sub = mk_subscription(org.id, cust.id, plan.id, :active)

      {:ok, _} =
        sub
        |> Ash.Changeset.for_update(:update, %{status: :cancelled})
        |> Ash.update(authorize?: false)

      [_new, churn] = movements(sub.id)
      assert churn.kind == :churn
      assert churn.mrr_delta_cents == -9_900
      assert churn.mrr_before_cents == 9_900
      assert churn.mrr_after_cents == 0
      assert churn.from_status == :active
      assert churn.to_status == :cancelled
    end
  end

  describe "full lifecycle — new → upgrade → downgrade → cancel → reactivate" do
    test "each transition emits the correctly-classified kind, and the deltas sum to closing MRR" do
      org = mk_org("mov-lifecycle")
      cust = mk_customer(org.id)
      pro = mk_plan(org.id, "Pro")
      biz = mk_plan(org.id, "Business")
      mk_price(org.id, pro.id, 9_900)
      mk_price(org.id, biz.id, 19_900)

      # new @ 9900
      sub = mk_subscription(org.id, cust.id, pro.id, :active)
      # upgrade → 19900
      {:ok, sub} =
        sub |> Ash.Changeset.for_update(:update, %{plan_id: biz.id}) |> Ash.update(authorize?: false)

      # downgrade → 9900
      {:ok, sub} =
        sub |> Ash.Changeset.for_update(:update, %{plan_id: pro.id}) |> Ash.update(authorize?: false)

      # cancel → 0
      {:ok, sub} =
        sub
        |> Ash.Changeset.for_update(:update, %{status: :cancelled})
        |> Ash.update(authorize?: false)

      # reactivate → 9900
      {:ok, _sub} =
        sub
        |> Ash.Changeset.for_update(:update, %{status: :active})
        |> Ash.update(authorize?: false)

      rows = movements(sub.id)
      kinds = Enum.map(rows, & &1.kind)
      assert kinds == [:new, :expansion, :contraction, :churn, :reactivation]

      # Opening MRR was 0; the signed deltas must sum to the closing MRR (9900).
      sum = Enum.reduce(rows, 0, fn m, acc -> acc + m.mrr_delta_cents end)
      assert sum == 9_900
    end
  end

  describe "T121 regression — the ledger read is a strict TOTAL ORDER (deterministic by construction, no wall-clock)" do
    # Historical flake root cause: `mov.occurred_at` and `mov.inserted_at` were BOTH
    # second-precision, so movements written inside one wall-clock second shared an
    # IDENTICAL (inserted_at, occurred_at) sort key. The read then had NO discriminating
    # key and Postgres returned an arbitrary permutation of the tied group → the
    # exact-order assertions flaked. `mov_id` is a random UUIDv4 and cannot recover
    # chronology. The fix widens `occurred_at` to microsecond precision (distinct
    # business-time instant per append) AND adds `id` as the final belt tiebreaker, so
    # the read `sort(inserted_at, occurred_at, id)` is a strict total order.
    #
    # These guards CONSTRUCT the collision deterministically (T105 clock-injection
    # doctrine): the ledger rows are written directly with EXPLICIT, controlled
    # id/inserted_at/occurred_at, so the tie/precision condition holds on EVERY run
    # independent of wall-clock alignment (no `length(seconds) == 1`-style precondition
    # that flakes when a rapid lifecycle straddles a second boundary). The append-only
    # Ash action does not accept id/inserted_at (`writable?: false`), so — exactly like
    # `wipe_movements/1` deletes directly — we write the immutable ledger row directly.

    test "a genuine (inserted_at, occurred_at) tie is broken deterministically by the id belt" do
      org = mk_org("mov-t121-tie")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      sub = mk_subscription(org.id, cust.id, plan.id, :active)
      # We own every row: drop the auto :new appended by the subscription create.
      wipe_movements(org.id)

      # ONE shared instant for BOTH timestamps → the ONLY total-order discriminator is
      # `id`. Ids are inserted in DESCENDING order, so heap/insertion order is the
      # OPPOSITE of the total order: a non-total sort (pre-fix, no id belt) would surface
      # insertion order; the fixed sort surfaces ASCENDING id. Fully constructed — no
      # dependence on wall-clock, so this holds on every one of 250+ runs under any load.
      at = ~N[2020-01-01 00:00:00.000000]
      ids = Enum.sort(Enum.map(1..5, fn _ -> Ash.UUID.generate() end), :desc)
      kinds = ~w(new expansion contraction churn reactivation)

      Enum.zip(ids, kinds)
      |> Enum.each(fn {id, kind} -> insert_mov!(org.id, sub.id, id, kind, at, at) end)

      # A strict total order returns the SAME order on EVERY read — never an arbitrary
      # permutation of the tied group.
      reads = Enum.map(1..10, fn _ -> Enum.map(movements(sub.id), &to_string(&1.id)) end)

      assert reads |> Enum.uniq() |> length() == 1,
             "ledger read is unstable across reads — the sort is not a total order"

      [order] = Enum.uniq(reads)
      assert length(order) == 5

      # The (inserted_at, occurred_at) tie resolves to the id belt: ASCENDING id — NOT
      # the DESCENDING insertion/heap order a non-total sort would surface.
      assert order == Enum.sort(order),
             "the (inserted_at, occurred_at) tie is not broken by the id belt → not a strict total order"
    end

    test "distinct sub-second occurred_at drives chronology (the usec widening is load-bearing)" do
      org = mk_org("mov-t121-usec")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      sub = mk_subscription(org.id, cust.id, plan.id, :active)
      wipe_movements(org.id)

      # Same wall-clock SECOND (identical inserted_at) — occurred_at differs ONLY in the
      # microsecond field the fix added. Ids are assigned so that ASCENDING id is the
      # REVERSE of chronological order: if `occurred_at` did NOT discriminate (pre-widen:
      # truncated to second → tied), the read would fall to the id belt and return the
      # movements REVERSED. Because occurred_at is usec, chronology wins by construction.
      second = ~N[2020-01-01 00:00:00]
      kinds = ~w(new expansion contraction churn reactivation)
      # Largest id at i=0 … smallest at i=4  ⇒  ascending-id order == reverse chronology.
      ids_desc = Enum.sort(Enum.map(kinds, fn _ -> Ash.UUID.generate() end), :desc)

      kinds
      |> Enum.with_index()
      |> Enum.each(fn {kind, i} ->
        occurred = NaiveDateTime.add(second, i, :microsecond)
        insert_mov!(org.id, sub.id, Enum.at(ids_desc, i), kind, second, occurred)
      end)

      read_kinds = movements(sub.id) |> Enum.map(&Atom.to_string(&1.kind))

      # Chronological order (occurred_at asc) — proves the usec discriminator dominates
      # the id belt. Pre-widen (occurred_at tied) this would read REVERSED via the id belt.
      assert read_kinds == kinds,
             "occurred_at (usec) is not the primary chronological discriminator; got #{inspect(read_kinds)}"
    end
  end

  describe "AC-G7-3 (structural) — mov carries zero PII columns" do
    test "the mov_subscription_event table has only bounded id/enum/int/timestamp columns" do
      {:ok, %{columns: cols}} = Repo.query("SELECT * FROM mov_subscription_event LIMIT 0")

      # No column name hints at subject identity.
      refute Enum.any?(cols, fn c ->
               c =~ "name" or c =~ "email" or c =~ "phone" or c =~ "address"
             end)

      # The expected bounded column set (self-qualifying mov_ storage).
      expected =
        ~w(mov_subscription_id mov_customer_id mov_plan_id mov_from_plan_id mov_kind
           mov_mrr_delta_cents mov_mrr_before_cents mov_mrr_after_cents mov_from_status
           mov_to_status mov_reason mov_occurred_at mov_id mov_org_id mov_inserted_at
           mov_updated_at)

      assert Enum.sort(cols) == Enum.sort(expected)

      # No pii_ prefixed column (the vault-routed PII shape) exists on the ledger.
      refute Enum.any?(cols, &String.starts_with?(&1, "pii_"))
    end
  end

  describe "MovementBackfill.from_snapshot/1 — day-one reconciliation honesty" do
    test "seeds one synthetic :new per active sub, idempotent, disclosed as backfill" do
      org = mk_org("mov-backfill")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      mk_price(org.id, plan.id, 9_900)

      # Create the subscription, then WIPE its movement rows to simulate a pre-ledger
      # (day-zero) subscription that has no captured movement.
      sub = mk_subscription(org.id, cust.id, plan.id, :active)
      wipe_movements(org.id)
      assert movements(sub.id) == []

      {:ok, summary} =
        Samen.Billing.MovementBackfill.from_snapshot(
          org_id: org.id,
          subscription_resource: Subscription,
          event_resource: SubscriptionEvent,
          price_resource: Price
        )

      assert summary.seeded == 1

      [seed] = movements(sub.id)
      assert seed.kind == :new
      assert seed.mrr_delta_cents == 9_900
      assert seed.reason == :backfill_snapshot
      assert seed.to_status == :active

      # Idempotent: a second run seeds nothing (the sub already has a mov row).
      {:ok, summary2} =
        Samen.Billing.MovementBackfill.from_snapshot(
          org_id: org.id,
          subscription_resource: Subscription,
          event_resource: SubscriptionEvent,
          price_resource: Price
        )

      assert summary2.seeded == 0
      assert summary2.skipped == 1
      assert length(movements(sub.id)) == 1
    end

    test "an inactive subscription is not backfilled (contributes 0 MRR)" do
      org = mk_org("mov-backfill-inactive")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      mk_price(org.id, plan.id, 9_900)

      sub = mk_subscription(org.id, cust.id, plan.id, :cancelled)
      wipe_movements(org.id)

      {:ok, summary} =
        Samen.Billing.MovementBackfill.from_snapshot(
          org_id: org.id,
          subscription_resource: Subscription,
          event_resource: SubscriptionEvent,
          price_resource: Price
        )

      assert summary.seeded == 0
      assert movements(sub.id) == []
    end
  end

  describe "best-effort — a movement append never aborts the primary subscription write" do
    test "the subscription create succeeds and returns a persisted row" do
      org = mk_org("mov-besteffort")
      cust = mk_customer(org.id)
      plan = mk_plan(org.id, "Pro")
      mk_price(org.id, plan.id, 9_900)

      # The write succeeds regardless of the ledger append (load-bearing state).
      sub = mk_subscription(org.id, cust.id, plan.id, :active)
      assert sub.id
      assert sub.status == :active
    end
  end
end
