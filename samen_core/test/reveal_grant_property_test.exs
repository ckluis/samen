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

  ## Determinism (T129, T121-pattern)

  This property exercises ONE thing: `active?/3` as a pure function of the clock
  vs the row's `expires_at` (plus the requestor-bound + distinct-party + unrevoked
  gate). It does NOT exercise the grant-MINTING pipeline (that is
  `reveal_grant_same_tx_test`, `reveal_grants_test`, `reveal_grant_seam_test`).

  Earlier revisions minted each grant via `Grants.request/1` + `Grants.approve/2`,
  which routes through the Ash Approvals **engine** (a real decision transaction +
  Ash notifications) and an **Oban** same-tx enqueue, deriving `expires_at` from a
  **wall-clock** `now`. The clock ASSERTION here is deterministic-by-math (usec
  precision, whole-second offsets), so it can never flip — but that minting
  pipeline could intermittently RAISE under full-suite load (it is the source of
  the `[warning] Missed 1 notifications` runtime lines this file emitted), turning
  a first `./ci.sh` run red then clearing on re-run — the T129 flake.

  Fix (T121 pattern — construct the row directly with a controlled instant): the
  grant row is inserted DIRECTLY with a **fixed** `expires_at` (no wall clock, no
  engine, no Oban), so the property is a pure, deterministic-by-construction
  function of `clock` vs that pinned `expires_at`. The row is still a genuine,
  DISTINCT-PARTY-approved (`granted_by != requestor_id`), un-revoked grant bound
  to the requestor, so every `active?/3` gate clause the property means to check —
  subject match, requestor binding, distinct-party, unrevoked, clock-vs-expiry —
  is still genuinely exercised. The DB `rvg_distinct_party` CHECK also still holds
  on the write (approver is always distinct from the requestor).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Samen.Reveal.Grants
  alias Samen.Reveal.RevealGrant

  @repo SamenCore.TestRepo

  # A FIXED base instant. `expires_at` is pinned relative to this (never derived
  # from the wall clock through the mint pipeline), so the whole property is a
  # deterministic function of the generated `(window_minutes, offset_seconds)`.
  @base ~U[2026-01-01 12:00:00.000000Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  # Insert a LIVE reveal grant row directly (no request/approve engine, no Oban,
  # no wall clock) with a controlled `expires_at`. The row is un-revoked and
  # DISTINCT-party-approved (`granted_by != requestor_id`), exactly the shape
  # `active?/3` must honor for the requestor — so the property still checks the
  # real requestor-bound + distinct-party + unrevoked + clock-vs-expiry gate, just
  # without the nondeterministic minting pipeline. `insert!` still hits the DB
  # `rvg_distinct_party` CHECK, which passes iff approver != requestor (always).
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

  property "active? tracks the clock vs expires_at (deny at/after expiry, allow before)" do
    check all(
            window_minutes <- integer(1..120),
            # offset_seconds relative to expires_at: negative = before, >=0 = at/after
            offset_seconds <- integer(-7200..7200),
            max_runs: 60
          ) do
      s = subj()
      requestor = actor()
      approver = actor()

      # A DISTINCT party (approver != requestor) holds a live grant for the
      # requestor with a controlled, wall-clock-independent expiry.
      expires_at = DateTime.add(@base, window_minutes * 60, :second)
      insert_live_grant!(s, requestor, approver, expires_at)

      clock = DateTime.add(expires_at, offset_seconds, :second)
      # The reveal capability binds to the REQUESTOR (P1 authz fix), gated on the
      # distinct approver having created the grant.
      result = Grants.active?(requestor, s, now: clock)

      # The row is never revoked in this property (we never drain / revoke), so
      # the ONLY gate is clock vs expires_at.
      if offset_seconds < 0 do
        assert result, "expected active before expiry (offset=#{offset_seconds}s)"
      else
        refute result, "expected DENY at/after expiry (offset=#{offset_seconds}s)"
      end
    end
  end

  property "a DIFFERENT actor never gets the grant, at any clock position" do
    check all(
            window_minutes <- integer(1..120),
            offset_seconds <- integer(-7200..7200),
            max_runs: 40
          ) do
      s = subj()
      requestor = actor()
      approver = actor()
      stranger = actor()

      expires_at = DateTime.add(@base, window_minutes * 60, :second)
      insert_live_grant!(s, requestor, approver, expires_at)

      clock = DateTime.add(expires_at, offset_seconds, :second)
      # A stranger (not the grant holder) is never authorized, ever — the grant is
      # live (requestor could reveal here), so this genuinely tests the requestor
      # binding, not merely an already-dead grant.
      refute Grants.active?(stranger, s, now: clock)
    end
  end
end
