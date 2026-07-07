defmodule Samen.PiiReasonScanTest do
  @moduledoc """
  F4.3 — reason/detail free-text shred honesty. The operator-authored `reason` on
  impersonation sessions and reveal requests, and the `detail` on audit-chain entries, is
  a NON-shreddable plaintext channel (ADR-002 §2.5). The fail-closed belt is a value-shape
  scan that REJECTS a bare email/SSN/phone-shaped reason at the write boundary.

  Red paths here:
    * a PII-shaped reason is REJECTED at `Sessions.open/1`, `Grants.request/1`, and
      `AuditChain.Writer.write/2` — before any row lands;
  Anti-tautology probe:
    * a NORMAL reason (with the same internal spaces a real reason has) PASSES on every
      path — so "rejected" is the value-shape gate firing on the PII shape, not a blanket
      refusal of free text.
  """
  use ExUnit.Case, async: false

  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias Samen.PiiReasonScan
  alias Samen.Reveal.Grants

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp operator, do: Actor.new("operator-#{System.unique_integer([:positive])}", :operator_support)
  defp org_id, do: Ecto.UUID.generate()

  # A reason with the internal spaces every real reason has — the anti-tautology control.
  @normal_reason "customer #1234 reported a billing error"

  # ==========================================================================
  # Unit: the scan itself (email/SSN/phone rejected; names + prose pass)
  # ==========================================================================

  describe "PiiReasonScan.scan/1 + check/2" do
    test "flags a bare email / SSN / phone value shape" do
      assert {:pii_shaped, :email} = PiiReasonScan.scan("jane.doe@example.com")
      assert {:pii_shaped, :ssn} = PiiReasonScan.scan("123-45-6789")
      assert {:pii_shaped, :phone} = PiiReasonScan.scan("+1-800-555-1234")
    end

    test "does NOT flag a normal reason (internal spaces) — names are not gated here" do
      assert :ok = PiiReasonScan.scan(@normal_reason)
      # A space-separated name is intentionally NOT rejected (ordinary reasons have spaces).
      assert :ok = PiiReasonScan.scan("spoke with Jane Doe about ticket 5")
      assert :ok = PiiReasonScan.scan(nil)
      assert :ok = PiiReasonScan.scan("")
    end

    test "check/2 returns a clear error tuple for a PII-shaped reason" do
      assert {:error, {:pii_shaped_reason, :email}} = PiiReasonScan.check("x@y.co")
      assert :ok = PiiReasonScan.check(@normal_reason)
    end
  end

  # ==========================================================================
  # RED PATH: impersonation reason rejected (F4.3)
  # ==========================================================================

  describe "Impersonation.open/3 rejects a PII-shaped reason (red path)" do
    test "a PII-shaped reason is REFUSED before any DB write" do
      op = operator()
      org = org_id()

      assert {:error, {:pii_shaped_reason, :email}} =
               Impersonation.open(op, org, "jane.doe@acme.com")

      # Nothing landed — no active session, no aud_event.
      refute Impersonation.active?(op, org)
      assert Samen.AuditEvent.for_subject(@repo, org) == []
    end

    test "ANTI-TAUTOLOGY: the SAME path with a normal reason SUCCEEDS" do
      op = operator()
      org = org_id()

      assert {:ok, session} = Impersonation.open(op, org, @normal_reason)
      assert session.reason == @normal_reason
      assert Impersonation.active?(op, org)
    end
  end

  # ==========================================================================
  # RED PATH: reveal-request reason rejected (F4.3)
  # ==========================================================================

  describe "Grants.request/1 rejects a PII-shaped reason (red path)" do
    test "a PII-shaped reason is REFUSED before any request row lands" do
      subject = Ecto.UUID.generate()

      assert {:error, {:pii_shaped_reason, :ssn}} =
               Grants.request(%{
                 subject_id: subject,
                 requestor_id: "op-1",
                 reason: "123-45-6789",
                 repo: @repo
               })

      # No requested audit row for this subject.
      assert Samen.AuditEvent.for_subject(@repo, subject) == []
    end

    test "ANTI-TAUTOLOGY: a normal reason files the request" do
      subject = Ecto.UUID.generate()

      assert {:ok, req} =
               Grants.request(%{
                 subject_id: subject,
                 requestor_id: "op-1",
                 reason: @normal_reason,
                 repo: @repo
               })

      assert req.reason == @normal_reason
    end
  end

  # ==========================================================================
  # RED PATH: audit-chain detail rejected (F4.3)
  # ==========================================================================

  describe "AuditChain.Writer.write/2 rejects a bare PII-shaped detail (red path)" do
    test "a bare email-shaped detail is REFUSED; a composed/normal detail writes" do
      org = org_id()

      assert {:error, {:pii_shaped_reason, :email}} =
               Samen.AuditChain.Writer.write(@repo, %{
                 org_id: org,
                 event_type: "system",
                 subject_id: org,
                 actor_id: "op-1",
                 correlation_id: Ecto.UUID.generate(),
                 detail: "person@example.com",
                 occurred_at: DateTime.utc_now()
               })

      # ANTI-TAUTOLOGY: a composed/normal detail (not a bare value shape) writes fine.
      assert {:ok, _} =
               Samen.AuditChain.Writer.write(@repo, %{
                 org_id: org,
                 event_type: "system",
                 subject_id: org,
                 actor_id: "op-1",
                 correlation_id: Ecto.UUID.generate(),
                 detail: "event=open reason=#{@normal_reason}",
                 occurred_at: DateTime.utc_now()
               })
    end
  end
end
