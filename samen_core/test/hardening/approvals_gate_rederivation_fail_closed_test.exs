defmodule Samen.Hardening.ApprovalsGateRederivationFailClosedTest do
  @moduledoc """
  Fail-closed PROOF for the one `Samen.Approvals.Gate` decision the ADR-049 mutation gate
  found SURVIVING (ledgered ACCEPTED_GAP as MG-18): the deliberate `authorize?: false` on
  `on_approve/2`'s §4.4 RE-DERIVATION read (line 96 on `0216ce8`; `false` → `true`).

  ## Why that literal is deliberate, and why flipping it matters

  §4.4 says the approved action is re-derived from governed domain state via `subject_ref`,
  then RE-INVOKED as the REQUESTER inside the requester's own policy envelope. The
  re-derivation READ is therefore not an authorization decision — it is how the engine finds
  the subject at all. The authorization decision is the `for_update`/`Ash.update` two lines
  below, which is `authorize?: true` and is left untouched here.

  Flipping the read to `authorize?: true` silently changes WHO CAN BE APPROVED FOR WHAT: the
  requester principal (`%{id: requested_by, org_id: approval.org_id, role: :member}`) is
  reconstructed from the APPROVAL's bounded ids, so any approval whose `org_id` does not
  match the subject's real org stops being an authorization failure on the WRITE (refused,
  §12: approval adds consent, never privilege) and becomes an invisible NOT-FOUND on the
  READ — `{:subject_unavailable, _}`, which §7.1 reserves for "the subject vanished/was
  archived between request and decision" and which leaves the approval PENDING for the
  approver to retry. A real refusal is re-labelled as a transient one.

  Verified RED-FIRST by hand: with `authorize?: true` the named test fails (the engine
  answers `{:subject_unavailable, _}` instead of `{:gate_action_failed, _}`), and it passes
  again on the byte-exact restored source.
  """
  use ExUnit.Case, async: false

  alias Samen.Approvals
  alias SamenCore.Support.ApprovalsFixture.Document

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp document!(org_id) do
    Samen.Factory.create!(Document, %{org_id: org_id, title: "Doc", secret: "ordinary"},
      authorize?: false
    )
  end

  defp gate_approval!(attrs) do
    {:ok, approval} =
      Approvals.request(
        Map.merge(
          %{kind: Approvals.Gate.kind_for(Document, :publish), reason: "hardening proof"},
          attrs
        )
      )

    approval
  end

  describe "MG-18 — the §4.4 re-derivation read is NOT the authorization decision (line 96)" do
    test "MG-18: an approval whose org does not match the subject fails on the WRITE, not as a missing subject" do
      subject_org = Ecto.UUID.generate()
      other_org = Ecto.UUID.generate()
      doc = document!(subject_org)

      # A Gate-kind approval attached to a real document but carrying a DIFFERENT org — the
      # shape the §12 "never privilege escalation" rule exists to refuse. (`Approvals.request/1`
      # does not itself cross-check the subject's org, which is exactly why the decision has
      # to be taken at the write.)
      approval =
        gate_approval!(%{
          org_id: other_org,
          subject_ref: "samen:apd:#{doc.id}",
          requested_by: Ecto.UUID.generate()
        })

      result = Approvals.approve(approval.id, Ecto.UUID.generate())

      assert {:error, {:gate_action_failed, _reason}} = result,
             "the re-derivation read must SEE the subject so the refusal lands on the " <>
               "authorized write; got: #{inspect(result)}"

      # The write really was refused — the transition rolled back with it.
      reloaded = Ash.get!(Document, doc.id, authorize?: false)
      assert reloaded.status != :published
    end

    test "CONTROL (anti-tautology): the honest same-org approval still EXECUTES as the requester" do
      org_id = Ecto.UUID.generate()
      doc = document!(org_id)
      requester_id = Ecto.UUID.generate()

      approval =
        gate_approval!(%{
          org_id: org_id,
          subject_ref: "samen:apd:#{doc.id}",
          requested_by: requester_id
        })

      assert {:ok, decided, %{executed: "publish"}} =
               Approvals.approve(approval.id, Ecto.UUID.generate())

      assert decided.state == :approved

      published = Ash.get!(Document, doc.id, authorize?: false)
      assert published.status == :published
      assert published.published_by == requester_id
    end
  end
end
