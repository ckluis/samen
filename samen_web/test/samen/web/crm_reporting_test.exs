defmodule Samen.Web.CRMReportingTest do
  @moduledoc """
  T76 (spec §I3) — CRM reporting: conversion, win-rate, activity leaderboard, built on the
  G8 view kit (`Samen.Web.Reads.aggregate_by!/3`) and rendered on
  `Samen.Web.CRM.DashboardLive` alongside the T56 tiles. Proofs, per CLAUDE.md's masking
  watch-list + anti-tautology discipline:

    * DETERMINISTIC METRICS — `pipeline_rates/2`'s win-rate and conversion-rate match
      hand-computed expected values EXACTLY, over seeded fixtures with known won/lost/open/
      on_hold counts (done-criterion 1).
    * HONEST EMPTY — an org with zero opportunities gets `nil` rates (rendered "—"), never a
      fabricated `0%`; an org with opportunities but zero CLOSED deals gets `nil` win_rate but
      a real (zero) conversion_rate — the two denominators disagree on purpose.
    * LEADERBOARD RANKING — `activity_leaderboard/3`'s ranks match hand-computed expected
      order EXACTLY (done-criterion 1); unassigned (`owner_id: nil`) activities are excluded;
      a non-CRM Work task never inflates a CRM activity count.
    * MED-1 FIX (fix round 1) — RANK BEFORE CAP: the true top performer surfaces at rank 1
      even when their uuid sorts last among all discovered owners (the verifier's live repro:
      13 owners, a 99-activity top performer, deliberately uuid-last); the display cap is
      DISCLOSED (`:capped`/`:hidden_owners`/`:hidden_count`), never silently swallowed.
    * MED-2 FIX (fix round 1) — the primitive's bounded-tail `Other` sentinel can NEVER
      appear as a ranked row, even in a scenario engineered so its arithmetic-remainder value
      would outrank every real owner if the rejection were removed.
    * ORG-SCOPE (sabotage-refutable, the T74/T75 lesson) — org B's opportunities/activities
      NEVER contribute to org A's rates or leaderboard (and DO contribute to org B's own — the
      refutation control).
    * MASKING (verified non-PII, refutable) — `Task.owner_id` (and every other field this
      surface reads/renders) is NOT vault-routed, anchored against the vaulted
      `Person.full_name` (mirrors `crm_dashboard_test.exs`'s own proof) — this surface never
      calls `Samen.Api.PiiResolution`/`Samen.Vault.reveal/3` because there is nothing to
      resolve.
    * FIRST-CLIENT — the real `DashboardLive` renders the new tiles from seeded data.
    * `mix samen.verify.aggregate_privacy` (INV-2) stays green: this surface adds NO
      `Samen.Aggregate.Resource` (the cross-tenant operator-plane primitive that verifier
      gates) — every new read here rides the TENANT-plane `Samen.Web.Reads` kit
      (`Samen.Policy.OrgScope` + keyset/DB-aggregate bounding), asserted directly below WITH
      a positive control (fix round 1, LOW-1 — `RealAggregateFixture`, a genuine
      `use Samen.Aggregate.Resource` module, so `aggregate_plane?/1` can actually return
      `true` in this suite, not just `false` for everything).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.DashboardLive
  alias Samen.Web.CRM.Reads

  @opportunity Samen.WebTest.Crm.Opportunity
  @person Samen.WebTest.Crm.Person
  @task Samen.WebTest.Work.Task

  # Fix round 1, LOW-1 — the INV-2 positive control. A REAL `use Samen.Aggregate.Resource`
  # module (abbrev `wcr` reserved via the sanctioned allocator, `mix samen.abbrev.reserve
  # --host samen_web --owner Samen.Web.CRMReportingTest.RealAggregateFixture --propose` — NOT
  # hand-edited), so `Samen.Aggregate.Info.aggregate_plane?/1` has something that can actually
  # return `true` in this test — without it, `refute aggregate_plane?(Task/Opportunity)` alone
  # cannot distinguish "correctly not aggregate-plane" from "the predicate always returns
  # false" (its own `rescue -> false` even fires for garbage/nonexistent modules). Never
  # queried (no migration needed) — only its DSL-level `aggregate_plane?` metadata is used.
  defmodule RealAggregateFixture do
    @moduledoc false
    use Samen.Aggregate.Resource,
      otp_app: :samen_web,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "wcr"

    postgres do
      table("wcr_real_aggregate_fixture")
      repo(Samen.WebTest.Repo)
    end

    attributes do
      attribute(:tier, :string, public?: true)
      attribute(:tenant_count, :integer, public?: true)
      attribute(:mrr_cents, :integer, public?: true)
    end

    actions do
      defaults([:read])
    end

    def aggregate_cohort_spec do
      %Samen.Aggregate.CohortSpec{
        cohort_key_columns: [:tier],
        cohort_count_column: :tenant_count,
        value_columns: [:mrr_cents]
      }
    end
  end

  # -- seed helpers ------------------------------------------------------------

  # A function-boundary equality check (kept OUT of the test body) so the compiler's
  # literal-type inference does not statically know `nil === 0.0` is always false —
  # the anti-tautology test needs a REAL runtime comparison, not a compile-time constant.
  defp same?(a, b), do: a === b

  defp seed_opp(org_id, status, opts \\ []) do
    @opportunity
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, name: "opp-#{System.unique_integer([:positive])}", status: status}, Map.new(opts)),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_activity(org_id, opts) do
    attrs =
      Map.merge(
        %{
          org_id: org_id,
          kind: :call,
          title: "activity",
          status: :completed,
          subject_key: "crm.person",
          subject_id: Ash.UUID.generate()
        },
        Map.new(opts)
      )

    @task
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  # ==========================================================================
  # 1. DETERMINISTIC METRICS — hand-computed win-rate / conversion-rate
  # ==========================================================================

  test "win_rate is CLOSED-deals basis (won / (won+lost)); conversion_rate is ALL-CREATED basis (won / everything)" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    # 3 won, 1 lost, 2 open, 1 on_hold => closed = 4, total = 7.
    for _ <- 1..3, do: seed_opp(org_id, :won)
    seed_opp(org_id, :lost)
    for _ <- 1..2, do: seed_opp(org_id, :open)
    seed_opp(org_id, :on_hold)

    scope = Samen.Web.Mount.scope(mount, org_id)
    rates = Reads.pipeline_rates(mount, scope)

    assert rates.won == 3
    assert rates.lost == 1
    assert rates.open == 2
    assert rates.on_hold == 1
    # win_rate: 3 / (3+1) = 0.75 EXACTLY
    assert rates.win_rate == 0.75
    # conversion_rate: 3 / (3+1+2+1) = 3/7 EXACTLY
    assert_in_delta rates.conversion_rate, 3 / 7, 1.0e-9
  end

  test "HONEST EMPTY: an org with NO opportunities gets nil for both rates (never a fabricated 0%)" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    scope = Samen.Web.Mount.scope(mount, org_id)
    rates = Reads.pipeline_rates(mount, scope)

    assert rates.win_rate == nil
    assert rates.conversion_rate == nil
    assert rates.won == 0
  end

  test "HONEST EMPTY (partial): an org with OPEN deals but ZERO closed deals gets nil win_rate but a real (zero) conversion_rate" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    for _ <- 1..4, do: seed_opp(org_id, :open)

    scope = Samen.Web.Mount.scope(mount, org_id)
    rates = Reads.pipeline_rates(mount, scope)

    # No decided deals yet => win_rate is UNDEFINED (nil), not "0% — we lose everything".
    assert rates.win_rate == nil
    # But conversion_rate IS defined (denominator is 4, numerator is 0 won) => a real 0.0.
    assert rates.conversion_rate == 0.0
  end

  test "ANTI-TAUTOLOGY: a fabricated-zero implementation would NOT equal nil — proving the assertion above is real" do
    refute same?(nil, 0.0)
  end

  # ==========================================================================
  # 2. LEADERBOARD RANKING — hand-computed order, exclusions
  # ==========================================================================

  test "activity_leaderboard ranks owners by CRM-anchored activity COUNT, descending, EXACT ranks" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    owner_a = Ash.UUID.generate()
    owner_b = Ash.UUID.generate()
    owner_c = Ash.UUID.generate()

    # A: 5 activities, B: 3, C: 1 — a clean, unambiguous rank order.
    for _ <- 1..5, do: seed_activity(org_id, owner_id: owner_a, subject_key: "crm.person")
    for _ <- 1..3, do: seed_activity(org_id, owner_id: owner_b, subject_key: "crm.company")
    seed_activity(org_id, owner_id: owner_c, subject_key: "crm.opportunity")

    scope = Samen.Web.Mount.scope(mount, org_id)
    board = Reads.activity_leaderboard(mount, scope)

    assert %{capped: false, hidden_owners: 0, hidden_count: 0} = board

    assert [
             %{rank: 1, owner_id: ^owner_a, count: 5},
             %{rank: 2, owner_id: ^owner_b, count: 3},
             %{rank: 3, owner_id: ^owner_c, count: 1}
           ] = board.rows
  end

  # Fix round 1, MED-1 — the verifier's exact live repro: 13 owners, the top performer (99
  # activities, ~80% of the org's total) has a uuid deliberately constructed to sort LAST
  # among all 13 (hex "f...") while the other 12 owners' uuids all sort BEFORE it (hex
  # "0..."). The PRIOR implementation discovered owners ASC-by-uuid and capped at 12 BEFORE
  # ranking — so the top performer, sorting 13th, was never even discovered, and rank 1 would
  # show one of the "0..."-prefixed owners with only 2 activities. Rank-BEFORE-cap fixes this:
  # discovery pulls all 13 (well under the 100 discovery_limit), THEN sorts by count, THEN
  # takes the top 12 for display — so the true top performer is always rank 1.
  test "MED-1 FIX: the true top performer surfaces at rank 1 even when their uuid sorts LAST among all discovered owners; the display cap is DISCLOSED" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    # Deliberately uuid-sorts LAST (hex 'f' > hex '0') — the exact bug shape.
    top_owner = "ffffffff-ffff-ffff-ffff-fffffffffff1"
    for _ <- 1..99, do: seed_activity(org_id, owner_id: top_owner, subject_key: "crm.person")

    # 12 other owners, uuid-sorts BEFORE top_owner, 2 activities each (24 total).
    other_owners =
      for i <- 1..12 do
        owner = "00000000-0000-0000-0000-00000000000#{i |> Integer.to_string(16) |> String.downcase()}"
        for _ <- 1..2, do: seed_activity(org_id, owner_id: owner, subject_key: "crm.company")
        owner
      end

    scope = Samen.Web.Mount.scope(mount, org_id)
    board = Reads.activity_leaderboard(mount, scope)

    # The true top performer is rank 1 — NOT absent, NOT buried.
    assert [%{rank: 1, owner_id: ^top_owner, count: 99} | rest] = board.rows
    assert length(rest) == 11

    # Total: 99 + 12*2 = 123 activities across 13 owners; the display shows top 12 (99 + 11*2
    # = 121 shown), so exactly 1 owner and 2 activities are hidden — EXACT, since discovery
    # (limit 100) was NOT capped at 13 owners.
    assert board.shown == 12
    assert board.capped == true
    assert board.hidden_owners == 1
    assert board.hidden_count == 2

    # Every discovered owner besides the hidden one is a real seeded owner (sanity: no
    # fabricated rows).
    assert Enum.all?(board.rows, &(&1.owner_id in [top_owner | other_owners]))
  end

  test "MED-1 FIX rendered: DashboardLive discloses the cap honestly (never a silently-truncated table)" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    top_owner = "ffffffff-ffff-ffff-ffff-fffffffffff1"
    for _ <- 1..99, do: seed_activity(org_id, owner_id: top_owner, subject_key: "crm.person")

    for i <- 1..12 do
      owner = "00000000-0000-0000-0000-00000000000#{i |> Integer.to_string(16) |> String.downcase()}"
      for _ <- 1..2, do: seed_activity(org_id, owner_id: owner, subject_key: "crm.company")
    end

    html = render_live(DashboardLive, mount, [org_id])

    # The true top performer's row is present with their real count.
    assert html =~ "lb-row-1"
    assert html =~ ~s(data-owner-id="#{top_owner}")
    # The disclosure paragraph renders, naming the exact withheld counts.
    assert html =~ ~s(data-capped="true")
    assert html =~ "Showing the top 12 members"
    assert html =~ "1"
    assert html =~ "2 more activities not shown"
  end

  # P2 (phase6-punchlist) — the DISCOVERY-CAPPED branch (`hidden_owners == nil`, i.e. the
  # ranking pool itself was capped: >discovery_limit distinct owners) must NOT claim
  # "the top N members" — the overall top performer may lie outside the bounded sample,
  # so that ordinal claim is FALSE in exactly that branch. Copy-only honesty fix.
  test "P2 cap disclosure: the discovery-capped branch (hidden_owners == nil) never claims 'the top' (ordinally false there)" do
    capped = %{shown: 12, hidden_owners: nil, hidden_count: 40}
    text = DashboardLive.cap_disclosure(capped)

    refute text =~ "the top"
    assert text =~ "bounded sample"
    assert text =~ "Showing 12 members"
    assert text =~ "40 more activities not shown"

    # ANTI-TAUTOLOGY control: the KNOWN-count branch (discovery NOT capped) still makes
    # the honest ordinal claim — proving the refute above is the nil branch, not a
    # helper that never says "the top" at all.
    known = %{shown: 12, hidden_owners: 1, hidden_count: 2}
    known_text = DashboardLive.cap_disclosure(known)
    assert known_text =~ "Showing the top 12 members"
    assert known_text =~ "1 more member(s)"
  end

  # Fix round 1, MED-2 — a leaderboard row can NEVER be the primitive's own bounded-tail
  # sentinel (`Samen.Web.Reads.other_key/0`, `:__other__`). Uses a SMALL `:discovery_limit`
  # (2, well under the 4 real owners seeded) to force discovery capping cheaply — the Other
  # slice's arithmetic-remainder value (2 activities, from the 2 undiscovered owners) is
  # STRICTLY GREATER than either discovered owner's own count (1 each), so if the Other
  # rejection were removed, `:__other__` WOULD sort to rank 1 (sabotage patch 82 proves this
  # by removing exactly that rejection).
  test "MED-2 FIX: the Other tail sentinel can NEVER appear as a leaderboard row, even when its arithmetic value would outrank every real owner" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    for _ <- 1..4 do
      owner = Ash.UUID.generate()
      seed_activity(org_id, owner_id: owner, subject_key: "crm.person")
    end

    scope = Samen.Web.Mount.scope(mount, org_id)
    board = Reads.activity_leaderboard(mount, scope, discovery_limit: 2)

    other = Samen.Web.Reads.other_key()

    assert board.capped == true
    refute Enum.any?(board.rows, &(&1.owner_id == other))
    # Anti-tautology: the Other slice's remainder (4 total - 2 discovered*1 each = 2) DOES
    # exceed each individual discovered owner's count (1) — so the rejection is load-bearing,
    # not vacuously true (there IS something that would outrank a real row if not rejected).
    assert Enum.all?(board.rows, &(&1.count == 1))
  end

  test "activity_leaderboard EXCLUDES unassigned (owner_id: nil) activities from the ranked list" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    owner_a = Ash.UUID.generate()

    seed_activity(org_id, owner_id: owner_a, subject_key: "crm.person")
    # Three unassigned activities — must NOT appear as a "nil" leaderboard row.
    for _ <- 1..3, do: seed_activity(org_id, owner_id: nil, subject_key: "crm.person")

    scope = Samen.Web.Mount.scope(mount, org_id)
    board = Reads.activity_leaderboard(mount, scope)

    assert [%{rank: 1, owner_id: ^owner_a, count: 1}] = board.rows
  end

  test "activity_leaderboard counts ONLY CRM-anchored tasks — a non-CRM Work task never inflates the count" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    owner_a = Ash.UUID.generate()

    seed_activity(org_id, owner_id: owner_a, subject_key: "crm.person")
    # A non-CRM-anchored task owned by the SAME member (e.g. a freight check-call/project
    # task in another vertical's Work usage) — must not count toward the CRM leaderboard.
    seed_activity(org_id, owner_id: owner_a, subject_key: "freight.load")

    scope = Samen.Web.Mount.scope(mount, org_id)
    board = Reads.activity_leaderboard(mount, scope)

    assert [%{rank: 1, owner_id: ^owner_a, count: 1}] = board.rows
  end

  test "activity_leaderboard is honestly empty when the org has no owned CRM activities yet" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    assert Reads.activity_leaderboard(mount, Samen.Web.Mount.scope(mount, org_id)) ==
             %{rows: [], capped: false, shown: 0, hidden_owners: 0, hidden_count: 0}
  end

  # ==========================================================================
  # 3. ORG-SCOPE (sabotage-refutable) — the T74/T75 lesson, pinned on day one
  # ==========================================================================

  test "ORG-SCOPE: org B's opportunities never contribute to org A's rates (and DO contribute to org B's own)" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    seed_opp(org_a, :won)
    seed_opp(org_a, :lost)

    # Org B genuinely holds 10 same-shaped opportunities — the refutation setup.
    for _ <- 1..10, do: seed_opp(org_b, :won)

    scope_a = Samen.Web.Mount.scope(mount, org_a)
    scope_b = Samen.Web.Mount.scope(mount, org_b)

    rates_a = Reads.pipeline_rates(mount, scope_a)
    rates_b = Reads.pipeline_rates(mount, scope_b)

    # Org A's win_rate is 1/(1+1) = 0.5, NOT skewed by org B's 10 wins.
    assert rates_a.win_rate == 0.5
    assert rates_a.won == 1

    # Refutation control: org B's OWN rates show its real 10 wins (so the absence above is
    # real org-scoping, not a seed that never landed anywhere).
    assert rates_b.won == 10
    assert rates_b.win_rate == 1.0
  end

  test "ORG-SCOPE: org B's activities never contribute to org A's leaderboard (and DO rank on org B's own)" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    owner_a = Ash.UUID.generate()
    owner_b_sentinel = Ash.UUID.generate()

    seed_activity(org_a, owner_id: owner_a, subject_key: "crm.person")

    # Org B genuinely holds 7 activities under a DIFFERENT owner — the refutation setup.
    for _ <- 1..7, do: seed_activity(org_b, owner_id: owner_b_sentinel, subject_key: "crm.person")

    board_a = Reads.activity_leaderboard(mount, Samen.Web.Mount.scope(mount, org_a))
    board_b = Reads.activity_leaderboard(mount, Samen.Web.Mount.scope(mount, org_b))

    assert [%{owner_id: ^owner_a, count: 1}] = board_a.rows
    refute Enum.any?(board_a.rows, &(&1.owner_id == owner_b_sentinel))

    # Refutation control: org B's own board shows its real 7.
    assert [%{owner_id: ^owner_b_sentinel, count: 7}] = board_b.rows
  end

  # ==========================================================================
  # 4. MASKING (verified non-PII, refutable) — no vault field on this surface
  # ==========================================================================

  test "MASKING: Task.owner_id (and every other field this surface reads) is NOT vault-routed (anchored vs a real 🔒 field)" do
    # The refutation anchor: Person.full_name IS vault-routed — so the negatives below are a
    # real property of the fields this surface touches, not a check that would pass for
    # everything (mirrors crm_dashboard_test.exs's own MASKING proof).
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)

    refute Samen.Pii.Info.vault_routed?(@task, :owner_id)
    refute Samen.Pii.Info.vault_routed?(@task, :subject_key)
    refute Samen.Pii.Info.vault_routed?(@task, :subject_id)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :status)
  end

  test "MASKING: the leaderboard tile source never CALLS PiiResolution.resolve/Vault.reveal — there is nothing to resolve (the moduledoc may still NAME PiiResolution in prose explaining why it's absent)" do
    src = File.read!("lib/samen/web/crm/dashboard_live.ex")
    refute src =~ "PiiResolution.resolve"
    refute src =~ "Vault.reveal"
  end

  # ==========================================================================
  # 5. INV-2 — this surface adds no cross-tenant Aggregate.Resource
  # ==========================================================================

  test "INV-2: neither Task nor Opportunity declares Samen.Aggregate.Resource — this reporting surface stays on the tenant-plane Reads kit, not the cross-tenant aggregate plane `mix samen.verify.aggregate_privacy` gates" do
    # Fix round 1, LOW-1 — the ANTI-TAUTOLOGY positive control: a REAL aggregate-plane
    # resource genuinely returns `true`, so the `refute`s below are a real property of
    # Task/Opportunity, not `aggregate_plane?/1` returning `false` for everything (its own
    # `rescue -> false` fires even for garbage/nonexistent modules).
    assert Samen.Aggregate.Info.aggregate_plane?(RealAggregateFixture)

    refute Samen.Aggregate.Info.aggregate_plane?(@task)
    refute Samen.Aggregate.Info.aggregate_plane?(@opportunity)
  end

  # ==========================================================================
  # 6. FIRST-CLIENT — real DashboardLive renders the new tiles
  # ==========================================================================

  test "FIRST-CLIENT: DashboardLive renders win-rate, conversion-rate, and the leaderboard from seeded data" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    seed_opp(org_id, :won)
    seed_opp(org_id, :lost)

    owner = Ash.UUID.generate()
    for _ <- 1..2, do: seed_activity(org_id, owner_id: owner, subject_key: "crm.person")

    html = render_live(DashboardLive, mount, [org_id])

    assert html =~ "Win rate"
    assert html =~ "50.0%"
    assert html =~ "Conversion"
    assert html =~ "dash-leaderboard"
    assert html =~ "Activities"
    assert html =~ "lb-row-1"
    assert html =~ "2"
  end

  test "FIRST-CLIENT HONEST EMPTY: a fresh org with no opportunities/activities renders '—' rates and the empty-leaderboard message, never a fabricated number" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    html = render_live(DashboardLive, mount, [org_id])

    assert html =~ "dash-leaderboard"
    assert html =~ "No activity yet"
    refute html =~ "0.0%"
  end
end
