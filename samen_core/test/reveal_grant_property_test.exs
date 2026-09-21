defmodule Samen.Reveal.GrantPropertyTest do
  @moduledoc """
  T1.6 property test (plan §6.2 "grant policy (∀ clock positions vs expires_at →
  deny after)").

  For a grant with a fixed `expires_at`, `Samen.Reveal.Grants.active?/3` must:
    * be TRUE for every clock position strictly before expires_at (row live,
      un-revoked), and
    * be FALSE for every clock position at or after expires_at,

  purely as a function of the clock vs the row's expires_at — with NO dependence
  on the auto-revoke job having run (deny-on-read, clause (c)).

  ## What this property actually refutes

  Of the five clauses in `active?/3`'s query, exactly TWO are refutable by THIS file:
  **clock-vs-expiry** (sabotage `g.expires_at > ^now` and the at/after-expiry property
  below goes red) and **requestor-binding** (sabotage `g.requestor_id == ^requestor_id`
  and the stranger property goes red). `unrevoked`, the `subject_id` match and
  `granted_by != requestor_id` are NOT refutable here — the row is never revoked, the
  requestor id is unique per iteration (so the subject filter is redundant within this
  test), and the `rvg_distinct_party` DB CHECK makes a same-party row impossible to insert
  at all. Those three are covered elsewhere (`reveal_grants_test`, the revoke tests, and
  the CHECK itself). This moduledoc used to claim all five were exercised here; that was
  the overclaim the T129 verification caught, and it is not made any more.

  ## Determinism by construction (T129, and the three couplings it left behind)

  The clock is INJECTED (`now:`) and `expires_at` is pinned relative to a fixed `@base`, so
  the assertion is arithmetic — no wall clock reaches it. T129 additionally removed the
  grant-MINTING pipeline from this file (`Grants.request/1` + `Grants.approve/2` → the Ash
  approvals engine, a same-tx Oban enqueue, and a wall-clock-derived `expires_at`): the row
  is now inserted DIRECTLY with a controlled instant. That fix is what stopped this file
  needing a re-run, and it is unchanged here.

  Three run-to-run couplings survived it, and none of them belongs in a property whose
  verdict is supposed to be pure arithmetic:

    1. **The repo is injected too** (`repo: @repo`). `active?/3` otherwise resolves it from
       `Application.get_env(:samen_core, :reveal_grant_repo)` AT CALL TIME, while the fixture
       row is written through `@repo` — so the property was asserting against whichever repo
       the application env happened to point at when that line ran, a global that any other
       test can move (the multinode harness repoints exactly that key). Injecting it makes
       the write and the read provably the same connection.

    2. **No GLOBAL shared sandbox mode.** This file does no off-process DB work at all — it
       inserts and queries from the test process — so `mode(@repo, {:shared, self()})` bought
       nothing and cost isolation: while shared mode is on, any still-alive process in the VM
       shares this test's connection AND its transaction (one failed statement from such a
       process aborts it, and every later insert here then raises), and, having no teardown,
       it also left the global mode switched for whatever ran next. An ordinary owner
       checkout is all this file needs.

    3. **Generators that cannot straddle the boundary.** The single signed-offset generator
       plus an `if` is replaced by TWO single-assertion properties — strictly-before ⇒ allow,
       at-or-after ⇒ deny — plus an explicit boundary test at −1s / 0s / +1s. A branch inside
       a property body is only taken when the seed happens to generate that side, so the
       exact `clock == expires_at` case (the "at expiry" half of the stated property, and the
       only position where `>` and `>=` differ) was previously proven only on runs where
       StreamData produced a 0. It is now proven on every run, and neither property body
       contains a branch that can go unexercised.

  The row is still a genuine, DISTINCT-PARTY-approved (`granted_by != requestor_id`),
  un-revoked grant bound to the requestor, so every clause the property means to check is
  present in the fixture; `insert!` still hits the `rvg_distinct_party` DB CHECK, which
  passes iff approver != requestor (always).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Samen.Reveal.Grants
  alias Samen.Reveal.RevealGrant

  @repo SamenCore.TestRepo

  # A FIXED base instant. `expires_at` is pinned relative to this (never derived
  # from the wall clock through the mint pipeline), so the whole property is a
  # deterministic function of the generated offsets.
  @base ~U[2026-01-01 12:00:00.000000Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  # Insert a LIVE reveal grant row directly (no request/approve engine, no Oban,
  # no wall clock) with a controlled `expires_at`. The row is un-revoked and
  # DISTINCT-party-approved (`granted_by != requestor_id`), exactly the shape
  # `active?/3` must honor for the requestor.
  defp insert_live_grant!(subject_id, requestor_id, granted_by, expires_at) do
    @repo.insert!(%RevealGrant{
      id: Ecto.UUID.generate(),
      request_id: Ecto.UUID.generate(),
      subject_id: subject_id,
      requestor_id: requestor_id,
      granted_by: granted_by,
      reason: "r",
      expires_at: expires_at,
      revoked_at: nil,
      inserted_at: @base,
      updated_at: @base
    })
  end

  # A live grant whose expiry sits a fixed number of minutes after @base.
  defp live_grant!(window_minutes) do
    subject = subj()
    requestor = actor()
    approver = actor()
    expires_at = DateTime.add(@base, window_minutes * 60, :second)

    insert_live_grant!(subject, requestor, approver, expires_at)

    %{subject: subject, requestor: requestor, approver: approver, expires_at: expires_at}
  end

  # BOTH the clock and the repo are injected, so the verdict depends on nothing global.
  defp active?(actor_id, subject_id, clock),
    do: Grants.active?(actor_id, subject_id, now: clock, repo: @repo)

  property "ALLOW at every clock position strictly BEFORE expires_at" do
    check all(
            window_minutes <- integer(1..120),
            # strictly-before by CONSTRUCTION: the generator cannot reach the boundary.
            before_seconds <- integer(1..7200),
            max_runs: 60
          ) do
      g = live_grant!(window_minutes)
      clock = DateTime.add(g.expires_at, -before_seconds, :second)

      # The reveal capability binds to the REQUESTOR (P1 authz fix), gated on the
      # distinct approver having created the grant. The row is never revoked here, so
      # the ONLY gate is clock vs expires_at.
      assert active?(g.requestor, g.subject, clock),
             "expected ACTIVE #{before_seconds}s before expiry"
    end
  end

  property "DENY at every clock position AT or AFTER expires_at" do
    check all(
            window_minutes <- integer(1..120),
            # at-or-after by CONSTRUCTION, 0 included: deny-on-read (clause (c)) denies the
            # moment the clock reaches expires_at, with no dependence on the auto-revoke job.
            after_seconds <- integer(0..7200),
            max_runs: 60
          ) do
      g = live_grant!(window_minutes)
      clock = DateTime.add(g.expires_at, after_seconds, :second)

      refute active?(g.requestor, g.subject, clock),
             "expected DENY #{after_seconds}s at/after expiry"
    end
  end

  test "the expiry boundary itself, pinned: ALLOW at -1s, DENY at 0s and +1s" do
    g = live_grant!(15)

    # `clock == expires_at` is the one position where `>` and `>=` disagree, so it is
    # asserted unconditionally rather than left to whether the seed generates it.
    assert active?(g.requestor, g.subject, DateTime.add(g.expires_at, -1, :second))
    refute active?(g.requestor, g.subject, g.expires_at)
    refute active?(g.requestor, g.subject, DateTime.add(g.expires_at, 1, :second))
  end

  property "a DIFFERENT actor never gets the grant, at any clock position" do
    check all(
            window_minutes <- integer(1..120),
            offset_seconds <- integer(-7200..7200),
            max_runs: 40
          ) do
      g = live_grant!(window_minutes)
      stranger = actor()
      clock = DateTime.add(g.expires_at, offset_seconds, :second)

      # A stranger (not the grant holder) is never authorized, ever — and the grant is
      # LIVE for a negative offset (the requestor could reveal there), so this genuinely
      # tests the requestor binding, not merely an already-dead grant.
      refute active?(stranger, g.subject, clock)
    end
  end
end
