defmodule Samen.Approvals.GatePolicyTest do
  @moduledoc """
  MG-19 — the one property `Samen.Approvals.Gate`'s `authorize?: true` (gate.ex:101)
  exists to hold, and the one nothing exercised: **an approval carries second-party
  consent, never privilege** (ADR-040 §4.4/§12 — "the requester acts within their OWN
  policy envelope; approval adds second-party consent, never privilege escalation").

  `on_approve/2` re-derives the subject with `authorize?: false` — correct, the engine
  must be able to SEE the record it was asked to decide about — and then re-invokes the
  gated action with `authorize?: true`. That second flag is the entire safety property:
  it re-applies the TARGET RESOURCE'S OWN policies to the reconstructed requester at
  EXECUTION time. Without it the engine would treat "a pending approval exists naming X
  as its requester" as evidence that X may perform the write, which is policy-bypass
  laundering: a mutation X could never make directly, made on X's behalf, over an audit
  trail that reads `approval_approved`.

  Nothing in the suite noticed. Mutating gate.ex:101 to `authorize?: false` left every
  test green, because every existing approval test drives the gate with a requester the
  target policy ALREADY permits — and a gate only ever driven by authorized requesters
  proves nothing about the gate.

  ## Why the approval is opened through `Samen.Approvals.request/2`

  Not for convenience — it is the reachable shape of the threat. The Gate's change face
  (`Ash.Changeset.for_update` on the gated action) does NOT open an approval for a
  requester the policy refuses: authorization runs first and the write comes back a bare
  `Ash.Error.Forbidden` with no approval row at all, which this file's front-door
  assertion pins. `Samen.Approvals.request/2` is the OTHER documented way in — the
  Face-1 handler-registry path (ADR-040 §4.4; `NoteHandler` in the fixture is one, and
  the reveal grant becomes one in T35), a trusted-kernel API whose own write is
  `authorize?: false`. It takes `org_id` and `requested_by` as DATA. So the row naming a
  requester can exist without that requester ever having been authorized for anything,
  and the execution-time re-check is the only thing standing between such a row and the
  write.

  ## The refusal axis

  `Gate.requester_principal/1` reconstructs the requester as
  `%{id: requested_by, org_id: approval.org_id, role: :member}` — `role` is a CONSTANT,
  so no role-based policy can distinguish one requester from another here. `Document`'s
  update policy is `forbid_unless OrgScope` + `forbid_unless RoleAtLeast :member`, which
  leaves ORG as the axis that discriminates, and it is the consequential one: the
  laundered write would be a cross-tenant mutation.

  Red/green pair (`Samen.RedPath` discipline) — both arms travel the IDENTICAL path, and
  the only difference between them is the requester's org:

    * RED — the refused requester's approved publish is still refused, the document is
      untouched, and the decision transaction rolls the approval back to `pending`;
    * CONTROL — the permitted requester's approved publish executes, as the requester.

  Captured red: with `authorize?: false` at gate.ex:101 the RED test fails by name
  (`Approvals.approve/3` returns `{:ok, …}` and the cross-org document is published)
  while the CONTROL still passes.
  """
  use ExUnit.Case, async: false

  alias Samen.Approvals
  alias Samen.Approvals.Gate
  alias SamenCore.Support.ApprovalsFixture.{Approval, Document}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  # ==========================================================================
  # Helpers (the engine_test.exs idiom)
  # ==========================================================================

  defp org, do: Ecto.UUID.generate()

  defp actor(org_id, role \\ :member),
    do: Samen.Scope.new(%{id: Ecto.UUID.generate(), org_id: org_id, role: role}).actor

  defp document(org_id),
    do:
      Samen.Factory.create!(
        Document,
        %{org_id: org_id, title: "Doc", secret: "ordinary"},
        authorize?: false
      )

  defp reload(doc), do: Ash.get!(Document, doc.id, authorize?: false)

  defp approval_state(id), do: Ash.get!(Approval, id, authorize?: false).state

  # Open a Gate-kind approval naming `requester` — the Face-1 / kernel-API path. The
  # subject_ref format is the Gate's own (`samen:<abbrev>:<id>`), derived rather than
  # hardcoded so it cannot drift from `Gate.subject_ref/1`.
  defp open_gate_approval(doc, action, requester) do
    Approvals.request(%{
      org_id: requester.org_id,
      kind: Gate.kind_for(Document, action),
      subject_ref: "samen:#{Samen.Info.abbrev(Document)}:#{doc.id}",
      requested_by: requester.id
    })
  end

  # The gated action driven directly as `actor` with the Gate already satisfied — i.e.
  # exactly what `on_approve/2` does, minus the engine. Used only to establish that the
  # target policy really does refuse / permit this actor, so neither arm below can pass
  # for the wrong reason.
  defp direct_attempt(doc, action, actor) do
    doc
    |> Ash.Changeset.for_update(action, %{},
      actor: actor,
      authorize?: true,
      context: %{approval_ok: true}
    )
    |> Ash.update()
  end

  # ==========================================================================
  # MG-19
  # ==========================================================================

  describe "gate.ex:101 authorize?: true re-applies the target resource's policy at execution" do
    test "RED: an approved action whose REQUESTER the target policy REFUSES is still refused" do
      org_a = org()
      org_b = org()
      doc = document(org_a)
      requester = actor(org_b)

      # PRECONDITION (non-vacuity): Document's own policy refuses THIS requester on
      # :publish. If that ever stops holding, the assertions below mean nothing.
      assert {:error, %Ash.Error.Forbidden{}} = direct_attempt(doc, :publish, requester)

      # A pending approval naming that requester exists.
      assert {:ok, approval} = open_gate_approval(doc, :publish, requester)
      assert approval.state == :pending
      assert approval.requested_by == requester.id
      assert reload(doc).status == :draft

      # A DISTINCT party approves. The consent is genuine — and says nothing about
      # whether the requester may perform the write.
      approver = Ecto.UUID.generate()
      refute approver == requester.id

      assert {:error, {:gate_action_failed, %Ash.Error.Forbidden{}}} =
               Approvals.approve(approval.id, approver)

      # The write did NOT happen: approval is consent, not privilege.
      published = reload(doc)
      assert published.status == :draft
      assert published.published_by == nil

      # The decision transaction rolled back whole (§4.3), so the approval is still
      # pending and the approver can cancel — not a decided row with no effect.
      assert approval_state(approval.id) == :pending
    end

    test "CONTROL: an approved action whose REQUESTER the target policy PERMITS does execute" do
      o = org()
      doc = document(o)
      requester = actor(o)

      # PRECONDITION: the IDENTICAL policy permits this requester — so the red above is
      # the policy re-check firing, not a blanket refusal of every approved execution.
      assert {:ok, _} = direct_attempt(document(o), :publish, requester)

      assert {:ok, approval} = open_gate_approval(doc, :publish, requester)
      assert reload(doc).status == :draft

      approver = Ecto.UUID.generate()
      assert {:ok, approved, meta} = Approvals.approve(approval.id, approver)
      assert approved.state == :approved
      assert meta.executed == "publish"

      published = reload(doc)
      assert published.status == :published
      # Executed AS THE REQUESTER, never the approver (§4.4).
      assert published.published_by == requester.id
      refute published.published_by == approver
    end

    test "the Gate's own change face does not open an approval for a refused requester" do
      # The front door is already closed: authorization runs before the Gate's
      # before_transaction hook can commit an approval, so a refused requester gets a
      # bare Forbidden and NO approval row. This is why the RED above goes through
      # Approvals.request/2 — and why the execution-time re-check still has to be real,
      # since request/2 is a legitimate kernel API that takes requested_by as data.
      org_a = org()
      doc = document(org_a)
      outsider = actor(org())

      before_count = @repo.aggregate(Approval, :count)

      assert {:error, %Ash.Error.Forbidden{}} =
               doc
               |> Ash.Changeset.for_update(:publish, %{}, actor: outsider)
               |> Ash.update()

      assert @repo.aggregate(Approval, :count) == before_count

      # Positive control: the same call by a PERMITTED requester does open one.
      insider = actor(org_a)

      assert {:error, _approval_required} =
               doc
               |> Ash.Changeset.for_update(:publish, %{}, actor: insider)
               |> Ash.update()

      assert @repo.aggregate(Approval, :count) == before_count + 1
    end
  end
end
