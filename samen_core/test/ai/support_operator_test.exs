defmodule Samen.AI.SupportOperatorTest do
  @moduledoc """
  RP-T70 / RP-AI-6 — the D5 AI support operator (ADR-043 §6.3): it DRAFTS a reply and
  enqueues it for HUMAN approval, and structurally cannot send without a distinct human
  approving. The crux invariants of this task, each proven non-vacuously:

    * **(a) draft egress MASKED** — a vault-routed (🔒) canary in the inbound support item is
      `••••` in the payload the AI provider receives, never plaintext, never a `vt_*` token.
      Non-vacuous positive control: the mask IS present in the provider payload (the field
      was resolved-then-masked, not simply omitted).
    * **(b) NO auto-send** — `draft_reply/3` opens a PENDING approval and sends NOTHING; the
      operator has no code path to `Samen.Delivery.Chokepoint.send/2`.
    * **(c) distinct human approve SENDS (positive control) + self-approval REJECTED** — only
      a distinct human approving fires the send (within the draft's own org); the AI
      principal approving its own request is refused (`:self_approval`), nothing sent.
    * **fail-honest send** — an unconfigured delivery yields `{:error, :adapter_unconfigured}`
      (never a fake `{:ok, _}`); the decision rolls back (approval pending, draft `:draft`).
    * **(d) org-scope** — org B's operator cannot ground on / reply over org A's support item
      (`:source_not_found`), with the same-org positive control. The sabotage twin
      (`scripts/sabotages/51-...`) drops the org filter and flips the named cross-org test.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.{Provider, SupportOperator, SupportReplyDraft}
  alias Samen.AI.SupportOperator.ReplyHandler
  alias Samen.Approvals
  alias Samen.Delivery.FakeProvider
  alias SamenCore.Support.ApprovalsFixture.{Approval, Document}
  alias SamenCore.TestRepo

  # A unique 🔒 canary seeded into the inbound support item's vault-routed `secret` field.
  @canary "canary-support-op-4k3j@leak.example"
  @mask Samen.Masked.mask()

  @registry %{"ai_support_reply" => {:operator, ReplyHandler}}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Provider.Fake.reset()
    FakeProvider.reset()
    :ok
  end

  # The AI service principal's scope (operator plane), serving `org`.
  defp scope(org) do
    %Samen.Scope{
      actor: %{id: SupportOperator.principal_id(), org_id: org, role: :member, plane: :operator}
    }
  end

  # An inbound support item as a governed record carrying a 🔒 canary + a non-PII field.
  defp item(org, secret) do
    Samen.Factory.create!(
      Document,
      %{org_id: org, title: "Refund question", secret: secret},
      authorize?: false
    )
  end

  # The engine wiring the operator + handler need (mirrors config/test.exs; passed explicit).
  defp wiring, do: [approval_resource: Approval, repo: TestRepo, kinds: @registry]

  defp reload(draft), do: Ash.get!(SupportReplyDraft, draft.id, authorize?: false)

  defp provider_payload_text do
    Provider.Fake.sent_payloads()
    |> Enum.map(fn {_cb, p} -> Enum.map_join(p.segments, " ", &to_string/1) end)
    |> Enum.join(" ")
  end

  # ==========================================================================
  # (a) draft egress masked — the PII canary never reaches the AI provider
  # ==========================================================================

  describe "(a) draft egress is masked through the chokepoint" do
    test "the 🔒 canary in the support item is MASKED to the provider; the mask IS present (non-vacuous)" do
      org = Ash.UUID.generate()
      doc = item(org, @canary)

      {:ok, result} =
        SupportOperator.draft_reply(
          scope(org),
          %{
            to_subscriber_id: Ash.UUID.generate(),
            source_resource: Document,
            source_id: doc.id,
            instruction: "draft a friendly reply to this refund question",
            verb: :generate
          },
          wiring()
        )

      # A draft WAS composed and an approval opened — the pipeline ran end to end.
      assert is_binary(result.draft_text)
      assert result.approval.state == :pending

      payload = provider_payload_text()
      # Positive control (non-vacuous): the vault field WAS resolved into the egress — and
      # masked. The mask token is present, proving the binding was processed, not omitted.
      assert payload =~ @mask
      # The crux: the canary plaintext and any vt_* token are absent from the provider payload.
      refute payload =~ @canary, "the 🔒 canary reached the AI provider payload"
      refute payload =~ "vt_", "a vault token reached the AI provider payload"

      # And the persisted draft body (what a human reviews / what will send) carries neither.
      refute reload(result.draft).body =~ @canary
      refute reload(result.draft).body =~ "vt_"
    end
  end

  # ==========================================================================
  # (b) no auto-send — a draft opens a PENDING approval and sends nothing
  # ==========================================================================

  describe "(b) the operator cannot auto-send" do
    test "drafting opens a PENDING approval and sends NOTHING (no direct send path)" do
      org = Ash.UUID.generate()

      {:ok, result} =
        SupportOperator.draft_reply(
          scope(org),
          %{to_subscriber_id: Ash.UUID.generate(), instruction: "a welcome reply"},
          wiring()
        )

      # A PENDING approval, a :draft record — and NOTHING delivered.
      assert result.approval.state == :pending
      assert result.draft.status == :draft
      assert reload(result.draft).status == :draft
      assert FakeProvider.calls() == []
    end
  end

  # ==========================================================================
  # (c) distinct human approve sends (positive control) + self-approval rejected
  # ==========================================================================

  describe "(c) only a distinct human approve sends" do
    test "a distinct human approve fires the send within-org; a self-approval is REJECTED" do
      org = Ash.UUID.generate()

      {:ok, result} =
        SupportOperator.draft_reply(
          scope(org),
          %{to_subscriber_id: Ash.UUID.generate(), instruction: "a reply"},
          wiring()
        )

      approval_id = result.approval_id

      # Self-approval by the AI principal (the requester) is REFUSED — distinct-party. Nothing
      # sends; the approval stays pending, the draft stays :draft.
      assert {:error, :self_approval} =
               Approvals.approve(approval_id, SupportOperator.principal_id(), wiring())

      assert FakeProvider.calls() == []
      assert reload(result.draft).status == :draft

      # Positive control: a DISTINCT human approves → NOW the send fires, as the requester's
      # own org, through the delivery chokepoint (a configured recording adapter here).
      human_id = Ash.UUID.generate()
      assert human_id != SupportOperator.principal_id()

      approve_opts =
        wiring() ++
          [delivery_env: :test, fallback_adapter: FakeProvider, fallback_config: %{configured: true}]

      assert {:ok, _approval, meta} = Approvals.approve(approval_id, human_id, approve_opts)
      assert meta.sent == true

      # A real delivery happened, within the draft's own org.
      assert [{:deliver, %{message: message}} | _] = FakeProvider.calls()
      assert message.org_id == org
      assert reload(result.draft).status == :sent
    end
  end

  # ==========================================================================
  # fail-honest send — unconfigured delivery never fakes an :ok
  # ==========================================================================

  describe "fail-honest send (ADR-014/024/026)" do
    test "an unconfigured delivery yields {:error, :adapter_unconfigured}; the decision rolls back" do
      org = Ash.UUID.generate()

      {:ok, result} =
        SupportOperator.draft_reply(
          scope(org),
          %{to_subscriber_id: Ash.UUID.generate(), instruction: "a reply"},
          wiring()
        )

      human_id = Ash.UUID.generate()

      # No adapter wired + env :prod ⇒ the delivery chokepoint blocks (never a fake :ok). The
      # handler propagates it, rolling the whole decision back.
      assert {:error, {:delivery_failed, :adapter_unconfigured}} =
               Approvals.approve(result.approval_id, human_id, wiring() ++ [delivery_env: :prod])

      # Rolled back: the approval stays pending, the draft stays :draft, nothing sent.
      {:ok, approval} = Approvals.get(result.approval_id, wiring())
      assert approval.state == :pending
      assert reload(result.draft).status == :draft
      assert FakeProvider.calls() == []
    end
  end

  # ==========================================================================
  # (d) org-scope — org B can never touch org A's support item
  # ==========================================================================

  describe "(d) org-scope isolation" do
    test "org B's operator cannot ground on org A's support item (positive control: org A can)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      doc = item(org_a, @canary)

      # Positive control — org A grounds on ITS OWN item and drafts.
      assert {:ok, a_result} =
               SupportOperator.draft_reply(
                 scope(org_a),
                 %{
                   to_subscriber_id: Ash.UUID.generate(),
                   source_resource: Document,
                   source_id: doc.id,
                   instruction: "reply"
                 },
                 wiring()
               )

      # The draft org A created belongs to org A (never another org).
      assert a_result.draft.org_id == org_a

      # RP-T70 (d): org B — same tool, same item id — cannot reach org A's item.
      assert {:error, :source_not_found} =
               SupportOperator.draft_reply(
                 scope(org_b),
                 %{
                   to_subscriber_id: Ash.UUID.generate(),
                   source_resource: Document,
                   source_id: doc.id,
                   instruction: "reply"
                 },
                 wiring()
               )
    end

    test "an org-less scope is refused fail-closed" do
      assert {:error, :no_org} =
               SupportOperator.draft_reply(
                 %Samen.Scope{actor: %{id: "u", org_id: nil}},
                 %{to_subscriber_id: Ash.UUID.generate(), instruction: "x"},
                 wiring()
               )
    end
  end

  # ==========================================================================
  # a rejection discards the draft (no send)
  # ==========================================================================

  describe "rejection" do
    test "a distinct human rejecting discards the draft and never sends" do
      org = Ash.UUID.generate()

      {:ok, result} =
        SupportOperator.draft_reply(
          scope(org),
          %{to_subscriber_id: Ash.UUID.generate(), instruction: "a reply"},
          wiring()
        )

      human_id = Ash.UUID.generate()
      assert {:ok, _} = Approvals.reject(result.approval_id, human_id, wiring())

      assert reload(result.draft).status == :discarded
      assert FakeProvider.calls() == []
    end
  end
end
