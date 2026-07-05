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
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Samen.Reveal.Grants

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

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

      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: window_minutes})

      clock = DateTime.add(grant.expires_at, offset_seconds, :second)
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

      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: window_minutes})

      clock = DateTime.add(grant.expires_at, offset_seconds, :second)
      # A stranger (not the grant holder) is never authorized, ever.
      refute Grants.active?(stranger, s, now: clock)
    end
  end
end
