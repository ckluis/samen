defmodule Samen.ImpersonationTest do
  @moduledoc """
  T4.1 masked-impersonation core (doc §control "Running the business"). Proves the
  session runtime mirrors the T1.6 reveal-grant mechanics: short-TTL, reason-required,
  single-org, deny-on-read per request, no renew-in-place, and every open/close/expiry
  writes a token-only aud_event row.

  Red paths here:
    * impersonation without a reason REFUSES (`{:error, :reason_required}`);
    * an expired session DENIES mid-flight (the expiry check is per-request via
      `active?/3` / the scope builder, not per-open);
    * a `:operator_readonly` (or non-operator) actor may NOT open a session.

  Anti-tautology probe on the expiry check: the SAME operator+org that DENIES after
  expiry ALLOWS before it (with only the clock moved) — so "denied" is the expiry gate
  firing, not a blanket refusal.
  """
  use ExUnit.Case, async: false

  alias Samen.Impersonation
  alias Samen.Impersonation.{Sessions, Scope, Session}
  alias Samen.OperatorPlane.Actor

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp operator(role \\ :operator_support),
    do: Actor.new("operator-#{System.unique_integer([:positive])}", role)

  defp org_id, do: Ecto.UUID.generate()

  # ==========================================================================
  # Open + lifecycle
  # ==========================================================================

  describe "open/3" do
    test "opens a short-TTL, single-org session with a reason and makes it active" do
      op = operator()
      org = org_id()

      assert {:ok, %Session{} = session} = Impersonation.open(op, org, "billing dispute #123")
      assert session.operator_id == op.id
      assert to_string(session.org_id) == org
      assert session.reason == "billing dispute #123"
      # Minutes-scale bounded window (default 30) — not a standing entitlement.
      assert DateTime.diff(session.expires_at, DateTime.utc_now(), :minute) in 25..30

      assert Impersonation.active?(op, org)
    end

    test "every open writes a token-only aud_event row (T4.1 clause (d))" do
      op = operator()
      org = org_id()
      {:ok, session} = Impersonation.open(op, org, "checking their onboarding")

      events = Samen.AuditEvent.for_subject(@repo, org)
      assert [ev | _] = events
      assert ev.event_type == "impersonation"
      # subject = the target org (bounded UUID), actor = the operator (bounded id).
      assert ev.subject_id == org
      assert ev.actor_id == op.id
      assert ev.correlation_id == session.id
      assert ev.detail =~ "event=open"
      assert ev.detail =~ "checking their onboarding"

      # No plaintext PII in the audit detail — it carries the reason + tokens only.
      refute ev.detail =~ ~r/\bssn\b/i
    end

    test "close/2 closes the session and writes a close event; a closed session denies" do
      op = operator()
      org = org_id()
      {:ok, session} = Impersonation.open(op, org, "support call")

      assert Impersonation.active?(op, org)
      assert {:ok, _closed} = Impersonation.close(session.id)
      refute Impersonation.active?(op, org)

      # A close aud_event row landed.
      events = Samen.AuditEvent.for_subject(@repo, org)
      assert Enum.any?(events, &(&1.detail =~ "event=close"))
    end
  end

  # ==========================================================================
  # RED PATH: reason required
  # ==========================================================================

  describe "reason-for-access is REQUIRED (red path)" do
    test "an open with no reason REFUSES before any DB write" do
      op = operator()
      org = org_id()

      assert {:error, :reason_required} = Impersonation.open(op, org, nil)
      assert {:error, :reason_required} = Impersonation.open(op, org, "")
      assert {:error, :reason_required} = Impersonation.open(op, org, "   ")

      # Nothing was written — no active session, no aud_event.
      refute Impersonation.active?(op, org)
      assert Samen.AuditEvent.for_subject(@repo, org) == []
    end

    test "Sessions.open/1 with a reason but no operator_id/org_id raises (missing key)" do
      assert_raise ArgumentError, ~r/missing required key/, fn ->
        Sessions.open(%{reason: "x"})
      end
    end
  end

  # ==========================================================================
  # RED PATH + ANTI-TAUTOLOGY: expired session denies mid-flight (per-request)
  # ==========================================================================

  describe "expiry denies mid-flight — per-request, not per-open (red path)" do
    test "a session active at open denies once now() > expires_at, checked per request" do
      op = operator()
      org = org_id()

      # A 1-minute window.
      {:ok, session} = Impersonation.open(op, org, "quick check", window_minutes: 1)

      # BEFORE expiry: active (anti-tautology positive control — same op+org).
      before = DateTime.add(session.expires_at, -30, :second)
      assert Sessions.active?(op.id, org, now: before)
      assert {:ok, %Samen.Scope{}} = Scope.for_session(op.id, org, now: before)

      # AFTER expiry: DENIED — with ONLY the clock moved past expires_at. The session
      # row still exists (no cleanup ran), proving the deny is the per-request expiry
      # check, not the auto-expire worker.
      later = DateTime.add(session.expires_at, 1, :second)
      refute Sessions.active?(op.id, org, now: later)
      assert {:error, :session_inactive} = Scope.for_session(op.id, org, now: later)

      # The row is still THERE and still open (deny-on-read, not deny-on-cleanup).
      assert %Session{closed_at: nil} = Sessions.get(session.id)
    end
  end

  # ==========================================================================
  # RED PATH + ANTI-TAUTOLOGY: suspension terminates a LIVE session (F4.2)
  # ==========================================================================

  describe "suspending an operator ends a live session on its next request (F4.2)" do
    alias Samen.OperatorPlane.Suspension

    test "a suspend mid-session makes the next scope rebuild DENY; the unsuspended session continues" do
      op = operator()
      org = org_id()

      # Open a live, unexpired session and confirm the scope rebuilds cleanly.
      {:ok, session} = Impersonation.open(op, org, "billing dispute #123", window_minutes: 30)
      assert {:ok, %Samen.Scope{}} = Scope.for_session(op.id, org)

      # Suspend the operator MID-SESSION.
      {:ok, _} = Suspension.suspend(%{operator_id: op.id, reason: "budget breach", repo: @repo})

      # RED PATH: the NEXT scope rebuild DENIES with the access-denied shape — even though
      # the session row is still unexpired and OPEN (deny is the suspension gate, not expiry).
      assert {:error, :operator_suspended} = Scope.for_session(op.id, org)
      assert %Session{closed_at: nil} = Sessions.get(session.id)
      # The unexpired session confirms this is NOT the expiry path firing.
      assert Sessions.active?(op.id, org)

      # ANTI-TAUTOLOGY / positive control: clear the suspension and the SAME session's scope
      # rebuild succeeds again — the deny was the suspension gate, not a blanket refusal.
      {:ok, _} = Suspension.clear(op.id, %{repo: @repo})
      assert {:error, :operator_suspended} != Scope.for_session(op.id, org)
      assert {:ok, %Samen.Scope{}} = Scope.for_session(op.id, org)
    end

    test "a DIFFERENT operator's live session is unaffected by this operator's suspension" do
      op_suspended = operator()
      op_clean = operator()
      org = org_id()

      {:ok, _} = Impersonation.open(op_suspended, org, "case A", window_minutes: 30)
      {:ok, _} = Impersonation.open(op_clean, org, "case B", window_minutes: 30)

      {:ok, _} = Suspension.suspend(%{operator_id: op_suspended.id, reason: "abuse", repo: @repo})

      # The suspended operator is denied; the clean operator over the SAME org still builds.
      assert {:error, :operator_suspended} = Scope.for_session(op_suspended.id, org)
      assert {:ok, %Samen.Scope{}} = Scope.for_session(op_clean.id, org)
    end
  end

  # ==========================================================================
  # RED PATH: no renew-in-place
  # ==========================================================================

  describe "no renew-in-place (red path)" do
    test "attempt_extend always fails and there is no path that mutates expires_at" do
      op = operator()
      org = org_id()
      {:ok, session} = Impersonation.open(op, org, "x", window_minutes: 1)

      assert {:error, :no_renew_in_place} =
               Sessions.attempt_extend(session.id, DateTime.add(session.expires_at, 3600))

      # The window is unchanged.
      assert %Session{expires_at: exp} = Sessions.get(session.id)
      assert DateTime.compare(exp, session.expires_at) == :eq
    end
  end

  # ==========================================================================
  # RED PATH: operator RBAC — who may impersonate
  # ==========================================================================

  describe "operator RBAC (red path)" do
    test "a :operator_readonly may NOT open a session" do
      op = operator(:operator_readonly)
      org = org_id()

      refute Actor.may_impersonate?(op)
      assert {:error, :not_authorized} = Impersonation.open(op, org, "reason")
      refute Impersonation.active?(op, org)
    end

    test "a non-operator actor (a bare map / tenant member) may NOT impersonate" do
      refute Actor.may_impersonate?(%{id: "tenant-user", role: :admin})
      assert {:error, :not_authorized} =
               Impersonation.open(%{id: "tenant-user", role: :admin}, org_id(), "reason")
    end

    test ":operator_admin and :operator_support may impersonate" do
      assert Actor.may_impersonate?(operator(:operator_admin))
      assert Actor.may_impersonate?(operator(:operator_support))
    end

    test "Actor.new/2 refuses an unknown role (fail closed)" do
      assert_raise ArgumentError, fn -> Actor.new("op-1", :god_mode) end
    end
  end

  # ==========================================================================
  # Tenant-visible listing (T4.1 clause (c))
  # ==========================================================================

  describe "list_for_org/2 — tenant-visible accountability view" do
    test "a tenant can see who impersonated their org, when, why, and expiry" do
      op1 = operator()
      op2 = operator()
      org = org_id()
      other_org = org_id()

      {:ok, _} = Impersonation.open(op1, org, "reason one")
      {:ok, s2} = Impersonation.open(op2, org, "reason two")
      {:ok, _} = Impersonation.open(op1, other_org, "different org")

      {:ok, _} = Impersonation.close(s2.id)

      list = Impersonation.list_for_org(org)
      assert length(list) == 2

      # Only THIS org's impersonations (not the other org's).
      assert Enum.all?(list, &(&1.operator_id in [op1.id, op2.id]))
      reasons = Enum.map(list, & &1.reason)
      assert "reason one" in reasons
      assert "reason two" in reasons

      # who / when / reason / expiry / active? all present.
      entry = Enum.find(list, &(&1.operator_id == op1.id))
      assert entry.reason == "reason one"
      assert %DateTime{} = entry.opened_at
      assert %DateTime{} = entry.expires_at
      assert entry.active? == true

      # The closed session shows active? == false.
      closed_entry = Enum.find(list, &(&1.operator_id == op2.id))
      assert closed_entry.active? == false
      assert %DateTime{} = closed_entry.closed_at
    end
  end
end
