defmodule Samen.Web.ChatCrossplaneScopeTest do
  @moduledoc """
  THE CROSS-PLANE VISIBILITY GATE (ADR-012 §2.3, test-plan §8.4, red path 6).

  A cross-plane `ChatThread` is OWNED BY THE TENANT ORG. Both parties are satisfied by the
  UNCHANGED `OrgScope`:

    * the TENANT actor (`org_id = <tenant_org>`, `plane: :tenant`) reads its own thread; and
    * the SaaS OPERATOR (`org_id = <tenant_org>` via the impersonation bridge, `plane: :operator`)
      reads the SAME thread — because the row's `org_id` is the tenant org and both actors present
      it. NO new policy, no upward escalation.

  Red path 6: an operator whose impersonation session targets a DIFFERENT org presents a
  different `org_id` → `OrgScope` returns the thread as ZERO rows. Cross-plane visibility is a
  grant that expires, not a backdoor.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat.Reads
  alias Samen.Web.Mount

  setup do
    org_id = Ash.UUID.generate()
    chat = Seeds.seed_chat(org_id)
    %{org_id: org_id, chat: chat}
  end

  test "a tenant-owned thread is visible to BOTH the tenant actor and the impersonating operator", %{
    org_id: org_id,
    chat: chat
  } do
    tenant_mount = chat_mount(plane: :tenant)
    operator_mount = chat_mount(plane: :operator, target_org_id: org_id)

    assert {:ok, tenant_thread} = Reads.get_thread(tenant_mount, Mount.scope(tenant_mount, org_id), chat.thread.id)
    assert {:ok, operator_thread} = Reads.get_thread(operator_mount, Mount.scope(operator_mount, org_id), chat.thread.id)

    # The SAME tenant-owned thread — same id — visible on both planes.
    assert tenant_thread.id == chat.thread.id
    assert operator_thread.id == chat.thread.id
  end

  test "an operator whose impersonation targets a DIFFERENT org sees the thread as zero rows (red path 6)", %{
    chat: chat
  } do
    # The operator opened a DIFFERENT tenant org (mismatched target) → org_id != <tenant_org>.
    other_org = Ash.UUID.generate()
    mismatched_mount = chat_mount(plane: :operator, target_org_id: other_org)
    scope = Mount.scope(mismatched_mount, other_org)

    # OrgScope narrows to other_org → the tenant-owned thread is not in scope → :error.
    assert :error = Reads.get_thread(mismatched_mount, scope, chat.thread.id)

    # And the thread list for the mismatched org does NOT include the tenant-owned thread.
    threads = Reads.threads(mismatched_mount, scope)
    refute Enum.any?(threads, fn t -> t.id == chat.thread.id end)
  end

  test "both parties see the SAME participants + messages under the SAME org_id", %{org_id: org_id, chat: chat} do
    tenant_mount = chat_mount(plane: :tenant)
    operator_mount = chat_mount(plane: :operator, target_org_id: org_id)

    tenant_parts = Reads.participants(tenant_mount, Mount.scope(tenant_mount, org_id), chat.thread.id)
    operator_parts = Reads.participants(operator_mount, Mount.scope(operator_mount, org_id), chat.thread.id)

    # Same membership set (the grant is data, visible to both parties under the shared org_id).
    assert Enum.map(tenant_parts, & &1.id) |> Enum.sort() ==
             Enum.map(operator_parts, & &1.id) |> Enum.sort()

    # The operator sees the cross-plane grant carrier (party) without trusting the live actor.
    assert Enum.any?(operator_parts, fn p -> p.party == :operator end)
    assert Enum.any?(operator_parts, fn p -> p.party == :tenant end)
  end

  # -- helpers -----------------------------------------------------------------

  defp chat_mount(opts) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator("op-1", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Samen.Web.Plane.tenant()
      end

    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: plane)
  end
end
