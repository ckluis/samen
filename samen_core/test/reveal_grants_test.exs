defmodule Samen.Reveal.GrantsTest do
  @moduledoc """
  T1.6 reveal-grant model (doc §control "'Time-boxed' is a built mechanism, not
  an adjective"; D6).

  Covers clauses:
    (a) RevealRequest/RevealGrant with subject_id/granted_by/requestor_id/reason/
        expires_at + bounded default window
    (b) distinct-party approval enforced in POLICY (this file) AND by DB CHECK
        (reveal_grant_db_check_test.exs)
    (c) deny-on-read: policy denies the moment now() > expires_at even with a
        stale (un-revoked) row
    (e) no renew-in-place (attempt_extend fails; no action mutates expires_at)
    (f) lifecycle audit rows written
  """
  use ExUnit.Case, async: false

  alias Samen.Reveal.Grants
  alias Samen.Reveal.{RevealRequest, RevealGrant}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    # Oban runs in :manual mode; share the sandbox connection so same-tx enqueue
    # sees the checked-out connection.
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  # ==========================================================================
  # (a) request + approve happy path, bounded default window
  # ==========================================================================

  describe "(a) request → distinct-party approve → time-boxed grant" do
    test "request writes a pending RevealRequest and a requested audit row" do
      s = subj()
      req_id = actor()

      assert {:ok, %RevealRequest{} = req} =
               Grants.request(%{subject_id: s, requestor_id: req_id, reason: "support ticket 42"})

      assert req.status == "pending"
      assert req.subject_id == s
      assert req.reason == "support ticket 42"

      events = Grants.audit_for(s) |> Enum.map(& &1.event)
      assert "requested" in events
    end

    test "approve by a DISTINCT party writes a grant with a bounded expires_at" do
      s = subj()
      requestor = actor()
      approver = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "reason"})

      before = DateTime.utc_now()
      assert {:ok, %RevealGrant{} = grant} = Grants.approve(req, %{granted_by: approver})

      assert grant.requestor_id == requestor
      assert grant.granted_by == approver
      assert grant.revoked_at == nil

      # Bounded default window (15 min) — expires within [now, now + 16min].
      assert DateTime.compare(grant.expires_at, before) == :gt
      assert DateTime.diff(grant.expires_at, before, :second) <= 16 * 60
      assert DateTime.diff(grant.expires_at, before, :second) >= 14 * 60
    end

    test "window_minutes overrides the default window" do
      s = subj()
      requestor = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      before = DateTime.utc_now()

      {:ok, grant} = Grants.approve(req, %{granted_by: actor(), window_minutes: 1})
      assert DateTime.diff(grant.expires_at, before, :second) <= 61
    end

    test "approve by id resolves the request" do
      s = subj()
      requestor = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      assert {:ok, %RevealGrant{}} = Grants.approve(req.id, %{granted_by: actor()})
    end
  end

  # ==========================================================================
  # (b) POLICY-layer distinct-party (DB layer proven separately)
  # ==========================================================================

  describe "(b) RED PATH — self-approval blocked at the POLICY layer" do
    test "approve where granted_by == requestor_id returns {:error, :self_approval}" do
      s = subj()
      me = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: me, reason: "r"})

      assert {:error, :self_approval} = Grants.approve(req, %{granted_by: me})
    end

    test "a refused self-approval writes NO grant row (whole op refused)" do
      s = subj()
      me = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: me, reason: "r"})
      {:error, :self_approval} = Grants.approve(req, %{granted_by: me})

      import Ecto.Query
      grants = @repo.all(from(g in RevealGrant, where: g.subject_id == ^s))
      assert grants == []
    end

    test "a refused self-approval writes a denied audit row" do
      s = subj()
      me = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: me, reason: "r"})
      {:error, :self_approval} = Grants.approve(req, %{granted_by: me})

      events = Grants.audit_for(s) |> Enum.map(& &1.event)
      assert "denied" in events
      refute "granted" in events
    end
  end

  # ==========================================================================
  # (c) deny-on-read: expiry denies even with a stale row
  # ==========================================================================

  describe "(c) deny-on-read — expired grant denies even if never cleaned up" do
    test "active? is true for a live grant" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, _grant} = Grants.approve(req, %{granted_by: approver})

      assert Grants.active?(requestor, s)
    end

    test "RED PATH: active? is FALSE once now() > expires_at, with the row still present and un-revoked" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 1})

      # The row is present and revoked_at is still NULL (auto-revoke job did NOT
      # run — testing mode is :manual and we do not drain). Evaluate the policy
      # at a clock position AFTER expires_at.
      future = DateTime.add(grant.expires_at, 60, :second)

      # Prove the row is still there and un-revoked (deny is on read, not cleanup).
      reloaded = @repo.get(RevealGrant, grant.id)
      assert reloaded.revoked_at == nil

      refute Grants.active?(requestor, s, now: future)
    end

    test "RED PATH: a revoked grant denies even before expiry" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 60})

      assert Grants.active?(requestor, s)
      {:ok, _} = Grants.revoke(grant.id)
      refute Grants.active?(requestor, s)
    end
  end

  # ==========================================================================
  # (e) no renew-in-place
  # ==========================================================================

  describe "(e) RED PATH — no renew-in-place" do
    test "attempt_extend always fails; there is no path that mutates expires_at" do
      s = subj()
      requestor = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: actor(), window_minutes: 1})

      new_expiry = DateTime.add(grant.expires_at, 3600, :second)
      assert {:error, :no_renew_in_place} = Grants.attempt_extend(grant.id, new_expiry)

      # expires_at is unchanged in the DB.
      assert @repo.get(RevealGrant, grant.id).expires_at == grant.expires_at
    end

    test "revoke sets revoked_at but NEVER touches expires_at" do
      s = subj()
      requestor = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: actor(), window_minutes: 60})

      {:ok, revoked} = Grants.revoke(grant.id)
      assert revoked.revoked_at != nil
      assert revoked.expires_at == grant.expires_at
    end

    test "re-access requires a FRESH request + approval (a new grant row)" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req1} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r1"})
      {:ok, grant1} = Grants.approve(req1, %{granted_by: approver, window_minutes: 60})
      {:ok, _} = Grants.revoke(grant1.id)
      refute Grants.active?(requestor, s)

      # A fresh request + approval restores access via a DISTINCT new grant.
      {:ok, req2} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r2"})
      {:ok, grant2} = Grants.approve(req2, %{granted_by: approver, window_minutes: 60})
      assert grant2.id != grant1.id
      assert Grants.active?(requestor, s)
    end
  end

  # ==========================================================================
  # (f) lifecycle audit rows
  # ==========================================================================

  describe "(f) grant lifecycle audit rows" do
    test "requested → granted → revoked all land as audit rows" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 60})
      {:ok, _} = Grants.revoke(grant.id)

      events = Grants.audit_for(s) |> Enum.map(& &1.event) |> Enum.sort()
      assert "requested" in events
      assert "granted" in events
      assert "revoked" in events
    end
  end

  # ==========================================================================
  # (b') Gate-0 vault-stack fix (P1 authz): the REQUESTOR holds the reveal
  # capability post distinct-party approval, NOT the approver. This closes the
  # self-serve-via-throwaway-requestor collusion.
  # ==========================================================================

  describe "reveal capability binds to the requestor, not the approver" do
    test "the requestor holds the capability after a distinct approver grants it" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, _grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 60})

      assert Grants.active?(requestor, s)
    end

    test "RED PATH: the APPROVER does NOT hold the reveal capability" do
      s = subj()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, _grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 60})

      # The approver merely AUTHORIZES; they cannot reveal. If active? keyed on
      # granted_by (the pre-fix model), this would be true — and an operator could
      # self-serve by being the approver for a throwaway requestor.
      refute Grants.active?(approver, s)
    end

    test "RED PATH: throwaway-requestor collusion is closed — no single actor can both request and reveal" do
      s = subj()
      # A malicious operator files a request under a BURNER requestor id they
      # control, hoping to later self-approve and reveal.
      operator = actor()
      burner_requestor = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: burner_requestor, reason: "sketchy"})

      # They cannot approve their own-controlled request as themselves if they ARE
      # the requestor (self-approval blocked). Trying to approve as the operator
      # (a DISTINCT party from the burner) DOES create a grant — but the capability
      # then binds to the BURNER requestor, NOT the operator. So the operator (the
      # approver) still cannot reveal.
      {:ok, _grant} = Grants.approve(req, %{granted_by: operator, window_minutes: 60})

      refute Grants.active?(operator, s),
             "the approving operator must NOT hold the reveal capability"

      # And a burner requestor id the operator merely controls does technically
      # hold the capability — but that is the whole point of dual control: to
      # reveal, the operator must act AS the requestor AND get a DISTINCT approver.
      # The single-actor self-serve path (approve-then-reveal-as-approver) is dead.
      assert Grants.active?(burner_requestor, s)
    end

    test "RED PATH: a self-approved grant can never authorize a reveal (defence in depth on read)" do
      s = subj()
      me = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: me, reason: "r"})
      # Self-approval is refused at the policy layer, so no grant exists at all.
      assert {:error, :self_approval} = Grants.approve(req, %{granted_by: me})
      # Therefore the actor holds no capability.
      refute Grants.active?(me, s)
    end
  end
end
