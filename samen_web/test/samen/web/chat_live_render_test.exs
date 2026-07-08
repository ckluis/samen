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
