defmodule Samen.Web.OperatorRevenueRenderTest do
  @moduledoc """
  Framework OPERATOR / Revenue render tests (WS-B / B3; design §1.4 + §1.6).

  The own-book half (waterfall / NRR + churn tiles / cohort grid) reads REAL rows:
  `mov` ledger rows via the OrgScope'd bounded Ash read and `mrr_revenue_rollup` RAW
  rows via the bounded SQL read — both wrapped through the `Samen.Revenue.Metrics`
  kernel fold by `Samen.Web.Operator.RevenueReads` (the surface never recomputes;
  the numbers asserted here are the kernel's, rendered).

  The cross-tenant half (MRR by plan) proves the RENDER contract of the token-blind
  path (AC-G7-9): a `%Samen.Aggregate.Suppressed{}` cohort — what the k-anon floor
  at the `Samen.Aggregate.read_all/2` chokepoint hands the loader for a below-floor
  plan — renders `⊘` and its underlying value NEVER reaches the HTML; a released
  cohort renders its value (positive control). The floor MECHANISM red-path (seed
  below-floor → suppressed; sabotage the floor → released) runs against the real
  aggregate plane in the demo suite (`Demo.OperatorRevenuePlanFloorTest`).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Operator, as: Op

  # -- fixtures -----------------------------------------------------------------

  # Seed the mov ledger lifecycle + the matching rollup rows for ONE operator org:
  #   2026-01: C1 :new +$100.00, C2 :new +$50.00   → closing $150.00
  #   2026-02: C1 :expansion +$50.00               → closing $200.00
  #   2026-03: C2 :churn −$50.00                   → closing $150.00
  defp seed_revenue! do
    org_id = Ash.UUID.generate()
    c1 = Ash.UUID.generate()
    c2 = Ash.UUID.generate()

    movements = [
      {c1, :new, 10_000, 0, 10_000, ~U[2026-01-10 12:00:00Z]},
      {c2, :new, 5_000, 0, 5_000, ~U[2026-01-20 12:00:00Z]},
      {c1, :expansion, 5_000, 10_000, 15_000, ~U[2026-02-08 12:00:00Z]},
      {c2, :churn, -5_000, 5_000, 0, ~U[2026-03-15 12:00:00Z]}
    ]

    for {customer_id, kind, delta, before_c, after_c, at} <- movements do
      Op.SubscriptionEvent
      |> Ash.Changeset.for_create(
        :append,
        %{
          org_id: org_id,
          subscription_id: Ash.UUID.generate(),
          customer_id: customer_id,
          kind: kind,
          mrr_delta_cents: delta,
          mrr_before_cents: before_c,
          mrr_after_cents: after_c,
          occurred_at: at
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    rollup = [
      {~D[2026-01-01], "new", 15_000, 2},
      {~D[2026-02-01], "expansion", 5_000, 1},
      {~D[2026-03-01], "churn", -5_000, 1}
    ]

    for {month, kind, delta, count} <- rollup do
      Ecto.Adapters.SQL.query!(
        Samen.WebTest.Repo,
        """
        INSERT INTO mrr_revenue_rollup
          (mrr_org_id, mrr_period_month, mrr_kind, mrr_delta_cents, mrr_count)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [Ecto.UUID.dump!(org_id), month, kind, delta, count]
      )
    end

    org_id
  end

  # A host revenue_plan_loader as the token-blind aggregate path would hand it over:
  # the floors ran at the read_all/2 chokepoint; the below-floor "bespoke" cohort
  # arrives ALREADY %Suppressed{} — the loader (and the framework) never see its value.
  def sample_plan_cohorts do
    [
      %{plan: "growth", tenant_count: 6, mrr_cents: 300_000},
      %{
        plan: "bespoke",
        tenant_count: 4,
        # observed is a DISTINCTIVE sentinel (still < k, so genuinely below-floor):
        # the render test refutes it ever reaching the HTML — a money_cell that
        # renders any part of a %Suppressed{} turns the test red (B3 gate P2 fix).
        mrr_cents: %Samen.Aggregate.Suppressed{reason: :k_anonymity, k: 99_991, observed: 41_927}
      }
    ]
  end

  defp revenue_mount(org_id, labels \\ %{}), do: build_operator_mount(org_id, labels: labels)

  # -- own book: waterfall / tiles / cohort grid ---------------------------------

  test "the waterfall renders per-period rows from the rollup, chained opening→closing (kernel fold, R1 shape)" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    assert html =~ ~s(class="app")
    assert html =~ "MRR movement waterfall"
    assert html =~ "waterfall-row"

    # 2026-01: opening $0 → new $150 → closing $150; 2026-02 opens at the prior
    # closing (the chain) → closing $200; 2026-03 churns $50 → closing $150.
    assert html =~ "2026-01"
    assert html =~ "2026-02"
    assert html =~ "2026-03"
    assert html =~ "$150.00"
    assert html =~ "$200.00"
  end

  test "the NRR / churn tiles render the kernel metrics for the latest period" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    # Latest period (2026-03): opening $200, churn $50 →
    # NRR (200−50)/200 = 75.0%; gross churn 50/200 = 25.0%;
    # logo churn: opening_logos 2 (two :new, zero prior churn), churn_logos 1 → 50.0%.
    assert html =~ "NRR"
    assert html =~ "75.0%"
    assert html =~ "Gross churn"
    assert html =~ "25.0%"
    assert html =~ "Logo churn"
    assert html =~ "50.0%"
    # The MRR tile is the latest closing.
    assert html =~ "MRR"
  end

  test "the cohort retention grid renders from the mov timeline (customer-keyed kernel fold)" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    # One cohort (2026-01, both customers), retained 100% M0/M1, 50% at M2 (C2 churned).
    assert html =~ "Cohort retention"
    assert html =~ "cohort-row"
    assert html =~ "100.0%"
    assert html =~ "50.0%"
  end

  test "the revenue surface is not a PII surface: no vault token, no mask sentinel, all bounded numbers" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    refute html =~ "vt_"
    refute html =~ "••••"
  end

  test "zero data renders the kit empty states, never a crash or a raw table" do
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(Ash.UUID.generate()), [])

    assert html =~ "revenue-empty"
    assert html =~ "cohorts-empty"
    assert html =~ "No revenue movements yet."
  end

  # -- cross-tenant: the k-anon suppression render contract (AC-G7-9) -------------

  test "a below-floor plan cohort renders ⊘ and its value NEVER reaches the HTML; a released cohort renders (positive control)" do
    org_id = seed_revenue!()

    html =
      render_live(
        Samen.Web.Operator.RevenueLive,
        revenue_mount(org_id, %{revenue_plan_loader: {__MODULE__, :sample_plan_cohorts, []}}),
        []
      )

    # Token-blind chrome.
    assert html =~ "MRR by plan"
    assert html =~ ~s(class="tb-bar")
    assert html =~ "k-anon suppressed"

    # Positive control: the released cohort renders its value.
    assert html =~ "growth"
    assert html =~ "$3000.00"

    # The below-floor cohort renders ⊘ IN ITS OWN ROW (never a number) + the
    # suppression note. The VALUE-level proof (the exact below-floor MRR exists in
    # the DB, is withheld by the floor, and a sabotaged floor releases it) is the
    # demo red-path against the real aggregate plane: `Demo.OperatorRevenuePlanFloorTest`.
    assert html =~ "bespoke"
    assert html =~ ~r/bespoke.*⊘/s, "the bespoke row itself must render the ⊘ glyph"
    assert html =~ "below the k-anonymity floor"

    # NEGATIVE contract (B3 gate P2 fix — makes this test non-tautological): no
    # fragment of the %Suppressed{} struct may reach the HTML. The observed/k
    # sentinels are distinctive, so any cell that renders them (e.g. a sabotaged
    # money_cell interpolating `observed`) turns this red.
    refute html =~ "41927"
    refute html =~ "41,927"
    refute html =~ "99991"
    refute html =~ "99,991"
  end

  test "without a revenue_plan_loader the cross-tenant section renders the wiring empty state" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    assert html =~ "plan-mrr-empty"
    assert html =~ "No cross-tenant plan projection wired."
  end
end
