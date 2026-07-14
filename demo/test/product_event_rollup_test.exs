defmodule Demo.ProductEventRollupTest do
  @moduledoc """
  WS-B / Phase B8 (ADR-021) — the `paf` funnel/retention rollup over the `pae`
  product-event ledger, on the B2 `:source :domain` machinery (AC-G12-6, rollup arm;
  the operator read surface is a separate unit).

  ## The reconciliation invariant (the R1 pattern applied to `pae`)

  The rollup is only trustworthy because it reconciles with the RAW ledger via an
  INDEPENDENT computation: each test tracks a fixture plan through the REAL
  `Samen.Analytics.track/1` capture boundary, computes the expected funnel stages +
  retention curve in Elixir (a different engine than the rollup's SQL), refreshes
  the `:domain` rollup, and asserts the `paf` rows match EXACTLY.

  RED PATH (anti-tautology): a mis-instrumented choke point (a `record.created`
  captured as `search.used` — the exact failure a wrong emitter call would produce)
  or a mis-timestamped event (shifted outside the 4-week curve) makes the rollup
  DIVERGE from the independent expectation → the reconciliation FAILS. We sabotage
  one raw `pae` row, re-refresh, show the SAME assertion now fails, then RESTORE the
  row byte-exact and show it reconciles again — the reconciliation is load-bearing,
  not a tautology that passes regardless of the ledger.

  ## The erasure stance (design §4.4 — `pae` has NO subject column)

  `pae_actor_ref` is a per-subject HMAC pseudonym, so the LOAD-BEARING erasure is
  B7's pseudonym-key destruction (AC-G12-5) — post-shred the rollup's counts stay
  honest k-anonymous aggregate (rows persist, linkage does not). The `:domain`
  spec's delete hook + oracle residue scan key `pae_actor_ref` against the RAW
  subject id and match ZERO rows by construction; that zero IS the invariant:
  a leaked raw id in `pae_actor_ref` (a sabotaged `track/1`) is deleted by the
  domain REBUILD arm and would be flagged by the DbContent residue scan. Proven
  live (not dead config) below.
  """
  use Demo.DataCase, async: false

  alias Demo.Analytics.ProductEvent
  alias Samen.{Analytics, Kms, Rollup, WideEvent}

  require Ash.Query

  # A Monday — a deterministic cohort-week anchor (date_trunc('week', ...) and
  # Date.beginning_of_week/1 both start weeks on Monday).
  @anchor ~U[2026-06-01 12:00:00Z]

  # event name => funnel stage label (the rollup's CASE mapping, restated
  # independently here so the test does not read the SQL it verifies).
  @funnel_stage %{
    "session.signed_in" => "signup",
    "first_run.completed" => "first_run",
    "record.created" => "first_record"
  }

  setup do
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  # ---- fixtures ---------------------------------------------------------------

  defp mk_subject do
    sid = Ash.UUID.generate()
    {:ok, _} = Kms.adapter().generate_subject_key(sid)
    sid
  end

  defp weeks_after(n), do: DateTime.add(@anchor, n * 7 * 86_400, :second)
  defp days_after(dt, n), do: DateTime.add(dt, n * 86_400, :second)

  # Track one event through the REAL capture boundary and return the plan entry the
  # independent expectation is computed from.
  defp track!(org_id, event, opts \\ []) do
    subject = Keyword.get(opts, :subject)
    at = Keyword.get(opts, :at, @anchor)

    {:ok, %ProductEvent{}} =
      Analytics.track(%{
        org_id: org_id,
        event_name: event,
        subject_id: subject,
        props: Keyword.get(opts, :props, %{}),
        occurred_at: at
      })

    %{org: org_id, event: event, subject: subject, at: at}
  end

  # ---- the INDEPENDENT expectations (Elixir, never the rollup's SQL) ----------

  # funnel: %{stage => distinct-actor count}; a stage KEY exists iff the org has
  # ≥1 such event (orgs-reached is row presence; actor_count may be 0 for
  # org-level events — COUNT(DISTINCT) skips NULL actor refs).
  defp expected_funnel(plan, org_id) do
    plan
    |> Enum.filter(&(&1.org == org_id and Map.has_key?(@funnel_stage, &1.event)))
    |> Enum.group_by(&Map.fetch!(@funnel_stage, &1.event))
    |> Map.new(fn {stage, events} ->
      distinct_actors =
        events |> Enum.map(& &1.subject) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

      {stage, distinct_actors}
    end)
  end

  # retention: %{{cohort_week, week_offset} => distinct-actor count}, offsets 0..4
  # only (the bounded curve), cohort = beginning-of-week of the actor's FIRST event.
  defp expected_retention(plan, org_id) do
    plan
    |> Enum.filter(&(&1.org == org_id and not is_nil(&1.subject)))
    |> Enum.group_by(& &1.subject)
    |> Enum.flat_map(fn {subject, evs} ->
      cohort =
        evs
        |> Enum.map(&DateTime.to_date(&1.at))
        |> Enum.min(Date)
        |> Date.beginning_of_week()

      evs
      |> Enum.map(fn ev ->
        div(Date.diff(Date.beginning_of_week(DateTime.to_date(ev.at)), cohort), 7)
      end)
      |> Enum.uniq()
      |> Enum.filter(&(&1 in 0..4))
      |> Enum.map(&{cohort, &1, subject})
    end)
    |> Enum.group_by(fn {cohort, offset, _s} -> {cohort, offset} end)
    |> Map.new(fn {key, hits} ->
      {key, hits |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length()}
    end)
  end

  # ---- read the rollup (what the operator read will consume — never raw pae) ---

  defp funnel_rows(org_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT paf_stage, paf_actor_count
        FROM paf_product_event_rollup
        WHERE paf_org_id = $1 AND paf_kind = 'funnel'
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    Map.new(rows, fn [stage, count] -> {stage, count} end)
  end

  defp retention_rows(org_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT paf_cohort_week, paf_week_offset, paf_actor_count
        FROM paf_product_event_rollup
        WHERE paf_org_id = $1 AND paf_kind = 'retention'
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    Map.new(rows, fn [week, offset, count] -> {{week, offset}, count} end)
  end

  # R1 over pae: the refreshed rollup matches the independently-computed
  # expectation EXACTLY (both arms).
  defp assert_reconciles(plan, org_id) do
    assert funnel_rows(org_id) == expected_funnel(plan, org_id)
    assert retention_rows(org_id) == expected_retention(plan, org_id)
  end

  defp pae_count(org_id) do
    ProductEvent
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  # ======================================================================
  # Spec registration — the B2 :source :domain machinery, reused
  # ======================================================================

  describe "the paf spec registers on the B2 :source :domain machinery" do
    test "product_event_rollup is :domain over pae and the worker refreshes it" do
      spec = Rollup.spec(:product_event_rollup)
      assert spec.source == :domain
      assert spec.table == "paf_product_event_rollup"
      # The erasure/oracle seam is declared on the pae ledger's pseudonym column —
      # the design-§4.4 stance (see the red-path + erasure tests below).
      assert spec.domain_table == "pae_product_event"
      assert spec.domain_subject_column == "pae_actor_ref"
      assert is_binary(spec.subject_delete_sql)

      {:ok, results} = Rollup.rebuild_all(Repo)
      assert Map.has_key?(results, :product_event_rollup),
             "the :domain paf rollup must be in the registry the RollupRefreshWorker rebuilds"
    end
  end

  # ======================================================================
  # GREEN — the rollup reconciles with the raw pae ledger (R1 over pae)
  # ======================================================================

  describe "R1 — the paf rollup reconciles with independently-computed pae counts" do
    test "funnel: signup→first-run→first-record distinct-actor counts per org" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      [s1, s2, s3, s4] = for _ <- 1..4, do: mk_subject()

      plan = [
        # org A: 3 actors signed in; org-level first-run; 1 actor created a record.
        track!(org_a, "session.signed_in", subject: s1),
        track!(org_a, "session.signed_in", subject: s2),
        track!(org_a, "session.signed_in", subject: s3),
        # A repeat sign-in must NOT inflate the distinct-actor count.
        track!(org_a, "session.signed_in", subject: s1, at: days_after(@anchor, 1)),
        track!(org_a, "first_run.completed"),
        track!(org_a, "record.created", subject: s1, props: %{"resource" => "crm.contact"}),
        # A non-funnel event must NOT materialize a funnel stage row.
        track!(org_a, "search.used", subject: s2, props: %{"surface" => "crm"}),
        # org B: one actor signed in, nothing else — no first_run/first_record rows.
        track!(org_b, "session.signed_in", subject: s4)
      ]

      {:ok, _} = Rollup.rebuild_all(Repo)

      assert_reconciles(plan, org_a)
      assert_reconciles(plan, org_b)

      # Spot-check the shape the read surface will consume (belt to the
      # independent-expectation braces): org A reached all three stages; the
      # org-level first_run row EXISTS with actor_count 0.
      a = funnel_rows(org_a)
      assert a == %{"signup" => 3, "first_run" => 0, "first_record" => 1}
      assert funnel_rows(org_b) == %{"signup" => 1}
    end

    test "retention: a 4-week curve of distinct actors, cohorted by first-seen week" do
      org = Ash.UUID.generate()
      [r1, r2, r3] = for _ <- 1..3, do: mk_subject()

      plan = [
        # r1: cohort week 0; active weeks 0 and 2; a week-6 event is BEYOND the
        # bounded curve and must not materialize an offset-6 row.
        track!(org, "session.signed_in", subject: r1, at: weeks_after(0)),
        track!(org, "search.used", subject: r1, at: days_after(weeks_after(0), 2), props: %{"surface" => "crm"}),
        track!(org, "record.created", subject: r1, at: weeks_after(2)),
        track!(org, "search.used", subject: r1, at: weeks_after(6), props: %{"surface" => "crm"}),
        # r2: cohort week 0, week 0 only.
        track!(org, "session.signed_in", subject: r2, at: weeks_after(0)),
        # r3: cohort week 1; active weeks 1 and 3 (offsets 0 and 2 of ITS cohort).
        track!(org, "session.signed_in", subject: r3, at: weeks_after(1)),
        track!(org, "search.used", subject: r3, at: weeks_after(3), props: %{"surface" => "support"})
      ]

      {:ok, _} = Rollup.rebuild_all(Repo)
      assert_reconciles(plan, org)

      # Spot-check (belt): two cohorts, offsets bounded to 0..4.
      w0 = Date.beginning_of_week(DateTime.to_date(weeks_after(0)))
      w1 = Date.beginning_of_week(DateTime.to_date(weeks_after(1)))

      assert retention_rows(org) == %{
               {w0, 0} => 2,
               {w0, 2} => 1,
               {w1, 0} => 1,
               {w1, 2} => 1
             }
    end
  end

  # ======================================================================
  # RED PATH — sabotage breaks the reconciliation; byte-exact restore heals it
  # ======================================================================

  describe "R1 RED PATH (anti-tautology) — a sabotaged pae row breaks the reconciliation" do
    test "funnel: a record.created mis-captured as search.used diverges → FAILS; restore → reconciles" do
      org = Ash.UUID.generate()
      s1 = mk_subject()

      plan = [
        track!(org, "session.signed_in", subject: s1),
        track!(org, "record.created", subject: s1, props: %{"resource" => "crm.contact"})
      ]

      # GREEN baseline.
      {:ok, _} = Rollup.rebuild_all(Repo)
      assert_reconciles(plan, org)

      # Capture the raw row so it can be restored BYTE-EXACT.
      %{rows: [[pae_id, correct_name]]} =
        Repo.query!(
          """
          SELECT pae_id, pae_event_name FROM pae_product_event
          WHERE pae_org_id = $1 AND pae_event_name = 'record.created'
          """,
          [Ecto.UUID.dump!(org)]
        )

      assert correct_name == "record.created"

      # SABOTAGE: a mis-instrumented choke point that captured the record-created
      # fact as a search event would have written exactly this row. The funnel's
      # first_record stage silently vanishes for the org.
      {:ok, _} =
        Repo.query(
          "UPDATE pae_product_event SET pae_event_name = 'search.used' WHERE pae_id = $1",
          [pae_id]
        )

      {:ok, _} = Rollup.rebuild_all(Repo)

      # The reconciliation is now BROKEN — the rollup diverges from the independent
      # expectation (first_record is gone from the rollup, present in the plan).
      refute funnel_rows(org) == expected_funnel(plan, org)

      assert_raise ExUnit.AssertionError, fn ->
        assert_reconciles(plan, org)
      end

      # RESTORE byte-exact; the reconciliation holds again.
      {:ok, _} =
        Repo.query(
          "UPDATE pae_product_event SET pae_event_name = $2 WHERE pae_id = $1",
          [pae_id, correct_name]
        )

      {:ok, _} = Rollup.rebuild_all(Repo)
      assert_reconciles(plan, org)
    end

    test "retention: an event shifted outside the 4-week curve diverges → FAILS; restore → reconciles" do
      org = Ash.UUID.generate()
      r1 = mk_subject()

      plan = [
        track!(org, "session.signed_in", subject: r1, at: weeks_after(0)),
        track!(org, "record.created", subject: r1, at: weeks_after(2))
      ]

      {:ok, _} = Rollup.rebuild_all(Repo)
      assert_reconciles(plan, org)

      %{rows: [[pae_id, correct_at]]} =
        Repo.query!(
          """
          SELECT pae_id, pae_occurred_at FROM pae_product_event
          WHERE pae_org_id = $1 AND pae_event_name = 'record.created'
          """,
          [Ecto.UUID.dump!(org)]
        )

      # SABOTAGE: a clock/timestamp bug lands the week-2 activity at week 7 —
      # outside the bounded curve, so the cohort's offset-2 row silently vanishes.
      {:ok, _} =
        Repo.query(
          "UPDATE pae_product_event SET pae_occurred_at = pae_occurred_at + interval '5 weeks' WHERE pae_id = $1",
          [pae_id]
        )

      {:ok, _} = Rollup.rebuild_all(Repo)

      refute retention_rows(org) == expected_retention(plan, org)

      assert_raise ExUnit.AssertionError, fn ->
        assert_reconciles(plan, org)
      end

      # RESTORE byte-exact (the captured timestamp, not an arithmetic inverse).
      {:ok, _} =
        Repo.query(
          "UPDATE pae_product_event SET pae_occurred_at = $2 WHERE pae_id = $1",
          [pae_id, correct_at]
        )

      {:ok, _} = Rollup.rebuild_all(Repo)
      assert_reconciles(plan, org)
    end
  end

  # ======================================================================
  # Erasure stance (design §4.4) — documented AND proven live
  # ======================================================================

  describe "erasure stance — pae has no subject column; the pseudonym key IS the erasure" do
    test "the domain arm matches ZERO rows for a raw subject id (token-blind by construction)" do
      org = Ash.UUID.generate()
      sid = mk_subject()

      plan = [
        track!(org, "session.signed_in", subject: sid),
        track!(org, "record.created", subject: sid)
      ]

      {:ok, _} = Rollup.rebuild_all(Repo)
      assert_reconciles(plan, org)
      assert pae_count(org) == 2

      # The erasure policy runs the paf domain arm: DELETE ... WHERE
      # pae_actor_ref::text = <raw sid> matches NOTHING — the raw id never reached
      # the ledger (pae_actor_ref is the HMAC pseudonym). rows_affected 0 is the
      # CORRECT arm result for this shape, not a skipped arm.
      report = Rollup.erase_subject(sid, Repo)
      entry = Enum.find(report, &(&1["rollup"] == "product_event_rollup"))
      assert entry["arm"] == "rebuild"
      assert entry["source"] == "domain"
      assert entry["rows_affected"] == 0

      # The pseudonymous rows PERSIST and the recomputed rollup still reconciles —
      # the aggregate stays honest k-anonymous history (design §4.4: rows survive,
      # linkage does not).
      assert pae_count(org) == 2
      assert_reconciles(plan, org)

      # The LOAD-BEARING erasure is B7's key destruction: post-shred the pseudonym
      # is unreconstructable, so actor_ref → subject re-identification is impossible
      # across live + mirror at once (AC-G12-5).
      {:ok, _} = Kms.adapter().shred(sid)
      assert {:error, :shredded} = WideEvent.for_subject(sid)
    end

    test "the seam is LIVE — a leaked raw subject id in pae_actor_ref is scanned and erased" do
      org = Ash.UUID.generate()
      sid = mk_subject()
      spec = Rollup.spec(:product_event_rollup)

      # A legitimate pseudonymous row that must SURVIVE the erasure untouched.
      track!(org, "session.signed_in", subject: sid)

      # SABOTAGE the capture boundary's guarantee: a broken track/1 that wrote the
      # RAW subject id into pae_actor_ref (the exact leak token-blindness forbids).
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO pae_product_event
            (pae_org_id, pae_actor_ref, pae_event_name, pae_props, pae_occurred_at,
             pae_inserted_at, pae_updated_at)
          VALUES ($1, $2, 'session.signed_in', '{}', now(), now(), now())
          """,
          [Ecto.UUID.dump!(org), sid]
        )

      # The DbContent oracle's INDEPENDENT residue scan (the spec's DECLARED
      # domain_table/domain_subject_column, not the delete hook) sees the leak —
      # post-shred this would be an oracle VIOLATION (B2-P1).
      residue_sql =
        "SELECT count(*) FROM #{spec.domain_table} WHERE #{spec.domain_subject_column}::text = $1"

      %{rows: [[1]]} = Repo.query!(residue_sql, [sid])

      # The domain REBUILD arm deletes EXACTLY the leaked row and recomputes.
      report = Rollup.erase_subject(sid, Repo)
      entry = Enum.find(report, &(&1["rollup"] == "product_event_rollup"))
      assert entry["rows_affected"] == 1

      # Residue gone; the legitimate pseudonymous row survives.
      %{rows: [[0]]} = Repo.query!(residue_sql, [sid])
      assert pae_count(org) == 1
    end
  end
end
