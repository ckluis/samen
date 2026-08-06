defmodule Samen.Web.ChatLiveRenderTest do
  @moduledoc """
  The chat LiveView render + mount-API gate (ADR-012 §6.2). Exercises the SAME `load/*` +
  `render/1` path the mounted route runs (via the `render_live` harness), on both planes:

    * the ThreadsLive inbox lists the org's threads;
    * the ThreadLive room renders the messages stream (body PII-resolved per plane), the
      participant roster (identity per the 3-state model), and the inline unfurl cards;
    * `handle_event "send"` persists + appends a message on the tenant plane;
    * `handle_info {:chat_message, ...}` appends a broadcast message re-read per plane.

  On the OPERATOR plane the SAME room renders bodies + identities `••••` — the two-plane thesis,
  extended to chat, with masking BY CONSTRUCTION (no LiveView masking branch).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat.{ThreadLive, ThreadsLive}
  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id, disclosure_mode: :tenant_wide, person_id: seeded.crm.person.id)
    %{org_id: seeded.org_id, chat: chat}
  end

  # -- the inbox ---------------------------------------------------------------

  test "ThreadsLive lists the org's threads (tenant plane)", %{org_id: org_id, chat: chat} do
    mount = chat_mount(plane: :tenant)
    html = render_live(ThreadsLive, mount, [org_id])

    assert html =~ chat.thread.subject
    assert html =~ "Conversations"
  end

  # ADR-013 §7 — the owner's exact complaint fixed: /chat lists threads by DEFAULT (no ?org),
  # never "no org selected". `mount/3` resolves the current org from the mount's default label.
  test "ThreadsLive inbox lists threads with NO ?org (resolves the mount default) — never a dead-end", %{org_id: org_id, chat: chat} do
    mount =
      Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{title: "Blue Ridge Logistics", default_org_id: org_id}
      )

    # mount/3 with EMPTY params + session — the resolver must reach the default_org_id label.
    session = %{"samen_mount" => Mount.to_session(mount)}
    {:ok, socket} = ThreadsLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

    refute socket.assigns.no_org
    assert socket.assigns.org_id == org_id

    html = ThreadsLive.render(Map.put(socket.assigns, :__changed__, %{})) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert html =~ chat.thread.subject
    refute html =~ "No org selected"
  end

  # ADR-013 §4.6 — the chat header + crumb read the RESOLVED org name (fixes "Workspace").
  test "ThreadsLive header/crumb show the resolved tenant name, not 'Workspace'", %{org_id: org_id} do
    mount =
      Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{title: "Summit Freight Partners", default_org_id: org_id}
      )

    html = render_live(ThreadsLive, mount, [org_id])
    assert html =~ "Summit Freight Partners"
  end

  # -- the room, tenant plane (clear) ------------------------------------------

  test "ThreadLive room renders CLEAR body + CLEAR identity + a CLEAR unfurl card (tenant)", %{
    org_id: org_id,
    chat: chat
  } do
    mount = chat_mount(plane: :tenant)
    html = render_live(ThreadLive, mount, [org_id, chat.thread.id])

    # The message body (vaulted) resolves clear on the tenant plane.
    assert html =~ "CHAT-BODY-SENTINEL"
    # The tenant participant identity is clear (tenant_wide, but tenant sees own plane anyway).
    assert html =~ Seeds.tenant_participant_full_name()
    # The inline unfurl card shows the real referenced person.
    assert html =~ Seeds.contact_full_name()
    # The safe handle is present.
    assert html =~ Seeds.tenant_participant_handle()
  end

  # -- the room, operator plane (masked) ---------------------------------------

  test "ThreadLive room renders •••• body + a MASKED unfurl card (operator), no plaintext", %{
    org_id: org_id,
    chat: chat
  } do
    # T153 — the operator desk-chat room is a per-tenant drill-in: it now requires a real,
    # audited impersonation session for this org (deny-on-read). Open one (keyed on the plane's
    # operator id "op-1"); the content then resolves masked, as before.
    open_impersonation!("op-1", org_id)
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    html = render_live(ThreadLive, mount, [org_id, chat.thread.id])

    # The body is masked on the operator plane — the sentinel is ABSENT.
    refute html =~ "CHAT-BODY-SENTINEL"
    assert html =~ "••••"
    # The referenced person's clear PII is ABSENT in the unfurl card.
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    # No vault token / pii_ column string leaks.
    refute html =~ "vt_"
    refute html =~ "pii_"
    # The safe handle still renders (non-PII).
    assert html =~ Seeds.tenant_participant_handle()
  end

  # -- the composer + realtime handlers ----------------------------------------

  test "handle_event send persists + appends a message (tenant plane)", %{org_id: org_id, chat: chat} do
    mount = chat_mount(plane: :tenant)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])

    before = length(socket.assigns.messages)

    {:noreply, socket} =
      ThreadLive.handle_event("send", %{"body" => "A brand-new composed line"}, socket)

    assert length(socket.assigns.messages) == before + 1
    last = List.last(socket.assigns.messages)
    assert last.message.body == "A brand-new composed line"
  end

  test "handle_info re-reads a broadcast message per plane (operator → ••••)", %{org_id: org_id, chat: chat} do
    # T153 — an active session is required for the operator room to load its content.
    open_impersonation!("op-1", org_id)
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])

    envelope = Samen.Web.Chat.envelope(chat.message)
    before = length(socket.assigns.messages)

    {:noreply, socket} = ThreadLive.handle_info({:chat_message, envelope}, socket)

    assert length(socket.assigns.messages) == before + 1
    appended = List.last(socket.assigns.messages)
    # The re-read resolved the body for the OPERATOR plane → masked.
    assert match?(%Samen.Masked{}, appended.message.body)
  end

  test "handle_info ignores a broadcast for a DIFFERENT thread", %{org_id: org_id, chat: chat} do
    mount = chat_mount(plane: :tenant)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])
    before = length(socket.assigns.messages)

    other_envelope = %{
      thread_id: Ash.UUID.generate(),
      message_id: Ash.UUID.generate(),
      sender_party: :tenant,
      participant_id: Ash.UUID.generate(),
      refs: []
    }

    {:noreply, socket} = ThreadLive.handle_info({:chat_message, other_envelope}, socket)
    assert length(socket.assigns.messages) == before
  end

  # -- T153: the operator desk-chat impersonation-session gate -----------------
  # The operator desk-chat (`plane: :operator`) reaches ONE tenant's chat. Viewing that tenant's
  # conversation content is a per-tenant drill-in → it now requires a real, audited
  # `Samen.Impersonation` session for the resolved org (deny-on-read), keyed on the plane's
  # operator id. The shared TENANT-plane chat is UNAFFECTED (never gated). Same gate/2 chokepoint
  # as the deliverability/automation/activity drill-ins (T150), so sabotage 57 flips these too.

  test "T153 DENIED without a session — the operator ROOM shows NO content + offers the open-session form", %{
    org_id: org_id,
    chat: chat
  } do
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    # No session opened.
    html = render_live(ThreadLive, mount, [org_id, chat.thread.id])

    assert html =~ "no active impersonation session"
    assert html =~ "open-session-form"
    assert html =~ ~s(phx-submit="open_session")
    # No tenant chat CONTENT (masked or otherwise) leaks on the deny state.
    refute html =~ "CHAT-BODY-SENTINEL"
    refute html =~ Seeds.tenant_participant_handle()
  end

  test "T153 DENIED without a session — the operator INBOX shows NO threads + offers the open-session form", %{
    org_id: org_id,
    chat: chat
  } do
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    html = render_live(ThreadsLive, mount, [org_id])

    assert html =~ "no active impersonation session"
    assert html =~ "open-session-form"
    refute html =~ chat.thread.subject
    refute html =~ "thread-row"
  end

  test "T153 WITH a session — the operator ROOM renders masked AND the access is RECORDED in the tenant ledger", %{
    org_id: org_id,
    chat: chat
  } do
    reason = "ticket #5150: chat dispute review"
    open_impersonation!("op-1", org_id, reason)

    mount = chat_mount(plane: :operator, target_org_id: org_id)
    html = render_live(ThreadLive, mount, [org_id, chat.thread.id])

    # Content resolves — masked by construction (operator plane, no grant).
    refute html =~ "CHAT-BODY-SENTINEL"
    assert html =~ "••••"
    refute html =~ "no active impersonation session"
    # The accountability line names the session (who/why/expiry).
    assert html =~ "session-accountability"
    assert html =~ reason

    # The tenant-visible ledger shows who / why / active — the honesty gap SecurityLive promised.
    ledger = Samen.Impersonation.list_for_org(org_id)
    assert Enum.any?(ledger, &(&1.operator_id == "op-1" and &1.reason == reason and &1.active?))
  end

  test "T153 positive control — the TENANT plane room is UNAFFECTED (renders clear, no session needed)", %{
    org_id: org_id,
    chat: chat
  } do
    mount = chat_mount(plane: :tenant)
    # No session anywhere — the tenant plane is never gated.
    html = render_live(ThreadLive, mount, [org_id, chat.thread.id])

    assert html =~ "CHAT-BODY-SENTINEL"
    refute html =~ "no active impersonation session"
    refute html =~ "open-session-form"
  end

  # -- helpers -----------------------------------------------------------------

  # Build the loaded socket the way `render_live` does, so handlers run against real assigns.
  defp build_socket(module, mount, load_args) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> then(&apply(module, :load, [&1 | load_args]))
  end

  defp chat_mount(opts) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator("op-1", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Samen.Web.Plane.tenant()
      end

    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: plane, labels: %{title: "Blue Ridge Logistics"})
  end
end
