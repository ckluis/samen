defmodule Samen.Approvals.EngineTest do
  @moduledoc """
  T34 — the E3 generalized approve/reject engine (ADR-040 §4; spec §E3). Exercised against
  a REAL Postgres DB via the `apv`/`apd` `SamenCore.Support.ApprovalsFixture` mount. Every
  guarantee pairs a green path with a discriminating/red twin (`Samen.RedPath`
  anti-tautology discipline). Covers the handoff done-criteria + the ADR §10 T34 duties:

    * c1 approve-executes-once / reject-never / pending-neither (on TWO gated action types);
    * c2 requester≠approver: `:self_approval` at the POLICY layer AND the `apv_distinct_party`
      DB CHECK, with a distinct-party positive control;
    * c3 org-scope cross-org read denied (both directions + the NULL-org governance row),
      decisions audited;
    * c4 the generic Gate hook proven on two different gated action types + the Face-1
      handler-registry path (the shape reveal adopts in T35) incl. the same-tx rollback;
    * exactly-once double-approve (machine guard); no-persisted-inputs / INV-1;
    * expiry AshOban trigger + job-args sink (`actor_persister :none`, ID-only args).
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Samen.Approvals
  alias SamenCore.Support.ApprovalsFixture.{Approval, Document}
  alias Samen.AuditEvent, as: AuditEvent

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp org, do: Ecto.UUID.generate()

  defp actor(org_id, role \\ :member),
    do: Samen.Scope.new(%{id: Ecto.UUID.generate(), org_id: org_id, role: role}).actor

  defp document(org_id, opts \\ []) do
    Samen.Factory.create!(
      Document,
      %{
        org_id: org_id,
        title: Keyword.get(opts, :title, "Doc"),
        secret: Keyword.get(opts, :secret, "ordinary")
      },
      authorize?: false
    )
  end

  defp reload(doc), do: Ash.get!(Document, doc.id, authorize?: false)

  # Invoke a Gate-guarded action as `actor`; returns {:approval_required, id} or {:ok, doc}.
  defp gated(doc, action, actor) do
    doc
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, error} ->
        {:approval_required, approval_id_from(error)}
    end
  end

  defp approval_id_from(error) do
    error
    |> Map.get(:errors, [])
    |> Enum.find_value(fn
      %Samen.Approvals.ApprovalRequired{approval_id: id} -> id
      _ -> nil
    end)
  end

  defp audit_events(approval_id, event_type) do
    @repo.all(
      from(a in AuditEvent,
        where: a.correlation_id == ^approval_id and a.event_type == ^event_type,
        select: a.event_type
      )
    )
  end

  # ==========================================================================
  # c1 + c4 — request → approve executes the gated action EXACTLY ONCE, as the requester.
  # ==========================================================================

  test "c1/c4 publish: request opens a pending approval (write aborted); a distinct approval executes it once, AS THE REQUESTER" do
    o = org()
    requester = actor(o, :member)
    doc = document(o, title: "Publish me")

    # 1. Requester invokes the gated action → write is refused, a pending approval opens.
    assert {:approval_required, approval_id} = gated(doc, :publish, requester)
    assert is_binary(approval_id)

    # pending-NEITHER: the document is untouched while the approval is pending.
    assert reload(doc).status == :draft
    assert reload(doc).published_by == nil

    # 2. A DISTINCT approver decides. The generic Gate handler re-invokes :publish as the
    #    REQUESTER inside the decision transaction.
    approver = Ecto.UUID.generate()
    assert {:ok, approved, meta} = Approvals.approve(approval_id, approver)
    assert approved.state == :approved
    assert approved.decided_by == approver
    assert meta.executed == "publish"

    # 3. Executed exactly once, AS THE REQUESTER (published_by == requester, NEVER approver).
    published = reload(doc)
    assert published.status == :published
    assert published.published_by == requester.id
    refute published.published_by == approver

    # Decisions are audited (governance tier).
    assert audit_events(approval_id, "approval_approved") == ["approval_approved"]
    assert audit_events(approval_id, "approval_requested") == ["approval_requested"]
  end

  test "c4 lock: a DIFFERENT gated action type flows through the same engine" do
    o = org()
    requester = actor(o, :member)
    doc = document(o)

    assert {:approval_required, approval_id} = gated(doc, :lock, requester)
    assert reload(doc).status == :draft

    assert {:ok, _approved, meta} = Approvals.approve(approval_id, Ecto.UUID.generate())
    assert meta.executed == "lock"

    locked = reload(doc)
    assert locked.status == :locked
    assert locked.locked_by == requester.id
  end

  test "c1 reject NEVER executes the gated action (red), a control approval does (positive)" do
    o = org()
    requester = actor(o, :member)

    # RED: rejected → the document is never published.
    doc = document(o)
    assert {:approval_required, approval_id} = gated(doc, :publish, requester)
    assert {:ok, rejected} = Approvals.reject(approval_id, Ecto.UUID.generate())
    assert rejected.state == :rejected
    assert reload(doc).status == :draft
    assert reload(doc).published_by == nil
    assert audit_events(approval_id, "approval_rejected") == ["approval_rejected"]

    # CONTROL: an approved sibling IS published (the reject-never check is not vacuous).
    doc2 = document(o)
    assert {:approval_required, id2} = gated(doc2, :publish, requester)
    assert {:ok, _, _} = Approvals.approve(id2, Ecto.UUID.generate())
    assert reload(doc2).status == :published
  end

  test "exactly-once: a second approve on a decided approval is refused (machine guard); the handler runs once" do
    o = org()
    requester = actor(o, :member)
    doc = document(o)

    {:approval_required, approval_id} = gated(doc, :publish, requester)
    assert {:ok, _, _} = Approvals.approve(approval_id, Ecto.UUID.generate())
    assert reload(doc).status == :published

    # Second decide hits a non-pending row → refused (AshStateMachine NoMatchingTransition
    # underlies the engine's :not_pending). The gated action does NOT run a second time.
    assert {:error, :not_pending} = Approvals.approve(approval_id, Ecto.UUID.generate())
    assert {:error, :not_pending} = Approvals.reject(approval_id, Ecto.UUID.generate())
    assert audit_events(approval_id, "approval_approved") == ["approval_approved"]
  end

  test "idempotent request: re-invoking the gated action returns the SAME pending approval" do
    o = org()
    requester = actor(o, :member)
    doc = document(o)

    {:approval_required, id1} = gated(doc, :publish, requester)
    {:approval_required, id2} = gated(doc, :publish, requester)
    assert id1 == id2
  end

  # ==========================================================================
  # c2 — requester ≠ approver: policy layer + DB CHECK (both, with a positive control).
  # ==========================================================================

  test "c2 POLICY: self-approval (decided_by == requested_by) is refused with :self_approval; the approval stays pending + a refusal is audited" do
    o = org()
    requester = actor(o, :member)
    doc = document(o)

    {:approval_required, approval_id} = gated(doc, :publish, requester)

    # The requester tries to approve their own request (decided_by == requested_by).
    assert {:error, :self_approval} = Approvals.approve(approval_id, requester.id)

    {:ok, still} = Approvals.get(approval_id)
    assert still.state == :pending
    assert still.decided_by == nil
    assert reload(doc).status == :draft
    assert audit_events(approval_id, "approval_self_decide_refused") == ["approval_self_decide_refused"]

    # POSITIVE CONTROL: a distinct approver succeeds (the refusal is not vacuous).
    assert {:ok, approved, _} = Approvals.approve(approval_id, Ecto.UUID.generate())
    assert approved.state == :approved
  end

  test "c2 DB CHECK: a raw insert with apv_decided_by == apv_requested_by raises apv_distinct_party (bypass-proof); a distinct-party row inserts" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    same = "same-party-#{System.unique_integer([:positive])}"

    # RED: raw SQL — no application code, no changeset. Postgres rejects self-approval.
    assert_raise Postgrex.Error, ~r/apv_distinct_party/, fn ->
      @repo.query!(
        """
        INSERT INTO apv_approval
          (apv_id, apv_kind, apv_subject_ref, apv_requested_by, apv_decided_by,
           apv_state, apv_inserted_at, apv_updated_at)
        VALUES (gen_random_uuid(), 'k', 's', $1, $1, 'approved', $2, $2)
        """,
        [same, now]
      )
    end

    # CONTROL: a DISTINCT-party direct insert SUCCEEDS (the CHECK only blocks self-approval).
    assert %{num_rows: 1} =
             @repo.query!(
               """
               INSERT INTO apv_approval
                 (apv_id, apv_kind, apv_subject_ref, apv_requested_by, apv_decided_by,
                  apv_state, apv_inserted_at, apv_updated_at)
               VALUES (gen_random_uuid(), 'k', 's', $1, $2, 'approved', $3, $3)
               """,
               ["requester-x", "approver-y", now]
             )
  end

  # ==========================================================================
  # T34-F1 — null approver must NOT produce a single-party decision (two-layer closure).
  # ==========================================================================

  test "null approver: approve(id, nil) is REFUSED (approver identity mandatory); the gated action does NOT execute; a distinct approver is the positive control" do
    o = org()
    requester = actor(o, :member)
    doc = document(o)

    {:approval_required, approval_id} = gated(doc, :publish, requester)

    # POLICY LAYER (T34-F1): a nil/blank approver is a single-party decision — fail-closed.
    assert {:error, :no_approver} = Approvals.approve(approval_id, nil)
    assert {:error, :no_approver} = Approvals.approve(approval_id, "")
    assert {:error, :no_approver} = Approvals.approve(approval_id, "   ")
    # reject is symmetric — a null approver cannot reject either.
    assert {:error, :no_approver} = Approvals.reject(approval_id, nil)

    # The approval stayed pending and the privileged action NEVER ran single-party.
    {:ok, still} = Approvals.get(approval_id)
    assert still.state == :pending
    assert still.decided_by == nil
    assert reload(doc).status == :draft

    # POSITIVE CONTROL: a valid distinct NON-NIL approver approves + executes (not vacuous).
    approver = Ecto.UUID.generate()
    assert {:ok, approved, %{executed: "publish"}} = Approvals.approve(approval_id, approver)
    assert approved.state == :approved
    assert reload(doc).status == :published
  end

  test "T34-F1 DB CHECK: a raw insert of an :approved row with NULL apv_decided_by RAISES apv_distinct_party (the null-approver DB hole is closed)" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # RED: a decided ('approved') row with a NULL approver — the old `IS NULL OR` branch
    # would have permitted this; the tightened CHECK rejects it.
    assert_raise Postgrex.Error, ~r/apv_distinct_party/, fn ->
      @repo.query!(
        """
        INSERT INTO apv_approval
          (apv_id, apv_kind, apv_subject_ref, apv_requested_by, apv_decided_by,
           apv_state, apv_inserted_at, apv_updated_at)
        VALUES (gen_random_uuid(), 'k', 's', $1, NULL, 'approved', $2, $2)
        """,
        ["requester-z", now]
      )
    end

    # A 'rejected' row with NULL approver is refused too (reject is also a decision).
    assert_raise Postgrex.Error, ~r/apv_distinct_party/, fn ->
      @repo.query!(
        """
        INSERT INTO apv_approval
          (apv_id, apv_kind, apv_subject_ref, apv_requested_by, apv_decided_by,
           apv_state, apv_inserted_at, apv_updated_at)
        VALUES (gen_random_uuid(), 'k', 's', $1, NULL, 'rejected', $2, $2)
        """,
        ["requester-z", now]
      )
    end

    # CONTROL: a PENDING row legitimately has a NULL approver — it still inserts fine.
    assert %{num_rows: 1} =
             @repo.query!(
               """
               INSERT INTO apv_approval
                 (apv_id, apv_kind, apv_subject_ref, apv_requested_by, apv_decided_by,
                  apv_state, apv_inserted_at, apv_updated_at)
               VALUES (gen_random_uuid(), 'k', 's', $1, NULL, 'pending', $2, $2)
               """,
               ["requester-z", now]
             )
  end

  test "NULL-org exception PRESERVED: a NULL-org governance approval still decides fine with a DISTINCT non-nil approver (the exception is about org, not approver)" do
    o = org()
    doc = document(o)

    # A NULL-org operator/governance approval (the reveal "pii_reveal" shape).
    {:ok, approval} =
      Approvals.request(%{
        org_id: nil,
        kind: "test:op",
        subject_ref: "samen:apd:#{doc.id}",
        requested_by: Ecto.UUID.generate()
      })

    assert approval.org_id == nil

    # A distinct non-nil approver decides it — org NULL + approver non-null distinct passes
    # both the tightened DB CHECK and the engine guard (the null-org exception is intact).
    assert {:ok, decided, %{noted: true}} = Approvals.approve(approval.id, Ecto.UUID.generate())
    assert decided.state == :approved
    assert decided.org_id == nil
    assert decided.decided_by != nil
    assert reload(doc).note == "approved"

    # And a NULL-org approval still cannot be approved by a NULL approver.
    {:ok, approval2} =
      Approvals.request(%{
        org_id: nil,
        kind: "test:op",
        subject_ref: "samen:apd:#{Ecto.UUID.generate()}",
        requested_by: Ecto.UUID.generate()
      })

    assert {:error, :no_approver} = Approvals.approve(approval2.id, nil)
  end

  # ==========================================================================
  # c3 — org scope (cross-org read denied, both directions + NULL-org governance row).
  # ==========================================================================

  test "c3 cross-org: a tenant actor never reads another org's OR the NULL-org governance approvals (both directions)" do
    org_a = org()
    org_b = org()

    {:approval_required, id_a} = gated(document(org_a), :publish, actor(org_a))
    {:approval_required, id_b} = gated(document(org_b), :publish, actor(org_b))

    # A NULL-org operator/governance approval (the reveal "pii_reveal" shape).
    {:ok, null_org} =
      Approvals.request(%{
        org_id: nil,
        kind: "test:op",
        subject_ref: "samen:apd:#{Ecto.UUID.generate()}",
        requested_by: Ecto.UUID.generate()
      })

    seen_a = read_ids(actor(org_a))
    seen_b = read_ids(actor(org_b))

    assert id_a in seen_a
    refute id_b in seen_a
    refute null_org.id in seen_a

    assert id_b in seen_b
    refute id_a in seen_b
    refute null_org.id in seen_b
  end

  defp read_ids(actor) do
    {:ok, rows} =
      Approval
      |> Ash.Query.select([:id])
      |> Ash.read(actor: actor, authorize?: true)

    Enum.map(rows, & &1.id)
  end

  # ==========================================================================
  # Face 1 (handler registry) — the shape reveal adopts in T35: same-tx handler + rollback.
  # ==========================================================================

  test "Face 1: a registered non-gate handler runs INSIDE the decision transaction" do
    o = org()
    doc = document(o)

    {:ok, approval} =
      Approvals.request(%{
        org_id: o,
        kind: "test:note",
        subject_ref: "samen:apd:#{doc.id}",
        requested_by: Ecto.UUID.generate()
      })

    assert {:ok, _, %{noted: true}} = Approvals.approve(approval.id, Ecto.UUID.generate())
    assert reload(doc).note == "approved"
  end

  test "Face 1 same-tx ROLLBACK (the reveal guarantee): a handler that writes then errors rolls the WHOLE decision back" do
    o = org()
    doc = document(o)

    {:ok, approval} =
      Approvals.request(%{
        org_id: o,
        kind: "test:boom",
        subject_ref: "samen:apd:#{doc.id}",
        requested_by: Ecto.UUID.generate()
      })

    # The handler updates the document THEN returns {:error, :boom} — everything rolls back.
    assert {:error, :boom} = Approvals.approve(approval.id, Ecto.UUID.generate())

    {:ok, still} = Approvals.get(approval.id)
    assert still.state == :pending
    # The handler's own governed write rolled back with the decision (same-tx atomicity).
    assert reload(doc).note == nil
    assert audit_events(approval.id, "approval_approved") == []
  end

  # ==========================================================================
  # No-persisted-inputs / INV-1 — the approval row holds NO plaintext PII / vt_* token.
  # ==========================================================================

  test "INV-1 / no-persisted-inputs: the approval row for a publish carries only the object-ref — never the subject's secret or a vt_* token" do
    o = org()
    requester = actor(o, :member)
    secret = "SSN-521-90-PLAINTEXT-#{System.unique_integer([:positive])}"
    doc = document(o, secret: secret)

    {:approval_required, approval_id} = gated(doc, :publish, requester)

    # Scan the ENTIRE raw approval row.
    %{columns: cols, rows: [row]} =
      @repo.query!("SELECT * FROM apv_approval WHERE apv_id = $1", [Ecto.UUID.dump!(approval_id)])

    row_text = cols |> Enum.zip(row) |> Enum.map(fn {_c, v} -> inspect(v) end) |> Enum.join(" ")

    refute row_text =~ secret, "plaintext secret leaked into the approval row"
    refute row_text =~ "vt_", "a vault token leaked into the approval row"

    # The row carries only the bounded object-ref, never the inputs.
    {:ok, approval} = Approvals.get(approval_id)
    assert approval.subject_ref == "samen:apd:#{doc.id}"
    assert approval.reason == nil
  end

  test "reason is PiiReasonScan-gated at write (a PII-shaped reason is refused before any row lands)" do
    o = org()

    assert {:error, {:pii_shaped_reason, _}} =
             Approvals.request(%{
               org_id: o,
               kind: "test:note",
               subject_ref: "samen:apd:#{Ecto.UUID.generate()}",
               requested_by: Ecto.UUID.generate(),
               reason: "victim@example.com"
             })
  end

  test "unregistered kinds are refused at write" do
    assert {:error, :unregistered_kind} =
             Approvals.request(%{
               org_id: org(),
               kind: "totally:unknown",
               subject_ref: "samen:apd:#{Ecto.UUID.generate()}",
               requested_by: Ecto.UUID.generate()
             })
  end

  # ==========================================================================
  # Expiry — the AshOban trigger transitions past-deadline pending rows; job-args sink.
  # ==========================================================================

  test "expiry: a past-deadline pending approval transitions to :expired via the AshOban trigger + audit" do
    o = org()
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

    {:ok, approval} =
      Approvals.request(%{
        org_id: o,
        kind: "test:note",
        subject_ref: "samen:apd:#{Ecto.UUID.generate()}",
        requested_by: Ecto.UUID.generate(),
        deadline_at: past
      })

    AshOban.Test.schedule_and_run_triggers(Approval)

    {:ok, expired} = Approvals.get(approval.id)
    assert expired.state == :expired
    assert audit_events(approval.id, "approval_expired") == ["approval_expired"]
  end

  test "expiry job-args sink: the expire trigger persists NO actor (actor_persister :none) and rides the automation_timers queue (ID-only args by construction)" do
    [trigger] =
      AshOban.Info.oban_triggers(Approval)
      |> Enum.filter(&(&1.name == :expire_scan))

    assert trigger.actor_persister == :none
    assert trigger.queue == :automation_timers
    assert trigger.worker_read_action == :scan_expired
  end
end
