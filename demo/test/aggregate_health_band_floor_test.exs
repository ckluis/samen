defmodule Demo.AggregateHealthBandFloorTest do
  @moduledoc """
  WS-B B4 — AC-G17-6: the cross-tenant **health-band distribution** floor, end-to-end
  on the demo against a real Postgres DB (design §2.3 LOAD-BEARING; ADR-019 §5;
  build-plan B4 task 4).

  Per-tenant health of the operator's OWN book is a TENANT-plane read (clear — the
  SaaS owns it). CROSS-tenant health ("how many accounts are at-risk across the
  fleet") is aggregate-ONLY: it routes through `Demo.Aggregate.HealthByBand` +
  `operator_aggregate` + `aggregate_cohort_spec/0`, and every cell passes the k-anon
  floor. A band with fewer than `k` accounts renders `%Suppressed{}`.

  THE RED-PATH PROBE (design §2.3 / ADR-019 §5, VERBATIM): seed 4 at-risk accounts →
  the `at_risk` band cohort has count 4 → `%Suppressed{}`; add a 5th → count 5 (>= k)
  → the count APPEARS. This proves the cross-tenant health surface NEVER bypasses the
  k-anon floor, and is not an always-suppress (the 5th releasing is the anti-tautology
  positive control).

  This suite runs the DEMO floor config (`k=2`); the probe below drives an EXPLICIT
  `k: 5` through the read to exercise the production floor the AC names (min_cohort =
  5) without depending on which env config is loaded.
  """
  use Demo.DataCase, async: false

  alias Demo.Aggregate.HealthByBand
  alias Samen.Aggregate.Suppressed

  # The production k-anon floor the AC names (design §2.3: min_cohort = 5). We pass it
  # explicitly to `read_all/2` so the probe is env-independent (the demo default is
  # k=2 for its small dogfood datasets).
  @k 5

  # --- seeding helpers -------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_plan(org_id, name) do
    {:ok, plan} =
      Demo.BillingScope.Plan
      |> Ash.Changeset.for_create(:create, %{name: name, org_id: org_id})
      |> Ash.create(authorize?: false)

    plan
  end

  defp mk_customer(org_id) do
    {:ok, cust} =
      Demo.BillingScope.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        billing_name: "Bill Payer",
        billing_email: "billing@example.com"
      })
      |> Ash.create(authorize?: false)

    cust
  end

  defp mk_subscription(org_id, customer_id, plan_id, status) do
    {:ok, sub} =
      Demo.BillingScope.Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: customer_id,
        plan_id: plan_id,
        status: status
      })
      |> Ash.create(authorize?: false)

    sub
  end

  # One tenant org whose worst health band is `band`, built from the dunning-dominant
  # billing signal the score derives from:
  #   :at_risk  → a :past_due subscription (in dunning)
  #   :healthy  → an :active subscription, no past-due
  #   :critical → a :cancelled subscription
  defp account_with_band!(band) do
    status =
      case band do
        :at_risk -> :past_due
        :healthy -> :active
        :critical -> :cancelled
      end

    org = mk_org("Acct-#{band}-#{System.unique_integer([:positive])}")
    plan = mk_plan(org.id, "Pro")
    cust = mk_customer(org.id)
    mk_subscription(org.id, cust.id, plan.id, status)
    org
  end

  defp band_counts do
    {:ok, rows} = Samen.Aggregate.read_all(HealthByBand, k: @k)
    Map.new(rows, &{&1.band, &1})
  end

  # ==========================================================================
  # AC-G17-6 — THE RED-PATH PROBE (design §2.3 / ADR-019 §5, VERBATIM)
  # ==========================================================================

  test "RED (k-anon on health band): 4 at-risk accounts SUPPRESS; a 5th makes the count APPEAR" do
    # A `healthy` cohort well above the floor keeps the read non-vacuous and gives the
    # probe a released positive control that is stable across both phases.
    for _ <- 1..6, do: account_with_band!(:healthy)

    # PHASE 1 — seed exactly 4 at-risk accounts. The at-risk band cohort = 4 < k=5.
    for _ <- 1..4, do: account_with_band!(:at_risk)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    by_band = band_counts()

    # at_risk (count 4 < k) → SUPPRESSED. The operator NEVER reads "there are 4
    # at-risk accounts across the fleet" — the count-under-floor never egresses.
    assert %Suppressed{reason: :k_anonymity, observed: 4} = by_band["at_risk"].account_count

    # healthy (count 6 >= k) → released the WHOLE time (anti-tautology positive
    # control: this is not an always-suppress).
    refute Suppressed.suppressed?(by_band["healthy"].account_count)
    assert by_band["healthy"].account_count == 6

    # PHASE 2 — a 5th at-risk account. The cohort crosses the floor (5 >= k=5).
    account_with_band!(:at_risk)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    by_band = band_counts()

    # at_risk (count 5 >= k) → the count now APPEARS. This is the "5th → count appears"
    # endpoint the AC names verbatim.
    refute Suppressed.suppressed?(by_band["at_risk"].account_count)
    assert by_band["at_risk"].account_count == 5

    # healthy still released, unchanged (the floor fired on band membership size, not
    # on the read as a whole).
    assert by_band["healthy"].account_count == 6
  end

  # ==========================================================================
  # ANTI-TAUTOLOGY (in-test, non-vacuity): the SAME read both suppresses and releases
  # depending ONLY on band-cohort size — a critical band under the floor suppresses
  # while a healthy band above it releases, in ONE read.
  # ==========================================================================

  test "anti-tautology: one read RELEASES a >=k healthy band and SUPPRESSES a <k critical band" do
    for _ <- 1..5, do: account_with_band!(:healthy)
    for _ <- 1..2, do: account_with_band!(:critical)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    by_band = band_counts()

    refute Suppressed.suppressed?(by_band["healthy"].account_count)
    assert by_band["healthy"].account_count == 5

    assert %Suppressed{reason: :k_anonymity, observed: 2} = by_band["critical"].account_count
  end

  # ==========================================================================
  # BYPASS-IMPOSSIBLE-VIA-DOMAIN: the health-band cross-tenant surface rides the same
  # read chokepoint as MRR/queue — suppression is not optional here either.
  # ==========================================================================

  test "the health-band projection routes reads through the suppression module — a <k band never egresses its count" do
    for _ <- 1..3, do: account_with_band!(:at_risk)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    {:ok, rows} = Samen.Aggregate.read_all(HealthByBand, k: @k)
    at_risk = Enum.find(rows, &(&1.band == "at_risk"))

    assert %Suppressed{} = at_risk.account_count
    # The withheld count (3) is structurally NOT in the returned struct — no
    # serialization path can leak it.
    refute match?(3, at_risk.account_count)
  end
end
