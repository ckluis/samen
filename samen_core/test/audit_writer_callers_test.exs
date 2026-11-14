defmodule Samen.AuditWriterCallersTest do
  @moduledoc """
  `Samen.AuditChain.Writer.write/2` is atomic (an `aud_event` never commits without its chain entry) and returns
  `{:error, _}` when it cannot be. The callers that GRANT or OPEN something propagate that error and fail closed:
  impersonation open, reveal request, reveal grant, approval request / decide / cancel. Callers that REMOVE access
  (revoke, expiry, denials) and the best-effort archival sink report it and never depend on it.

  Faults are real `DBConnection.ConnectionError`s from `Samen.FaultRepo` (`:probe` = the chain existence probe).
  Every refusal is paired with a positive control through the same call.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Samen.AuditChain.Writer
  alias Samen.{Approvals, FaultRepo}
  alias Samen.Reveal.{Grants, RevealGrant, RevealRequest}
  alias Samen.Impersonation.Session

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    FaultRepo.heal()
    on_exit(&FaultRepo.heal/0)
    :ok
  end

  defp events(subject) do
    @repo.aggregate(from(e in Samen.AuditEvent, where: e.subject_id == ^subject), :count)
  end

  defp attrs(subject, extra \\ %{}) do
    Map.merge(
      %{
        org_id: Ecto.UUID.generate(),
        event_type: "system",
        subject_id: subject,
        actor_id: "actor",
        detail: "event=test",
        occurred_at: DateTime.utc_now()
      },
      extra
    )
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "Writer.write/2 atomicity" do
    test "a chain append that fails AFTER the event insert leaves no chainless aud_event (outside a transaction)" do
      subject = uniq("sub-nokey")
      refute @repo.in_transaction?()

      # a subject payload whose key does not exist: the chain append refuses after `aud_event` was inserted
      assert {:error, {:subject_key_unavailable, _}} =
               Writer.write(@repo, attrs(subject, %{subject_payload: "secret"}))

      assert events(subject) == 0
    end

    test "positive control: without the failing payload the event AND its chain entry commit" do
      subject = uniq("sub-ok")
      assert {:ok, %{aud_event: _, chain: %Samen.AuditChain.Entry{}}} = Writer.write(@repo, attrs(subject))
      assert events(subject) == 1
    end

    test "an unavailable chain writes nothing, inside a caller's transaction too, and does not poison it" do
      subject = uniq("sub-down")
      FaultRepo.fail([:probe])

      capture_log(fn ->
        assert {:ok, :survived} =
                 @repo.transaction(fn ->
                   assert {:error, :audit_chain_unavailable} = Writer.write(FaultRepo, attrs(subject))
                   # the tolerant caller's own transaction is still usable
                   assert events(subject) == 0
                   :survived
                 end)
      end)

      assert events(subject) == 0
    end

    test "inside a caller's transaction a chain failure is the CALLER's rollback to take" do
      subject = uniq("sub-nested")

      assert {:error, :caller_rolled_back} =
               @repo.transaction(fn ->
                 assert {:error, {:subject_key_unavailable, _}} =
                          Writer.write(@repo, attrs(subject, %{subject_payload: "secret"}))

                 @repo.rollback(:caller_rolled_back)
               end)

      assert events(subject) == 0
    end
  end

  describe "impersonation open fails closed" do
    test "audit down: no session, no committed anything; audit up: the session opens" do
      op = uniq("op")
      org = Ecto.UUID.generate()
      args = %{operator_id: op, org_id: org, reason: "billing dispute", repo: FaultRepo}

      FaultRepo.fail([:probe])
      capture_log(fn -> assert {:error, :audit_unavailable} = Samen.Impersonation.Sessions.open(args) end)
      FaultRepo.heal()
      assert @repo.aggregate(from(s in Session, where: s.operator_id == ^op), :count) == 0

      assert {:ok, %Session{}} = Samen.Impersonation.Sessions.open(args)
      assert @repo.aggregate(from(s in Session, where: s.operator_id == ^op), :count) == 1
    end
  end

  describe "reveal request / grant fail closed" do
    test "request: audit down → no request row; audit up → recorded and audited" do
      subject = uniq("sub-req")
      attrs = %{subject_id: subject, requestor_id: uniq("req"), reason: "support case 42", repo: FaultRepo}

      FaultRepo.fail([:probe])
      capture_log(fn -> assert {:error, :audit_chain_unavailable} = Grants.request(attrs) end)
      FaultRepo.heal()
      assert @repo.aggregate(from(r in RevealRequest, where: r.subject_id == ^subject), :count) == 0

      assert {:ok, %RevealRequest{}} = Grants.request(attrs)
      assert @repo.aggregate(from(r in RevealRequest, where: r.subject_id == ^subject), :count) == 1
    end

    test "grant: audit down → no grant; audit up → the grant lands" do
      subject = uniq("sub-grant")
      {:ok, req} = Grants.request(%{subject_id: subject, requestor_id: uniq("req"), reason: "support case 43"})
      approver = uniq("appr")

      FaultRepo.fail([:probe])

      capture_log(fn ->
        assert {:error, :audit_chain_unavailable} = Grants.do_approve(req, approver, %{}, FaultRepo)
      end)

      FaultRepo.heal()
      assert @repo.aggregate(from(g in RevealGrant, where: g.subject_id == ^subject), :count) == 0

      assert {:ok, %RevealGrant{}} = Grants.do_approve(req, approver, %{}, FaultRepo)
      assert @repo.aggregate(from(g in RevealGrant, where: g.subject_id == ^subject), :count) == 1
    end

    test "revoke REMOVES access: it stands when the audit is down (reported, not undone)" do
      subject = uniq("sub-revoke")
      {:ok, req} = Grants.request(%{subject_id: subject, requestor_id: uniq("req"), reason: "support case 44"})
      {:ok, grant} = Grants.do_approve(req, uniq("appr"), %{}, @repo)

      FaultRepo.fail([:probe])
      capture_log(fn ->
        assert {:ok, %RevealGrant{revoked_at: %DateTime{}}} = Grants.revoke(grant.id, %{repo: FaultRepo})
      end)

      FaultRepo.heal()
      assert %RevealGrant{revoked_at: %DateTime{}} = @repo.get(RevealGrant, grant.id)
    end
  end

  describe "approvals fail closed" do
    @kind "pii_reveal"

    defp approval_attrs, do: %{org_id: Ecto.UUID.generate(), kind: @kind, subject_ref: "samen:t.r:#{uniq("x")}", requested_by: uniq("rq")}

    test "request: audit down → no approval; audit up → opened" do
      a = approval_attrs()
      FaultRepo.fail([:probe])
      capture_log(fn -> assert {:error, :request_failed} = Approvals.request(a, repo: FaultRepo) end)
      FaultRepo.heal()
      assert {:ok, %{state: :pending}} = Approvals.request(a, repo: FaultRepo)
    end

    test "cancel: audit down → still pending; audit up → cancelled" do
      {:ok, approval} = Approvals.request(approval_attrs())
      FaultRepo.fail([:probe])
      capture_log(fn -> assert {:error, {:audit_failed, _}} = Approvals.cancel(approval.id, "rq", repo: FaultRepo) end)
      FaultRepo.heal()
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert {:ok, %{state: :cancelled}} = Approvals.cancel(approval.id, "rq", repo: FaultRepo)
    end
  end
end
