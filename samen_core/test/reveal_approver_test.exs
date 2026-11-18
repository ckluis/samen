defmodule Samen.Reveal.ApproverTest do
  @moduledoc """
  PP-13 — the KERNEL half of the tenant reveal-APPROVER surface: the org-scoped pending read
  (`Samen.Reveal.Grants.pending_for_org/2` over `Samen.Approvals.list_pending/3`), the
  approve-moment audit landing on the TENANT chain (the B6 residual close in
  `do_approve/4`), and `Samen.Reveal.Grants.deny/2`.

  Each guarantee pairs a red path with a positive control (anti-tautology), and three are
  sabotage-pinned (org-scope drop, approve-audit-off-chain, distinct-party self-approval).
  """
  use ExUnit.Case, async: false

  alias Samen.Reveal.Grants
  alias Samen.Reveal.RevealGrant

  import Ecto.Query

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"
  defp org, do: Ecto.UUID.generate()

  # ==========================================================================
  # pending_for_org/2 — the org-scoped, metadata-only pending read
  # ==========================================================================

  describe "pending_for_org/2 org-scoped pending read" do
    test "lists this org's pending reveal-requests, enriched with the request metadata" do
      org_a = org()
      s = subj()
      requestor = actor()

      {:ok, req} =
        Grants.request(%{
          subject_id: s,
          requestor_id: requestor,
          reason: "ticket 88: CDL verify",
          resource: Some.Freight.Driver,
          action: :reveal_driver,
          org_id: org_a
        })

      assert [row] = Grants.pending_for_org(org_a, repo: @repo)
      assert row.request_id == req.id
      assert row.subject_id == s
      assert row.requestor_id == requestor
      assert row.reason == "ticket 88: CDL verify"
      assert row.resource == "Elixir.Some.Freight.Driver"
      assert row.action == "reveal_driver"
      assert is_binary(row.approval_id)
    end

    test "RED: a failed pending read RAISES instead of answering [] (nothing awaiting approval); healthy, the same call answers" do
      org_a = org()
      s = subj()

      {:ok, _req} =
        Grants.request(%{subject_id: s, requestor_id: actor(), reason: "ticket 89: pending read", org_id: org_a})

      Samen.FaultRepo.fail([:get])

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unavailable} = Grants.pending_for_org_result(org_a, repo: Samen.FaultRepo)
        assert_raise RuntimeError, ~r/could not be read/, fn -> Grants.pending_for_org(org_a, repo: Samen.FaultRepo) end
      end)

      Samen.FaultRepo.heal()
      assert [_] = Grants.pending_for_org(org_a, repo: Samen.FaultRepo)
    end

    test "MASKING: the pending row carries ONLY metadata — no vault value, no vt_* token" do
      org_a = org()

      {:ok, _req} =
        Grants.request(%{
          subject_id: subj(),
          requestor_id: actor(),
          reason: "ticket 90: verify",
          org_id: org_a
        })

      [row] = Grants.pending_for_org(org_a, repo: @repo)

      # The row is a fixed metadata projection — it has NO field that could hold the
      # plaintext value the approver is deciding whether to unmask.
      assert Map.keys(row) |> Enum.sort() ==
               [:action, :approval_id, :org_id, :reason, :request_id, :requested_at, :requestor_id, :resource, :subject_id]

      refute row |> Map.values() |> Enum.any?(fn v -> is_binary(v) and String.contains?(v, "vt_") end)
    end

    test "RED: a different org sees NONE of another org's pending reveal requests (org-scope)" do
      org_a = org()
      org_b = org()
      s = subj()
      requestor = actor()

      {:ok, _req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "ticket 91", org_id: org_a})

      # POSITIVE control: org_a sees its own pending request.
      assert [%{subject_id: ^s}] = Grants.pending_for_org(org_a, repo: @repo)

      # RED: org_b sees nothing of org_a's pending request. (Sabotage: dropping the
      # `org_filter` in `Samen.Approvals.list_pending/3` makes org_b see org_a's row → flips.)
      assert Grants.pending_for_org(org_b, repo: @repo) == []
    end
  end

  # ==========================================================================
  # approve — mints the grant AND records the approve-moment on the TENANT chain
  # ==========================================================================

  describe "approve records the granted event on the tenant audit chain (PP-13 / B6 residual)" do
    test "approve records the granted event on the tenant audit chain, org-attributed" do
      org_a = org()
      s = subj()
      requestor = actor()
      approver = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "ticket 92", org_id: org_a})

      {:ok, _grant} = Grants.approve(req, %{granted_by: approver, org_id: org_a})

      events = Samen.AuditChain.reveal_events_for_org(org_a, repo: @repo)

      # RED leg of the pin: the APPROVE moment ("granted") is now on the tenant chain — the
      # B6 residual (approve-audit written inline, never on the chain) is closed. Sabotage:
      # dropping the `org_id` on `do_approve/4`'s granted `write_audit` sends it to __global__
      # → this assertion flips (only the "requested" event would remain for org_a).
      assert Enum.any?(events, fn e ->
               e.actor_id == approver and e.subject_id == s and e.detail =~ "granted"
             end),
             "the approve-moment (granted) must appear on the tenant's reveal ledger"
    end

    test "a granted-off-chain would still leave the request event — the pin targets granted only" do
      # Positive control / anti-tautology: the REQUESTED event is on the tenant chain
      # regardless (Batch 6), so the sabotage's flip is specifically about the GRANTED event.
      org_a = org()
      s = subj()
      requestor = actor()

      {:ok, _req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "ticket 93", org_id: org_a})

      events = Samen.AuditChain.reveal_events_for_org(org_a, repo: @repo)
      assert Enum.any?(events, fn e -> e.actor_id == requestor and e.detail =~ "requested" end)
    end

    test "the minted grant lets the REQUESTOR (operator) unmask — the lifecycle completes" do
      org_a = org()
      s = subj()
      requestor = actor()
      approver = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "ticket 94", org_id: org_a})

      refute Grants.active?(requestor, s), "no grant before approval — mask holds"

      {:ok, _grant} = Grants.approve(req, %{granted_by: approver, org_id: org_a})

      assert Grants.active?(requestor, s), "after a distinct approval the requestor may reveal"
    end
  end

  # ==========================================================================
  # distinct-party — the requester cannot approve their own request
  # ==========================================================================

  describe "distinct-party: the requester cannot approve their own request" do
    test "a self-approval is refused with :self_approval and issues no grant" do
      org_a = org()
      s = subj()
      me = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: me, reason: "ticket 95", org_id: org_a})

      # RED: the requester approving their OWN request is refused at the policy layer
      # (and, if that were bypassed, by the engine policy + the DB CHECK). Sabotage: removing
      # BOTH policy-layer distinct-party checks makes the self-approval fall to the DB CHECK,
      # which returns a constraint error rather than :self_approval → this assertion flips.
      assert {:error, :self_approval} = Grants.approve(req, %{granted_by: me, org_id: org_a})

      grants = @repo.all(from(g in RevealGrant, where: g.subject_id == ^s))
      assert grants == [], "a refused self-approval mints no grant"
    end

    test "positive control: a DISTINCT approver both mints a grant and enables the reveal" do
      org_a = org()
      s = subj()
      requestor = actor()
      approver = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "ticket 96", org_id: org_a})

      assert {:ok, %RevealGrant{}} = Grants.approve(req, %{granted_by: approver, org_id: org_a})
      assert Grants.active?(requestor, s)
    end
  end

  # ==========================================================================
  # deny — rejects the approval (drops from pending), records the denial, mints nothing
  # ==========================================================================

  describe "deny/2" do
    test "deny rejects the pending approval (drops off pending), records a denial, mints NO grant" do
      org_a = org()
      s = subj()
      requestor = actor()
      denier = actor()

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: requestor, reason: "ticket 97", org_id: org_a})

      assert [_] = Grants.pending_for_org(org_a, repo: @repo)

      assert {:ok, _} = Grants.deny(req, %{denied_by: denier, org_id: org_a, repo: @repo})

      # It dropped off the pending queue (the approval transitioned pending -> rejected).
      assert Grants.pending_for_org(org_a, repo: @repo) == []

      # No grant was minted — the mask holds.
      refute Grants.active?(requestor, s)
      assert @repo.all(from(g in RevealGrant, where: g.subject_id == ^s)) == []

      # The denial is on the tenant reveal ledger.
      events = Samen.AuditChain.reveal_events_for_org(org_a, repo: @repo)
      assert Enum.any?(events, fn e -> e.actor_id == denier and e.detail =~ "denied" end)
    end
  end

  # ==========================================================================
  # S6 — a request whose engine approval failed to open is recovered by the queue read
  # ==========================================================================

  describe "orphaned request (its engine approval failed to open) — recovered by pending_for_org_result/2" do
    import ExUnit.CaptureLog

    alias Samen.Approvals
    alias Samen.Reveal.RevealRequest

    # File a request while the approvals read is broken: the request commits, its approval does not open.
    defp file_orphan(org_id, attrs \\ %{}) do
      previous = Application.get_env(:samen_core, Samen.Approvals)

      Application.put_env(:samen_core, Samen.Approvals,
        approval_resource: SamenCore.Support.UnreadableApproval,
        repo: @repo
      )

      try do
        capture_log(fn ->
          assert {:ok, req} =
                   Grants.request(
                     Map.merge(
                       %{subject_id: subj(), requestor_id: actor(), reason: "ticket 301: orphan", org_id: org_id},
                       attrs
                     )
                   )

          send(self(), {:orphan, req})
        end)
      after
        Application.put_env(:samen_core, Samen.Approvals, previous)
      end

      assert_received {:orphan, req}
      req
    end

    defp approvals_for(org_id, req) do
      {:ok, set} = Approvals.subject_refs_with_approval(org_id, "pii_reveal", [Samen.Reveal.ApprovalHandler.subject_ref(req)])
      MapSet.size(set)
    end

    test "the request persists the org its engine approval is filed under; a non-UUID org is NULL, never a failure" do
      org_a = org()
      {:ok, req} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 302", org_id: org_a})
      assert @repo.get!(RevealRequest, req.id).org_id == org_a

      {:ok, no_org} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 303"})
      assert @repo.get!(RevealRequest, no_org.id).org_id == nil

      log =
        capture_log(fn ->
          assert {:ok, bad} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 304", org_id: "not-a-uuid"})
          assert @repo.get!(RevealRequest, bad.id).org_id == nil
        end)

      # said at filing time, by name, with the value left out
      assert log =~ "write=reveal_request_org_uncastable"
      refute log =~ "not-a-uuid"
    end

    test "RED before the fix: an orphan is invisible to the queue; now the read re-opens it and the approver can APPROVE it end to end" do
      org_a = org()
      req = file_orphan(org_a)
      assert approvals_for(org_a, req) == 0, "the open failed: no approval exists"
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal")

      log = capture_log(fn -> assert {:ok, [_]} = Grants.pending_for_org_result(org_a, repo: @repo) end)
      assert log =~ "write=reveal_recover_engine_approval"
      assert approvals_for(org_a, req) == 1

      assert [row] = Grants.pending_for_org(org_a, repo: @repo)
      assert row.request_id == req.id and row.org_id == org_a

      approver = actor()
      assert {:ok, grant} = Grants.approve(row.request_id, %{granted_by: approver, org_id: org_a, repo: @repo})
      assert Grants.active?(req.requestor_id, req.subject_id)
      assert grant.request_id == req.id
      assert Grants.pending_for_org(org_a, repo: @repo) == []
    end

    test "the recovered request can be DENIED end to end, minting no grant" do
      org_a = org()
      req = file_orphan(org_a)
      capture_log(fn -> assert [_] = Grants.pending_for_org(org_a, repo: @repo) end)

      assert {:ok, _} = Grants.deny(req.id, %{denied_by: actor(), org_id: org_a, repo: @repo})
      assert Grants.pending_for_org(org_a, repo: @repo) == []
      refute Grants.active?(req.requestor_id, req.subject_id)
    end

    test "a healthy request is not reported as recovered (positive control: nothing to recover is silent)" do
      org_a = org()
      {:ok, _} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 305", org_id: org_a})
      quiet = capture_log(fn -> assert [_] = Grants.pending_for_org(org_a, repo: @repo) end)
      refute quiet =~ "reveal_recover_engine_approval"
    end

    test "RED: org A's queue read never re-opens or shows org B's orphan; org B's own read does (positive control)" do
      org_a = org()
      org_b = org()
      req_a = file_orphan(org_a)
      req_b = file_orphan(org_b)

      capture_log(fn ->
        assert [row_a] = Grants.pending_for_org(org_a, repo: @repo)
        assert row_a.request_id == req_a.id
      end)

      assert approvals_for(org_a, req_a) == 1
      # org A's read touched ONLY org A: B's orphan still has no approval anywhere
      assert approvals_for(org_b, req_b) == 0
      assert {:ok, []} = Approvals.list_pending(org_b, "pii_reveal")

      capture_log(fn -> assert [_] = Grants.pending_for_org(org_b, repo: @repo) end)
      assert approvals_for(org_b, req_b) == 1
      assert approvals_for(org_a, req_b) == 0
    end

    test "RED: a request that already has an approval in a TERMINAL state is never re-opened (approved, rejected, cancelled)" do
      org_a = org()

      for decide <- [:approve, :reject, :cancel] do
        {:ok, req} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 306 #{decide}", org_id: org_a})
        {:ok, [approval]} = Approvals.list_pending(org_a, "pii_reveal") |> then(fn {:ok, l} -> {:ok, Enum.filter(l, &(&1.subject_ref == Samen.Reveal.ApprovalHandler.subject_ref(req)))} end)

        case decide do
          :approve -> {:ok, _, _} = Approvals.approve(approval.id, actor())
          :reject -> {:ok, _} = Approvals.reject(approval.id, actor())
          :cancel -> {:ok, _} = Approvals.cancel(approval.id, req.requestor_id)
        end
      end

      quiet = capture_log(fn -> assert {:ok, []} = Grants.pending_for_org_result(org_a, repo: @repo) end)
      refute quiet =~ "reveal_recover_engine_approval"
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal")
    end

    test "a request older than the scan window is not re-opened (bounded look); a fresh one is" do
      org_a = org()
      old = file_orphan(org_a)
      fresh = file_orphan(org_a)
      stale_at = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      @repo.update_all(from(q in RevealRequest, where: q.id == ^old.id), set: [inserted_at: stale_at])

      capture_log(fn -> assert [_] = Grants.pending_for_org(org_a, repo: @repo) end)
      assert approvals_for(org_a, fresh) == 1
      assert approvals_for(org_a, old) == 0
    end

    test "the window edge is INCLUSIVE: a request filed exactly one window ago is still scanned, one microsecond older is not" do
      org_a = org()
      on_edge = file_orphan(org_a)
      past_edge = file_orphan(org_a)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      edge = DateTime.add(now, -14 * 86_400, :second)
      @repo.update_all(from(q in RevealRequest, where: q.id == ^on_edge.id), set: [inserted_at: edge])
      @repo.update_all(from(q in RevealRequest, where: q.id == ^past_edge.id), set: [inserted_at: DateTime.add(edge, -1, :microsecond)])

      capture_log(fn -> assert {:ok, [_]} = Grants.pending_for_org_result(org_a, repo: @repo, now: now) end)
      assert approvals_for(org_a, on_edge) == 1
      assert approvals_for(org_a, past_edge) == 0
    end

    test "the scan is limit-bounded: a full scan is reported as bounded and never reads past the limit" do
      org_a = org()
      limit = Grants.orphan_scan_limit()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows =
        for i <- 1..limit do
          %{
            rvq_id: Ecto.UUID.bingenerate(),
            rvq_subject_id: subj(),
            rvq_requestor_id: "bulk",
            rvq_reason: "ticket 307",
            rvq_status: "pending",
            rvq_org_id: Ecto.UUID.dump!(org_a),
            rvq_inserted_at: DateTime.add(now, -i, :second),
            rvq_updated_at: now
          }
        end

      @repo.insert_all("rvq_reveal_request", rows)
      extra = file_orphan(org_a)
      @repo.update_all(from(q in RevealRequest, where: q.id == ^extra.id), set: [inserted_at: DateTime.add(now, -(limit + 5), :second)])

      log = capture_log(fn -> assert {:ok, _} = Grants.pending_for_org_result(org_a, repo: @repo) end)
      assert log =~ "read=reveal_orphan_scan"
      assert log =~ "cause=bounded"
      # the request beyond the limit is NOT claimed seen
      assert approvals_for(org_a, extra) == 0
    end

    test "RED: repeated readers open ONE approval for the orphan, never a second (a second read finds the first's)" do
      org_a = org()
      req = file_orphan(org_a)

      capture_log(fn ->
        for _ <- 1..4, do: assert({:ok, [_]} = Grants.pending_for_org_result(org_a, repo: @repo))
      end)

      {:ok, pending} = Approvals.list_pending(org_a, "pii_reveal")
      assert length(pending) == 1
      assert approvals_for(org_a, req) == 1
    end

    test "RED: a reader whose scan went stale converges on the winner's ONE approval, claims no recovery, fails nothing" do
      org_a = org()
      req = file_orphan(org_a)

      # this reader's scan: it sees the request with no approval
      assert {:ok, [seen]} = Grants.orphan_candidates(org_a, @repo, [])
      assert seen.id == req.id

      # the other reader opens the approval AFTER that scan and BEFORE this reader's re-open
      assert {:ok, _} =
               Approvals.request(%{
                 org_id: org_a,
                 kind: "pii_reveal",
                 subject_ref: Samen.Reveal.ApprovalHandler.subject_ref(req),
                 requested_by: req.requestor_id
               })

      log = capture_log(fn -> assert Grants.reopen_orphan(seen, org_a, @repo, []) == :skipped end)

      # the loser's re-open found the winner's approval: it neither failed, nor opened a second one, nor claimed a recovery
      refute log =~ "reveal_open_engine_approval"
      refute log =~ "reveal_recover_engine_approval"
      {:ok, pending} = Approvals.list_pending(org_a, "pii_reveal")
      assert length(pending) == 1
      assert approvals_for(org_a, req) == 1
    end

    test "RED: a request DECIDED between the scan and the re-open gets no second approval (re-checked under the row lock)" do
      org_a = org()
      req = file_orphan(org_a)

      assert {:ok, [seen]} = Grants.orphan_candidates(org_a, @repo, [])

      # decided AFTER the scan read it (an approver tab, or the original open landing late and then approved)
      assert {:ok, grant} = Grants.approve(req.id, %{granted_by: actor(), org_id: org_a, repo: @repo})
      assert @repo.get!(RevealRequest, req.id).status == "approved"
      assert approvals_for(org_a, req) == 1

      log = capture_log(fn -> assert Grants.reopen_orphan(seen, org_a, @repo, []) == :skipped end)

      refute log =~ "reveal_recover_engine_approval"
      # no second pending approval to approve into a second grant
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal")
      assert approvals_for(org_a, req) == 1
      assert [_one] = @repo.all(from(g in RevealGrant, where: g.request_id == ^grant.request_id))
    end

    test "RED: a request decided with NO approval row (engine-less path) is not re-opened: its own status says decided" do
      org_a = org()
      req = file_orphan(org_a)
      assert {:ok, [seen]} = Grants.orphan_candidates(org_a, @repo, [])

      # an unwired host decided it: a grant and `approved`, but no approval was ever written
      assert {:ok, _grant} = Grants.do_approve(@repo.get!(RevealRequest, req.id), actor(), %{org_id: org_a}, @repo)
      assert approvals_for(org_a, req) == 0
      assert @repo.get!(RevealRequest, req.id).status == "approved"

      capture_log(fn -> assert Grants.reopen_orphan(seen, org_a, @repo, []) == :skipped end)
      assert approvals_for(org_a, req) == 0

      # and a later queue read does not revive it (the scan selects pending requests only)
      assert {:ok, []} = Grants.pending_for_org_result(org_a, repo: @repo)
      assert approvals_for(org_a, req) == 0
    end

    test "RED: a LEGACY request (approval decided, status still pending) is not re-opened: the re-open checks approvals in any state" do
      org_a = org()
      {:ok, req} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 314", org_id: org_a})
      assert {:ok, _} = Grants.approve(req.id, %{granted_by: actor(), org_id: org_a, repo: @repo})

      # a row from before the status was written: the approval says decided, the request says pending
      @repo.update_all(from(q in RevealRequest, where: q.id == ^req.id), set: [status: "pending"])
      assert approvals_for(org_a, req) == 1

      capture_log(fn -> assert Grants.reopen_orphan(@repo.get!(RevealRequest, req.id), org_a, @repo, []) == :skipped end)
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal")
      assert approvals_for(org_a, req) == 1
    end

    test "RED: a decision filed in ANOTHER lane (no org) still decides the request; org A's queue never re-opens it" do
      org_a = org()
      req = file_orphan(org_a)

      # approved with no org_id: the approval lands in the plane-global lane, outside org A's approvals
      assert {:ok, _grant} = Grants.approve(req.id, %{granted_by: actor(), repo: @repo})
      assert approvals_for(org_a, req) == 0
      assert @repo.get!(RevealRequest, req.id).status == "approved"

      quiet = capture_log(fn -> assert {:ok, []} = Grants.pending_for_org_result(org_a, repo: @repo) end)
      refute quiet =~ "reveal_recover_engine_approval"
      assert approvals_for(org_a, req) == 0
    end

    test "RED: a second approval of an already-approved request is refused and mints no second grant" do
      org_a = org()
      {:ok, req} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 311", org_id: org_a})

      assert {:ok, _} = Grants.approve(req.id, %{granted_by: actor(), org_id: org_a, repo: @repo})
      assert {:error, :not_pending} = Grants.approve(req.id, %{granted_by: actor(), org_id: org_a, repo: @repo})
      assert {:error, :not_pending} = Grants.deny(req.id, %{denied_by: actor(), org_id: org_a, repo: @repo})

      assert [_one] = @repo.all(from(g in RevealGrant, where: g.request_id == ^req.id))
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal")
    end

    test "RED: a stray pending approval of a decided request (data from before the status was written) cannot be approved into a second grant" do
      org_a = org()
      {:ok, req} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 315", org_id: org_a})
      assert {:ok, _} = Grants.approve(req.id, %{granted_by: actor(), org_id: org_a, repo: @repo})

      # an approval opened on top of the decided request, the way the old recovery did
      assert {:ok, stray} =
               Approvals.request(%{
                 org_id: org_a,
                 kind: "pii_reveal",
                 subject_ref: Samen.Reveal.ApprovalHandler.subject_ref(req),
                 requested_by: req.requestor_id
               })

      assert {:error, :not_pending} = Approvals.approve(stray.id, actor())
      assert [_one] = @repo.all(from(g in RevealGrant, where: g.request_id == ^req.id))
      # the refused approval rolled back with everything else: it is still pending, and a reject cannot overwrite the decision
      assert {:ok, _} = Approvals.reject(stray.id, actor())
      assert @repo.get!(RevealRequest, req.id).status == "approved"
    end

    test "every path that decides a reveal request writes its terminal status on the request itself" do
      org_a = org()
      new = fn tag -> elem(Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 312 #{tag}", org_id: org_a}), 1) end
      status = fn req -> @repo.get!(RevealRequest, req.id).status end
      pending_approval = fn req -> hd(Enum.filter(elem(Approvals.list_pending(org_a, "pii_reveal"), 1), &(&1.subject_ref == Samen.Reveal.ApprovalHandler.subject_ref(req)))) end

      via_grants_approve = new.("grants approve")
      assert status.(via_grants_approve) == "pending"
      {:ok, _} = Grants.approve(via_grants_approve.id, %{granted_by: actor(), org_id: org_a, repo: @repo})
      assert status.(via_grants_approve) == "approved"

      via_grants_deny = new.("grants deny")
      {:ok, _} = Grants.deny(via_grants_deny.id, %{denied_by: actor(), org_id: org_a, repo: @repo})
      assert status.(via_grants_deny) == "denied"

      via_engine_approve = new.("engine approve")
      {:ok, _, _} = Approvals.approve(pending_approval.(via_engine_approve).id, actor())
      assert status.(via_engine_approve) == "approved"

      via_engine_reject = new.("engine reject")
      {:ok, _} = Approvals.reject(pending_approval.(via_engine_reject).id, actor())
      assert status.(via_engine_reject) == "denied"

      via_engine_cancel = new.("engine cancel")
      {:ok, _} = Approvals.cancel(pending_approval.(via_engine_cancel).id, via_engine_cancel.requestor_id)
      assert status.(via_engine_cancel) == "cancelled"

      # an unwired host: no engine, so the request row alone carries the decision
      previous = Application.get_env(:samen_core, Samen.Approvals)
      Application.put_env(:samen_core, Samen.Approvals, [])

      try do
        engineless_approve = new.("engineless approve")
        {:ok, _} = Grants.approve(engineless_approve.id, %{granted_by: actor(), repo: @repo})
        assert status.(engineless_approve) == "approved"

        engineless_deny = new.("engineless deny")
        {:ok, _} = Grants.deny(engineless_deny.id, %{denied_by: actor(), repo: @repo})
        assert status.(engineless_deny) == "denied"
      after
        Application.put_env(:samen_core, Samen.Approvals, previous)
      end

      # a refused decision decides nothing: the request stays pending (positive control for the writes above)
      refused = new.("self approve")
      assert {:error, :self_approval} = Grants.approve(refused.id, %{granted_by: refused.requestor_id, org_id: org_a, repo: @repo})
      assert {:error, :self_approval} = Grants.deny(refused.id, %{denied_by: refused.requestor_id, org_id: org_a, repo: @repo})
      assert status.(refused) == "pending"
    end

    test "the scan bound is not spent on DECIDED requests: an orphan behind 200 newer decided ones is recovered, no bounded report" do
      org_a = org()
      limit = Grants.orphan_scan_limit()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows =
        for i <- 1..limit do
          %{
            rvq_id: Ecto.UUID.bingenerate(),
            rvq_subject_id: subj(),
            rvq_requestor_id: "bulk",
            rvq_reason: "ticket 313",
            rvq_status: Enum.at(["approved", "denied", "cancelled"], rem(i, 3)),
            rvq_org_id: Ecto.UUID.dump!(org_a),
            rvq_inserted_at: DateTime.add(now, -i, :second),
            rvq_updated_at: now
          }
        end

      @repo.insert_all("rvq_reveal_request", rows)
      orphan = file_orphan(org_a)
      @repo.update_all(from(q in RevealRequest, where: q.id == ^orphan.id), set: [inserted_at: DateTime.add(now, -(limit + 5), :second)])

      log = capture_log(fn -> assert {:ok, [_]} = Grants.pending_for_org_result(org_a, repo: @repo) end)
      refute log =~ "cause=bounded"
      assert approvals_for(org_a, orphan) == 1
    end

    test "a recovered approval keeps the request's own filing time and queue position" do
      org_a = org()
      req = file_orphan(org_a)
      filed = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second) |> DateTime.truncate(:microsecond)
      @repo.update_all(from(q in RevealRequest, where: q.id == ^req.id), set: [inserted_at: filed])
      newer = file_orphan(org_a)

      {[first, second], _log} =
        with_log(fn ->
          assert {:ok, [_, _] = rows} = Grants.pending_for_org_result(org_a, repo: @repo)
          rows
        end)

      assert first.request_id == req.id, "the older request is first in the oldest-first queue"
      assert first.requested_at == filed
      assert second.request_id == newer.id
    end

    test "RED: a failed re-open is reported AND the queue says it is partial; healed, the next read recovers it" do
      org_a = org()
      {:ok, healthy} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 308", org_id: org_a})
      orphan = file_orphan(org_a)

      registry = Application.get_env(:samen_core, Samen.Approvals.Registry)
      Application.put_env(:samen_core, Samen.Approvals.Registry, kinds: %{})

      log =
        try do
          capture_log(fn ->
            assert {:partial, [row], 1} = Grants.pending_for_org_result(org_a, repo: @repo)
            assert row.request_id == healthy.id
            # the raising list variant never hands back a list it knows is incomplete
            assert_raise RuntimeError, ~r/could not be surfaced/, fn -> Grants.pending_for_org(org_a, repo: @repo) end
          end)
        after
          Application.put_env(:samen_core, Samen.Approvals.Registry, registry)
        end

      assert log =~ "write=reveal_open_engine_approval"
      refute log =~ "reveal_recover_engine_approval"
      assert approvals_for(org_a, orphan) == 0

      capture_log(fn -> assert {:ok, [_, _]} = Grants.pending_for_org_result(org_a, repo: @repo) end)
      assert approvals_for(org_a, orphan) == 1
    end

    test "RED: an orphan scan that cannot read the approvals is {:error, :unavailable} while the pending list is HEALTHY" do
      org_a = org()
      _orphan = file_orphan(org_a)

      # POSITIVE CONTROL (same wiring, same org): the pending LIST itself reads fine through this resource, so only the
      # scan's column-projected read is down
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal", approval_resource: SamenCore.Support.ScanFaultApproval)
      assert {:ok, []} = Approvals.list_pending(org_a, "pii_reveal")

      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Grants.pending_for_org_result(org_a, repo: @repo, approval_resource: SamenCore.Support.ScanFaultApproval)
        end)

      assert log =~ "read=reveal_orphan_scan"
      # the same org on the healthy engine answers (and recovers the orphan)
      capture_log(fn -> assert {:ok, [_]} = Grants.pending_for_org_result(org_a, repo: @repo) end)
    end

    test "RED: an orphan scan whose request read RAISES is {:error, :unavailable} while the pending list is healthy" do
      org_a = org()
      _orphan = file_orphan(org_a)
      Samen.FaultRepo.fail([:all])

      try do
        log =
          capture_log(fn ->
            assert {:error, :unavailable} = Grants.pending_for_org_result(org_a, repo: Samen.FaultRepo)
          end)

        assert log =~ "read=reveal_orphan_scan"
      after
        Samen.FaultRepo.heal()
      end

      capture_log(fn -> assert {:ok, [_]} = Grants.pending_for_org_result(org_a, repo: @repo) end)
    end

    test "a request with no org and no approval is NAMED (never given a guessed org); a no-org request WITH a global approval is not" do
      {:ok, with_approval} = Grants.request(%{subject_id: subj(), requestor_id: actor(), reason: "ticket 310 a"})
      unopened = file_orphan(nil, %{reason: "ticket 310 b"})
      # DECIDED for real (an unwired host's approve: a grant and `approved`, no approval row), not a hand-set status
      closed = file_orphan(nil, %{reason: "ticket 310 c"})
      {:ok, _} = Grants.do_approve(@repo.get!(RevealRequest, closed.id), actor(), %{}, @repo)
      assert @repo.get!(RevealRequest, closed.id).status == "approved"
      assert approvals_for(nil, closed) == 0
      attributed = file_orphan(org(), %{reason: "ticket 310 d"})
      {:ok, ids} = Grants.unattributed_requests(repo: @repo)

      # only a NO-org AND still-pending request counts: an org-bearing orphan is the queue's to recover, a decided one is done
      refute to_string(attributed.id) in ids
      refute to_string(closed.id) in ids

      assert to_string(unopened.id) in ids
      refute to_string(with_approval.id) in ids
      assert @repo.get!(RevealRequest, unopened.id).org_id == nil

      # the NOTE task prints it, exit 0
      out = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Samen.Verify.RevealOrgs.run([]) end)
      assert out =~ "NOTE"
      assert out =~ to_string(unopened.id)
    end
  end
end
