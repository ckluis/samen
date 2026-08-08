defmodule Driftwood.AiSupportDraftPersistenceTest do
  @moduledoc """
  T155 (operator ruling — persistence host = DRIFTWOOD) — the AI support-reply draft
  PERSISTS end-to-end in a REAL host (`Driftwood.Repo`) via driftwood's own config
  (`Samen.AI.Domain` mounted, `:samen_ai_support_reply_draft_repo` → `Driftwood.Repo`, the
  `ai_support_reply` approval kind registered) and flows through the E3 approval engine —
  requester (the AI service principal) is never the decider, a distinct human approve marks
  the draft `:sent`.

  This is the proof the samen_web kit (host-agnostic) could not carry alone: the draft
  resource is compile-bound to a repo, so ONLY a host that adopted the domain proves real
  persistence. No explicit engine/repo `wiring()` is passed to `draft_reply/3` — it resolves
  driftwood's REAL config, so a green here means driftwood genuinely adopted the plane.
  """
  use Driftwood.DataCase, async: false

  alias Samen.AI.{Provider, SupportOperator, SupportReplyDraft}
  alias Samen.Approvals
  alias Samen.Delivery.FakeProvider

  setup do
    Provider.Fake.reset()
    FakeProvider.reset()
    :ok
  end

  # The AI service principal's scope (operator plane) serving `org` — draft_reply resolves
  # driftwood's config for the repo/approval-resource/registry (NO explicit wiring passed).
  defp scope(org) do
    %Samen.Scope{
      actor: %{id: SupportOperator.principal_id(), org_id: org, role: :member, plane: :operator}
    }
  end

  # Physical proof the row lives in DRIFTWOOD's repo (not samen_core's TestRepo) — a raw
  # Driftwood.Repo query against the migrated ai_support_reply_draft table.
  defp row_in_driftwood_repo(id) do
    %{rows: rows} =
      Driftwood.Repo.query!(
        "SELECT sas_status, sas_org_id FROM ai_support_reply_draft WHERE sas_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    rows
  end

  test "a draft PERSISTS in Driftwood.Repo and opens a pending ai_support_reply approval" do
    org = Ash.UUID.generate()

    {:ok, result} =
      SupportOperator.draft_reply(
        scope(org),
        %{to_subscriber_id: Ash.UUID.generate(), instruction: "draft a friendly reply"}
      )

    # (1) The draft is a real, persisted row in DRIFTWOOD's repo (physical query), in this org.
    assert [[status, row_org]] = row_in_driftwood_repo(result.draft.id)
    assert status == "draft"
    assert Ecto.UUID.load!(row_org) == org

    # (2) Readable back through the Ash resource on driftwood's configured repo.
    reloaded = Ash.get!(SupportReplyDraft, result.draft.id, authorize?: false)
    assert reloaded.status == :draft

    # (3) A PENDING ai_support_reply approval was opened (routed by driftwood's registry).
    assert result.approval.state == :pending
    assert result.approval.kind == "ai_support_reply"

    # And nothing was sent (draft, not send).
    assert FakeProvider.calls() == []
  end

  test "requester (AI principal) is NEVER the decider; a distinct human approve marks it :sent" do
    org = Ash.UUID.generate()

    {:ok, result} =
      SupportOperator.draft_reply(
        scope(org),
        %{to_subscriber_id: Ash.UUID.generate(), instruction: "a reply"}
      )

    approval_id = result.approval_id

    # Self-approval by the AI principal (the requester) is refused — distinct-party by
    # construction. Nothing sends; the draft stays :draft.
    assert {:error, :self_approval} =
             Approvals.approve(approval_id, SupportOperator.principal_id())

    assert FakeProvider.calls() == []
    assert Ash.get!(SupportReplyDraft, result.draft.id, authorize?: false).status == :draft

    # Positive control: a DISTINCT human approves → the send fires through the delivery
    # chokepoint, within the draft's own org, and the persisted draft flips to :sent.
    human_id = Ash.UUID.generate()
    assert human_id != SupportOperator.principal_id()

    approve_opts = [
      delivery_env: :test,
      fallback_adapter: FakeProvider,
      fallback_config: %{configured: true}
    ]

    assert {:ok, _approval, meta} = Approvals.approve(approval_id, human_id, approve_opts)
    assert meta.sent == true

    assert [{:deliver, %{message: message}} | _] = FakeProvider.calls()
    assert message.org_id == org

    # The persisted draft in DRIFTWOOD's repo is now :sent (the status transition survived).
    assert [[status, _org]] = row_in_driftwood_repo(result.draft.id)
    assert status == "sent"
  end

  test "the kit's list_drafts read is ORG-SCOPED: org A never sees org B's drafts (drop-filter-flips-this)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    {:ok, _} =
      SupportOperator.draft_reply(scope(org_a), %{to_subscriber_id: Ash.UUID.generate(), instruction: "A's draft"})

    {:ok, _} =
      SupportOperator.draft_reply(scope(org_b), %{to_subscriber_id: Ash.UUID.generate(), instruction: "B's draft"})

    # `Samen.Web.AI.Server.list_drafts/2` (the kit read) org-scopes by construction.
    a_drafts = Samen.Web.AI.Server.list_drafts(nil, org_a)
    b_drafts = Samen.Web.AI.Server.list_drafts(nil, org_b)

    # Positive control: each org sees exactly its own one draft.
    assert length(a_drafts) == 1
    assert length(b_drafts) == 1
    # The crux (patch 145): org A's read never returns org B's draft.
    refute Enum.any?(a_drafts, &(&1.id in Enum.map(b_drafts, fn d -> d.id end)))
  end
end
