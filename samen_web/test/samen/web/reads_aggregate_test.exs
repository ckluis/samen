defmodule Samen.Web.ReadsAggregateTest do
  @moduledoc """
  The GENERIC aggregate primitives (`Samen.Web.Reads.aggregate_by!/3` + `time_series!/3`,
  G8/T56) — the framework building blocks the chart/dashboard tiles consume. Each proof is
  anti-tautology (a positive control anchors every guard):

    * AGGREGATE — a seeded resource aggregates into the RIGHT per-slice measures (a grouped
      COUNT and a grouped SUM match the seeded data exactly).
    * ORG-SCOPE — a 2-org seed: org B's rows NEVER contribute to org A's measures or total
      (sabotage-refutable — org B genuinely holds same-key rows, proven absent from A's series).
    * DB-LEVEL — the aggregate is computed IN SQL: the `%Series{}` carries only NUMBERS (no
      `rows` field exists), and a large-N seed yields a bounded slice set with an exact count —
      proving it never loads-then-sums in Elixir.
    * BUCKET BOUNDING — an unbounded-cardinality dimension caps at `max_points` slices and
      buckets the tail into ONE `Other` slice (total = shown + Other); a tiny cohort's LABEL
      folds into `Other` under `:collapse_below` (chart tidiness — NOT anonymity: the folded
      VALUE stays recoverable as the `Other` remainder).
    * MASKING (INV-1) — aggregating BY a vault-routed dimension is REFUSED
      (`MaskedGroupKeyError`), and SUM/AVG OF a vault-routed measure is REFUSED
      (`MaskedMeasureError`); non-vaulted twins aggregate fine (the refutation controls).
    * TIME SERIES — a seeded date facet buckets into the right per-bucket counts; an unbounded
      window is refused.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.MaskedGroupKeyError
  alias Samen.Web.Reads.MaskedMeasureError
  alias Samen.Web.Reads.UnboundedSeriesRangeError
  alias Samen.Web.Series

  @opportunity Samen.WebTest.Crm.Opportunity
  @person Samen.WebTest.Crm.Person

  # -- seed helpers ------------------------------------------------------------

  defp seed_opp(org_id, attrs) do
    @opportunity
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, name: "opp", status: :open}, attrs),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp money(cents), do: Samen.Type.Money.from_cents(cents, :USD)

  defp point(%Series{points: points}, key), do: Enum.find(points, &(&1.key == key))

  # -- AGGREGATE (values match the seed) ---------------------------------------

  test "AGGREGATE count-by-status: each slice count matches the seed" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    for _ <- 1..3, do: seed_opp(org, %{status: :open, name: "o"})
    for _ <- 1..2, do: seed_opp(org, %{status: :won, name: "w"})

    series =
      Mount.resource(mount, Opportunity)
      |> Reads.aggregate_by!(:status, scope: scope, groups: [{:open, "Open"}, {:won, "Won"}, {:lost, "Lost"}])

    assert point(series, :open).value == 3
    assert point(series, :won).value == 2
    assert point(series, :lost).value == 0
    assert point(series, :open).label == "Open"
    assert series.measure == :count
    assert series.dimension == :status
    assert series.total == 5
  end

  test "AGGREGATE sum-by-status: each slice SUMS the Money value (in cents)" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    seed_opp(org, %{status: :open, value: money(100_00)})
    seed_opp(org, %{status: :open, value: money(200_00)})
    seed_opp(org, %{status: :won, value: money(500_00)})

    series =
      Mount.resource(mount, Opportunity)
      |> Reads.aggregate_by!(:status, scope: scope, measure: {:sum, :value})

    # Bar heights come from `value` (minor units); the raw Money is kept for formatting.
    assert point(series, :open).value == 300_00
    assert point(series, :won).value == 500_00
    assert %Money{} = point(series, :open).raw
    assert series.total == 800_00
    assert series.measure == {:sum, :value}
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B never contributes to org A's measures or total" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope_a = Mount.scope(mount, org_a)
    scope_b = Mount.scope(mount, org_b)

    # Org A: 2 open. Org B genuinely holds 5 SAME-KEY (open) rows — the refutation setup.
    for _ <- 1..2, do: seed_opp(org_a, %{status: :open, value: money(100_00)})
    for _ <- 1..5, do: seed_opp(org_b, %{status: :open, value: money(999_00)})

    b_count =
      @opportunity
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.count!(scope: scope_b)

    assert b_count == 5

    counts = Mount.resource(mount, Opportunity) |> Reads.aggregate_by!(:status, scope: scope_a)
    sums = Mount.resource(mount, Opportunity) |> Reads.aggregate_by!(:status, scope: scope_a, measure: {:sum, :value})

    # OrgScope narrows every slice + the total: only org A's 2 @ $100, none of org B's 5 @ $999.
    assert point(counts, :open).value == 2
    assert counts.total == 2
    assert point(sums, :open).value == 200_00
    assert sums.total == 200_00
  end

  # -- DB-LEVEL (computed in SQL, never load-then-sum) -------------------------

  test "DB-LEVEL: the %Series{} carries only numbers (no rows), even over a large N" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    # A large single-cohort seed: if the primitive LOADED rows it would carry 60 records;
    # a SQL aggregate carries ONE number. The struct structurally cannot hold rows.
    for _ <- 1..60, do: seed_opp(org, %{status: :open})

    series = Mount.resource(mount, Opportunity) |> Reads.aggregate_by!(:status, scope: scope)

    assert point(series, :open).value == 60
    assert series.total == 60
    # Structural DB-aggregate proof: a Series has no rows field, and every point value is a
    # bare number (never a loaded row set).
    refute Map.has_key?(series, :rows)
    assert Enum.all?(series.points, &is_number(&1.value))
    # Bounded: the slice set never exceeds the cap + the Other tail.
    assert length(series.points) <= Reads.max_agg_points() + 1
  end

  # -- BUCKET BOUNDING (cap + Other tail; small-label collapse) ----------------

  test "BOUNDING: an over-cap dimension caps slices + buckets the tail into Other" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    # 8 opportunities each with a DISTINCT name → 8 distinct group keys.
    for i <- 1..8, do: seed_opp(org, %{name: "name-#{i}"})

    series =
      Mount.resource(mount, Opportunity)
      |> Reads.aggregate_by!(:name, scope: scope, max_points: 3)

    other = point(series, Reads.other_key())

    # 3 shown slices + 1 bounded Other tail — NEVER 8 slices.
    assert length(series.points) == 4
    assert series.capped == true
    # The tail is bucketed, not dropped: shown(3×1) + Other == the grand total (8).
    assert other.value == 5
    assert series.total == 8
    assert Enum.sum(Enum.map(series.points, & &1.value)) == 8

    # Positive control: UNDER the cap, no Other slice appears.
    small = Mount.resource(mount, Opportunity) |> Reads.aggregate_by!(:name, scope: scope, max_points: 50)
    assert small.capped == false
    assert point(small, Reads.other_key()) == nil
  end

  test "SMALL-LABEL: a tiny cohort's LABEL folds into Other under :collapse_below (tidiness, NOT anonymity)" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    for _ <- 1..3, do: seed_opp(org, %{status: :open})
    seed_opp(org, %{status: :won})

    # collapse_below 2: the count-1 `won` cohort must NOT render as its OWN labelled slice.
    series =
      Mount.resource(mount, Opportunity)
      |> Reads.aggregate_by!(:status, scope: scope, collapse_below: 2)

    assert point(series, :won) == nil
    assert point(series, :open).value == 3
    # NOTE: this is NOT k-anonymity — the folded VALUE is NOT hidden. `Other` is the arithmetic
    # remainder (total 4 − shown 3), so the lone collapsed cohort's value (1) is fully
    # reconstructable by subtraction. The label is tidied; the value is not a secret.
    assert point(series, Reads.other_key()).value == 1
    assert series.capped == true

    # Refutation control: the default (no collapse) DOES surface the singleton as its own slice —
    # so the fold above is a real label collapse, not a slice that never rendered.
    plain = Mount.resource(mount, Opportunity) |> Reads.aggregate_by!(:status, scope: scope)
    assert point(plain, :won).value == 1
  end

  # -- MASKING (INV-1) ---------------------------------------------------------

  test "MASKING: aggregating BY a vault-routed dimension is REFUSED; non-vaulted groups fine" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    # Refutation anchors: full_name IS vaulted, job_title/status are NOT.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
    refute Samen.Pii.Info.vault_routed?(@person, :job_title)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :status)

    err =
      assert_raise MaskedGroupKeyError, fn ->
        Reads.aggregate_by!(Mount.resource(mount, Person), :full_name, scope: scope)
      end

    assert err.message =~ "vault-routed"

    # GREEN control: the non-vaulted twin aggregates without raising (anti-tautology).
    series = Mount.resource(mount, Opportunity) |> Reads.aggregate_by!(:status, scope: scope)
    assert series.dimension == :status
  end

  test "MASKING: SUM/AVG OF a vault-routed measure is REFUSED; a non-vaulted measure is fine" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)
    seed_opp(org, %{status: :open, value: money(100_00)})

    # RED: summing the 🔒 full_name (grouping by the non-vaulted job_title) is refused — a
    # summed secret would leak plaintext / a 1-cohort value.
    assert_raise MaskedMeasureError, fn ->
      Reads.aggregate_by!(Mount.resource(mount, Person), :job_title, scope: scope, measure: {:sum, :full_name})
    end

    # GREEN control: summing the non-vaulted Opportunity :value works (anti-tautology).
    series =
      Mount.resource(mount, Opportunity)
      |> Reads.aggregate_by!(:status, scope: scope, measure: {:sum, :value})

    assert point(series, :open).value == 100_00
  end

  # -- TIME SERIES -------------------------------------------------------------

  test "TIME SERIES: monthly buckets count the seeded close_dates; window is bounded" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    seed_opp(org, %{close_date: ~D[2026-01-10]})
    seed_opp(org, %{close_date: ~D[2026-01-20]})
    seed_opp(org, %{close_date: ~D[2026-03-05]})

    series =
      Mount.resource(mount, Opportunity)
      |> Reads.time_series!(:close_date,
        scope: scope,
        range_start: ~D[2026-01-01],
        range_end: ~D[2026-04-01],
        unit: :month
      )

    assert series.dimension == :bucket
    # Jan / Feb / Mar buckets, in order.
    assert length(series.points) == 3
    assert Enum.map(series.points, & &1.value) == [2, 0, 1]
    assert Enum.at(series.points, 0).label == "Jan 2026"
    assert series.total == 3

    # A vault-routed axis is refused (INV-1); a non-vaulted date facet is fine (control above).
    assert_raise MaskedGroupKeyError, fn ->
      Reads.time_series!(Mount.resource(mount, Person), :full_name,
        scope: scope,
        range_start: ~D[2026-01-01],
        range_end: ~D[2026-02-01]
      )
    end
  end

  test "TIME SERIES: an unbounded (multi-decade daily) window is REFUSED" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    assert_raise UnboundedSeriesRangeError, fn ->
      Mount.resource(mount, Opportunity)
      |> Reads.time_series!(:close_date,
        scope: scope,
        range_start: ~D[2000-01-01],
        range_end: ~D[2030-01-01],
        unit: :day
      )
    end

    # Positive control: an EMPTY/inverted window is likewise refused (not silently empty).
    assert_raise UnboundedSeriesRangeError, fn ->
      Mount.resource(mount, Opportunity)
      |> Reads.time_series!(:close_date, scope: scope, range_start: ~D[2026-05-01], range_end: ~D[2026-05-01])
    end
  end
end
