defmodule Samen.Web.OperatorAnalyticsRenderTest do
  @moduledoc """
  Framework OPERATOR / Product-analytics render tests (WS-B / B8; design §4.5,
  AC-G12-6).

  The surface reads REAL rows: `paf_product_event_rollup` RAW rows via the bounded
  cross-tenant SQL read in `Samen.Web.Operator.AnalyticsReads`, with the ENFORCED
  k-anonymity floor (`Samen.Aggregate.Privacy`, config default k=5 — this app sets
  no override, so the design's "k-anon min 5" is literally what runs) applied at
  the read before anything reaches the LiveView.

  The red-path is the B3 sentinel-refute pattern, non-tautological from birth:

    * **Render half** — a below-floor stage/cohort seeds DISTINCTIVE values;
      the test asserts `⊘` renders in that row AND refutes the sentinels ever
      reaching the HTML (a sabotaged cell that interpolates a `%Suppressed{}`
      field, or a floor that releases, turns it red).
    * **Flip half (anti-tautology)** — the SAME read with the floor sabotaged
      (`k: 1`, the `Samen.Aggregate.read_all/2` override seam) RELEASES the
      below-floor values: the sentinels demonstrably exist in the rollup and are
      withheld ONLY by the floor — the suppression assertions are load-bearing,
      not vacuous.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Aggregate.Suppressed
  alias Samen.Web.Operator.AnalyticsReads

  # Below-floor sentinels: DISTINCTIVE values that must never reach the HTML while
  # the floor stands. 41,927 actors across 4 orgs (< k=5) at first_record; the
  # retention sentinels are the suppressed cohort's would-be rates (75.0% / 25.0%),
  # chosen so no released row renders the same string.
  @funnel_sentinel_total 41_927
  @suppressed_cohort_week ~D[2026-06-01]
  @released_cohort_week ~D[2026-05-04]

  # -- fixtures -----------------------------------------------------------------

  defp insert_paf!(attrs) do
    Ecto.Adapters.SQL.query!(
      Samen.WebTest.Repo,
      """
      INSERT INTO paf_product_event_rollup
        (paf_org_id, paf_kind, paf_stage, paf_cohort_week, paf_week_offset, paf_actor_count)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [
        Ecto.UUID.dump!(attrs[:org_id] || Ash.UUID.generate()),
        attrs[:kind],
        attrs[:stage],
        attrs[:cohort_week],
        attrs[:week_offset],
        attrs[:actor_count]
      ]
    )
  end

  # The released funnel: signup reached by 6 orgs (>= k=5, 48 actors), first_run by
  # 5 orgs (25 actors), first_record by 4 orgs ONLY (< k=5) carrying the DISTINCTIVE
  # 41,927-actor sum — genuinely below-floor, its value must suppress.
  defp seed_funnel! do
    for _ <- 1..6, do: insert_paf!(kind: "funnel", stage: "signup", actor_count: 8)
    for _ <- 1..5, do: insert_paf!(kind: "funnel", stage: "first_run", actor_count: 5)

    for count <- [41_924, 1, 1, 1] do
      insert_paf!(kind: "funnel", stage: "first_record", actor_count: count)
    end

    :ok
  end

  # Two weekly cohorts, cross-tenant (two orgs contribute to the released one):
  #   released  (2026-05-04): size 6 (3+3 at W0) — W1 3/6 = 50.0%, W2 2/6 = 33.3%
  #   suppressed (2026-06-01): size 4 (< k=5)    — W1 3/4 = 75.0%, W2 1/4 = 25.0%
  # The suppressed cohort's rates are the render sentinels.
  defp seed_retention! do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    org_c = Ash.UUID.generate()

    rows = [
      {org_a, @released_cohort_week, 0, 3},
      {org_b, @released_cohort_week, 0, 3},
      {org_a, @released_cohort_week, 1, 2},
      {org_b, @released_cohort_week, 1, 1},
      {org_a, @released_cohort_week, 2, 2},
      {org_c, @suppressed_cohort_week, 0, 4},
      {org_c, @suppressed_cohort_week, 1, 3},
      {org_c, @suppressed_cohort_week, 2, 1}
    ]

    for {org_id, week, offset, count} <- rows do
      insert_paf!(
        org_id: org_id,
        kind: "retention",
        cohort_week: week,
        week_offset: offset,
        actor_count: count
      )
    end

    :ok
  end

  defp analytics_mount, do: build_operator_mount(Ash.UUID.generate())

  defp render_analytics do
    render_live(Samen.Web.Operator.AnalyticsLive, analytics_mount(), [])
  end

  # -- the funnel + retention reads, rendered ------------------------------------

  test "the activation funnel renders cross-tenant stage rows from the paf rollup (orgs-reached + actor sums)" do
    seed_funnel!()
    html = render_analytics()

    assert html =~ ~s(class="app")
    assert html =~ "Activation funnel"
    assert html =~ "funnel-row"

    # All three stages, funnel order, with the released cross-tenant sums.
    assert html =~ "funnel-signup"
    assert html =~ "Signed in"
    assert html =~ ">48<"
    assert html =~ "funnel-first_run"
    assert html =~ "First run completed"
    assert html =~ ">25<"
    assert html =~ "funnel-first_record"
    assert html =~ "First record created"
  end

  test "the 4-week retention grid renders weekly cohort rows with per-offset rates" do
    seed_retention!()
    html = render_analytics()

    assert html =~ "Retention · 4-week curve"
    assert html =~ "retention-row"
    assert html =~ "retention-#{@released_cohort_week}"

    # The released cohort (size 6 >= k=5): W0 100%, W1 50.0%, W2 33.3%.
    assert html =~ "100.0%"
    assert html =~ "50.0%"
    assert html =~ "33.3%"
  end

  test "zero data renders the kit empty states, never a crash or a raw table" do
    html = render_analytics()

    assert html =~ "funnel-empty"
    assert html =~ "No product events yet."
    assert html =~ "retention-empty"
    assert html =~ "No cohorts yet."
  end

  test "the analytics surface is not a PII surface: no vault token, no mask sentinel, all bounded numbers" do
    seed_funnel!()
    seed_retention!()
    html = render_analytics()

    refute html =~ "vt_"
    refute html =~ "••••"
  end

  # -- the k-anon suppression render contract (AC-G12-6, sentinel-refute) ---------

  test "a below-floor stage and cohort render ⊘ and their values NEVER reach the HTML; released rows render (positive control)" do
    seed_funnel!()
    seed_retention!()
    html = render_analytics()

    # Token-blind chrome.
    assert html =~ ~s(class="tb-bar")
    assert html =~ "k-anon suppressed"

    # Positive controls: the released stage/cohort values render.
    assert html =~ ">48<"
    assert html =~ "50.0%"
    assert html =~ "33.3%"

    # FUNNEL: the 4-org first_record stage renders ⊘ IN ITS OWN ROW, never a number.
    assert html =~ ~r/funnel-first_record.*⊘/s,
           "the first_record row itself must render the ⊘ glyph"

    assert html =~ "funnel stages below the k-anonymity floor"

    # RETENTION: the size-4 cohort renders ⊘ across its curve + the suppression note.
    assert html =~ ~r/retention-#{@suppressed_cohort_week}.*⊘/s,
           "the suppressed cohort row itself must render the ⊘ glyph"

    assert html =~ "cohorts below the k-anonymity floor"

    # NEGATIVE contract (the B3 sentinel-refute pattern — non-tautological from
    # birth): no below-floor value may reach the HTML. The sentinels are distinctive
    # (41,927 actors; the 75.0%/25.0% rates only the suppressed cohort would
    # produce), so a floor that releases OR a cell that interpolates any part of
    # the %Suppressed{} turns this red.
    refute html =~ "41927"
    refute html =~ "41,927"
    refute html =~ "75.0%"
    refute html =~ "25.0%"
  end

  test "RED-PATH (anti-tautology flip): sabotaging the floor (k: 1) RELEASES the below-floor values — the suppression above is the floor's doing" do
    seed_funnel!()
    seed_retention!()
    mount = analytics_mount()

    # The floored read (as the LiveView performs it): below-floor arrives Suppressed.
    %{funnel: funnel, retention: retention} = AnalyticsReads.analytics(mount)

    floored_stage = Enum.find(funnel, &(&1.stage == "first_record"))
    assert %Suppressed{reason: :k_anonymity, observed: 4} = floored_stage.actor_count

    floored_cohort = Enum.find(retention, &(&1.cohort_week == @suppressed_cohort_week))
    assert Suppressed.suppressed?(floored_cohort.weeks)
    # The released cohort is the positive control (not an always-⊘ read).
    released_cohort = Enum.find(retention, &(&1.cohort_week == @released_cohort_week))
    refute Suppressed.suppressed?(released_cohort.weeks)

    # SABOTAGE: the same read with the k-anon floor gutted (k: 1 admits any cohort —
    # the read_all/2 override seam). The exact below-floor values ARE released,
    # proving (a) they exist in the rollup (the suppression test is not vacuous) and
    # (b) a broken floor flips that test red — the AC-G12-6 sabotage contract.
    %{funnel: sab_funnel, retention: sab_retention} = AnalyticsReads.analytics(mount, k: 1)

    sabotaged_stage = Enum.find(sab_funnel, &(&1.stage == "first_record"))
    refute Suppressed.suppressed?(sabotaged_stage.actor_count)
    assert sabotaged_stage.actor_count == @funnel_sentinel_total

    sabotaged_cohort = Enum.find(sab_retention, &(&1.cohort_week == @suppressed_cohort_week))
    refute Suppressed.suppressed?(sabotaged_cohort.weeks)
    assert %{offset: 1, actors: 3, rate: rate_w1} = Enum.find(sabotaged_cohort.weeks, &(&1.offset == 1))
    assert_in_delta rate_w1, 0.75, 1.0e-9
  end
end
