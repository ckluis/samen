defmodule Demo.BillingScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the Billing scope (ADR-040 §5.9, T37a): `Plan` and
  `Price` flip `archivable true` (T36's `use Samen.Resource, archivable: true`
  convention, backed by ash_archival). `customer`/`subscription`/`invoice`/
  `payment`/`usage`/`entitlement`/`subscription_event` stay excluded per the
  roster (provider mirrors / derived state / append-only ledgers) and are left
  untouched.

  §5.3: no unique index exists on `bpl_plan`/`bpr_price` — the partial-index
  conversion has nothing to convert for this scope (proven by the c1-style
  archive/restore round trip below finding no `:restore_conflict` case to
  construct; see `_orch/tasks/T37a/handoff.md`).

  §5.5's standing duty for every adopting scope: an archived record must not
  leak via relationship load or aggregate, bypassing the read preparation.
  Every RED here (archived does not surface) is paired with a distinct
  positive-control CONTROL (a live row DOES surface via the same path) so the
  RED assertion is provably falsifiable, not a tautology (house masking-watch-
  list discipline, CLAUDE.md).

  Neither `Plan` nor `Price` carries a vault-routed (🔒) field — INV-1 masking-
  on-archive is not applicable to this scope's adoption (only `Customer` is
  🔒, and `Customer` is excluded from the roster).
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.BillingScope.{Customer, Entitlement, Plan, Price, Subscription}

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  defp mk_plan(org_id, name \\ "Plan") do
    {:ok, plan} =
      Plan
      |> Ash.Changeset.for_create(:create, %{
        name: "#{name}-#{:rand.uniform(999_999)}",
        org_id: org_id,
        interval: :monthly
      })
      |> Ash.create(authorize?: false)

    plan
  end

  defp mk_price(org_id, plan_id) do
    {:ok, price} =
      Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        plan_id: plan_id,
        unit_amount: Samen.Type.Money.from_cents(1999, :USD)
      })
      |> Ash.create(authorize?: false)

    price
  end

  defp mk_customer(org_id) do
    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        billing_name: "Archival Test Co",
        billing_email: "archival@billing.example"
      })
      |> Ash.create(authorize?: false)

    customer
  end

  defp mk_subscription(org_id, customer_id, plan_id) do
    {:ok, sub} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: customer_id,
        plan_id: plan_id,
        status: :active
      })
      |> Ash.create(authorize?: false)

    sub
  end

  defp mk_entitlement(org_id, subscription_id, plan_id) do
    {:ok, ent} =
      Entitlement
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        subscription_id: subscription_id,
        plan_id: plan_id,
        feature: :basic,
        granted: true
      })
      |> Ash.create(authorize?: false)

    ent
  end

  defp live_plan_ids, do: Plan |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()

  defp archived_plan_ids do
    Plan |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp archived_plan(id) do
    Plan |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.find(&(&1.id == id))
  end

  defp live_price_ids, do: Price |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()

  defp archived_price_ids do
    Price |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp archived_price(id) do
    Price |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.find(&(&1.id == id))
  end

  # ── introspection: the adopt-me convention landed on both roster rows ──────

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "Plan and Price report true; the excluded Customer reports false" do
      assert Samen.Info.archivable?(Plan)
      assert Samen.Info.archivable?(Price)
      refute Samen.Info.archivable?(Customer)
    end
  end

  # ── c1: archive hides / :archived shows / restore returns — Plan ───────────

  describe "Plan — archive hides from default read, :archived shows it, restore returns it" do
    test "archive removes Plan from default reads (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
      org = mk_org()
      plan = mk_plan(org)
      assert MapSet.member?(live_plan_ids(), plan.id)

      {:ok, _} = Samen.Archival.archive(plan, authorize?: false)

      # RED: gone from the default read.
      refute MapSet.member?(live_plan_ids(), plan.id)
      # CONTROL: the :archived include-read still sees it — hidden, not gone.
      assert MapSet.member?(archived_plan_ids(), plan.id)

      # ASSERT: restore returns it to the default read.
      {:ok, _} = Samen.Archival.restore(archived_plan(plan.id), authorize?: false)
      assert MapSet.member?(live_plan_ids(), plan.id)
      refute MapSet.member?(archived_plan_ids(), plan.id)
    end
  end

  # ── c1: archive hides / :archived shows / restore returns — Price ──────────

  describe "Price — archive hides from default read, :archived shows it, restore returns it" do
    test "archive removes Price from default reads (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
      org = mk_org()
      plan = mk_plan(org)
      price = mk_price(org, plan.id)
      assert MapSet.member?(live_price_ids(), price.id)

      {:ok, _} = Samen.Archival.archive(price, authorize?: false)

      # RED: gone from the default read.
      refute MapSet.member?(live_price_ids(), price.id)
      # CONTROL: the :archived include-read still sees it — hidden, not gone.
      assert MapSet.member?(archived_price_ids(), price.id)

      # ASSERT: restore returns it to the default read.
      {:ok, _} = Samen.Archival.restore(archived_price(price.id), authorize?: false)
      assert MapSet.member?(live_price_ids(), price.id)
      refute MapSet.member?(archived_price_ids(), price.id)
    end
  end

  # ── §5.5 leak duty: relationship load — Subscription.plan ──────────────────

  describe "§5.5 — an archived Plan does not leak via Subscription.plan relationship load" do
    test "Subscription.plan resolves to nil for an archived plan (RED); a live plan surfaces (CONTROL)" do
      org = mk_org()
      customer = mk_customer(org)

      archived = mk_plan(org, "Archived")
      live = mk_plan(org, "Live")

      sub_on_archived = mk_subscription(org, customer.id, archived.id)
      sub_on_live = mk_subscription(org, customer.id, live.id)

      {:ok, _} = Samen.Archival.archive(archived, authorize?: false)

      # RED: the relationship load does NOT surface the archived plan — the
      # default-read preparation (`is_nil(archived_at)`) applies to the
      # destination resource's read even when reached via a belongs_to load,
      # not just a direct `Ash.read!(Plan)`.
      loaded_on_archived = Ash.load!(sub_on_archived, :plan, authorize?: false)
      assert loaded_on_archived.plan == nil

      # CONTROL (anti-tautology): the exact same relationship load path DOES
      # surface a live plan — proves the nil above is the archival filter
      # firing, not a broken/vacuous load.
      loaded_on_live = Ash.load!(sub_on_live, :plan, authorize?: false)
      assert %Plan{id: live_id} = loaded_on_live.plan
      assert live_id == live.id
    end
  end

  # ── §5.5 leak duty: relationship load — Price.plan ──────────────────────────

  describe "§5.5 — an archived Plan does not leak via Price.plan relationship load" do
    test "Price.plan resolves to nil for an archived plan (RED); a live plan surfaces (CONTROL)" do
      org = mk_org()

      archived = mk_plan(org, "Archived")
      live = mk_plan(org, "Live")

      price_on_archived = mk_price(org, archived.id)
      price_on_live = mk_price(org, live.id)

      {:ok, _} = Samen.Archival.archive(archived, authorize?: false)

      # RED: the second independent belongs_to consumer (Price → Plan) is
      # ALSO filtered — proves the preparation is resource-level (applies to
      # every relationship consumer of Plan), not a one-off wired for
      # Subscription only.
      loaded_on_archived = Ash.load!(price_on_archived, :plan, authorize?: false)
      assert loaded_on_archived.plan == nil

      # CONTROL: a live plan surfaces via the same path.
      loaded_on_live = Ash.load!(price_on_live, :plan, authorize?: false)
      assert %Plan{id: live_id} = loaded_on_live.plan
      assert live_id == live.id
    end
  end

  # ── §5.5 leak duty: aggregate — Subscription :exists on :plan ──────────────

  describe "§5.5 — an archived Plan does not leak via an :exists aggregate" do
    test "the :exists aggregate over Subscription.plan is false for an archived plan (RED); true for a live one (CONTROL)" do
      org = mk_org()
      customer = mk_customer(org)

      archived = mk_plan(org, "Archived")
      live = mk_plan(org, "Live")

      sub_on_archived = mk_subscription(org, customer.id, archived.id)
      sub_on_live = mk_subscription(org, customer.id, live.id)

      {:ok, _} = Samen.Archival.archive(archived, authorize?: false)

      # RED: the ad-hoc aggregate — a SEPARATE code path from relationship
      # loading, compiled to a correlated SQL subquery/EXISTS by AshPostgres —
      # also honors the default-read filter on the destination resource.
      archived_result =
        Subscription
        |> Ash.Query.filter(id == ^sub_on_archived.id)
        |> Ash.Query.aggregate(:plan_live?, :exists, :plan)
        |> Ash.read_one!(authorize?: false)

      refute archived_result.aggregates.plan_live?

      # CONTROL (anti-tautology): the identical aggregate over a subscription
      # pointing at a LIVE plan reports true — proves `false` above is the
      # archival filter firing, not the aggregate being vacuously false.
      live_result =
        Subscription
        |> Ash.Query.filter(id == ^sub_on_live.id)
        |> Ash.Query.aggregate(:plan_live?, :exists, :plan)
        |> Ash.read_one!(authorize?: false)

      assert live_result.aggregates.plan_live?
    end
  end

  # ── §5.4: no cascade — archiving Plan leaves its consumers live ────────────

  describe "§5.4 — billing declares no cascades: archiving Plan does not archive its consumers" do
    test "Price/Subscription/Entitlement of an archived Plan stay live (their own default reads still surface them)" do
      org = mk_org()
      customer = mk_customer(org)
      plan = mk_plan(org, "Cascade")
      price = mk_price(org, plan.id)
      sub = mk_subscription(org, customer.id, plan.id)
      ent = mk_entitlement(org, sub.id, plan.id)

      {:ok, _} = Samen.Archival.archive(plan, authorize?: false)

      # The plan itself is hidden (already proven above); its non-archivable
      # consumers are NOT touched — no `archive_related` cascade declared for
      # billing (§5.4), so they remain visible on their own default reads.
      assert MapSet.member?(live_price_ids(), price.id)
      assert Subscription |> Ash.read!(authorize?: false) |> Enum.any?(&(&1.id == sub.id))
      assert Entitlement |> Ash.read!(authorize?: false) |> Enum.any?(&(&1.id == ent.id))
    end
  end
end
