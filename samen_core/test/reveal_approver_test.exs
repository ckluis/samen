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
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
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
end
