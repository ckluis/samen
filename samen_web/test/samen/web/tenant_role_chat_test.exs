defmodule Samen.Web.TenantRoleChatTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), Chat: the inbox and the room act with the role the signed-in person's
  ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Mount.scope/2`'s fixed `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`). Every refusal is
  paired with a positive control.

  Role choice: reading the inbox and a room is open to every active member (a viewer included); starting a conversation
  and posting a message are a member's; flipping the org-wide identity disclosure is an admin's (the kernel says so:
  `ChatDisclosureSetting` writes are `RoleAtLeast :admin`), and the handler checks it itself.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat.{ThreadLive, ThreadsLive}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  setup do
    ctx = H.setup_accounts()
    chat = Seeds.seed_chat(ctx.org_id, disclosure_mode: :masked)
    Map.put(ctx, :chat, chat)
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  defp threads(org_id) do
    Samen.WebTest.Chat.ChatThread
    |> Ash.Query.ensure_selected([:org_id, :subject])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp message_count(thread_id) do
    Samen.WebTest.Chat.ChatMessage
    |> Ash.Query.ensure_selected([:thread_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.thread_id == thread_id))
  end

  defp disclosure_on?(org_id) do
    Samen.WebTest.Chat.ChatDisclosureSetting
    |> Ash.Query.ensure_selected([:org_id, :expose_identity_to_support])
    |> Ash.read!(authorize?: false)
    |> Enum.any?(&(&1.org_id == org_id and &1.expose_identity_to_support))
  end

  defp inbox(login, ctx), do: H.live_socket(login, ThreadsLive, "/chat", ctx.org_id)
  defp room(login, ctx), do: H.live_socket(login, ThreadLive, "/chat/:id", ctx.org_id, %{"id" => ctx.chat.thread.id})

  test "both pages act with the RESOLVED role, not :member, and every role reads", ctx do
    for role <- [:viewer, :member, :admin, :owner] do
      login = H.log_in(Map.fetch!(ctx, role))

      for socket <- [inbox(login, ctx), room(login, ctx)] do
        assert socket.assigns.actor_state == :ok
        assert socket.assigns.acting_scope.actor.role == role
        assert socket.assigns.acting_scope.actor.resolved == true
      end

      assert html(ThreadsLive, inbox(login, ctx)) =~ "Rate confirmation for load #4471", "#{role}: the inbox is open to every member"
      assert html(ThreadLive, room(login, ctx)) =~ "Rate confirmation for load #4471", "#{role}: the room is open to every member"
    end
  end

  test "a viewer's crafted new_conversation creates nothing and the form is not offered; a member's does", ctx do
    viewer = inbox(H.log_in(ctx.viewer), ctx)
    assert viewer.assigns.can_write == false
    refute html(ThreadsLive, viewer) =~ ~s(id="new-conversation-form")

    before = length(threads(ctx.org_id))
    H.event(ThreadsLive, "new_conversation", %{"subject" => "Viewer thread"}, viewer)
    assert length(threads(ctx.org_id)) == before

    member = inbox(H.log_in(ctx.member), ctx)
    assert html(ThreadsLive, member) =~ ~s(id="new-conversation-form")
    H.event(ThreadsLive, "new_conversation", %{"subject" => "Member thread"}, member)
    assert Enum.any?(threads(ctx.org_id), &(&1.subject == "Member thread"))
  end

  test "the org-wide disclosure flip is an admin's: a member's and a viewer's crafted event changes nothing, an admin's does", ctx do
    for role <- [:viewer, :member] do
      socket = inbox(H.log_in(Map.fetch!(ctx, role)), ctx)
      assert socket.assigns.can_admin == false
      refute html(ThreadsLive, socket) =~ ~s(id="disclosure-form")

      socket = H.event(ThreadsLive, "toggle_disclosure", %{"expose_identity" => "on"}, socket)
      assert socket.assigns.flash_note =~ "admin only"
      refute disclosure_on?(ctx.org_id), "#{role} flipped org-wide identity disclosure"
    end

    admin = inbox(H.log_in(ctx.admin), ctx)
    assert html(ThreadsLive, admin) =~ ~s(id="disclosure-form")
    H.event(ThreadsLive, "toggle_disclosure", %{"expose_identity" => "on"}, admin)
    assert disclosure_on?(ctx.org_id)
  end

  test "posting in a room is a member's: a viewer's crafted send posts nothing, a member's does", ctx do
    thread_id = ctx.chat.thread.id
    before = message_count(thread_id)

    viewer = room(H.log_in(ctx.viewer), ctx)
    assert viewer.assigns.can_write == false
    refute html(ThreadLive, viewer) =~ ~s(id="chat-composer")

    viewer = H.event(ThreadLive, "send", %{"body" => "viewer says hi"}, viewer)
    assert viewer.assigns.flash["error"] =~ "can read this conversation but not post"
    assert message_count(thread_id) == before

    member = room(H.log_in(ctx.member), ctx)
    assert html(ThreadLive, member) =~ ~s(id="chat-composer")
    H.event(ThreadLive, "send", %{"body" => "member says hi"}, member)
    assert message_count(thread_id) == before + 1
  end

  test "NAVIGATION: a suspended member's pages are the denied state: nothing is read, no event writes", ctx do
    login = H.log_in(ctx.member)
    sockets = [{ThreadsLive, "/chat", %{}, inbox(login, ctx)}, {ThreadLive, "/chat/:id", %{"id" => ctx.chat.thread.id}, room(login, ctx)}]

    for {view, _path, _extra, socket} <- sockets do
      assert html(view, socket) =~ "Rate confirmation for load #4471", "nothing to read while acting (vacuous control)"
    end

    SpineAccounts.suspend!(ctx.member, ctx.org_id)
    before = message_count(ctx.chat.thread.id)
    thread_count = length(threads(ctx.org_id))

    for {view, _path, extra, socket} <- sockets do
      refused = H.params(view, socket, extra)
      assert refused.assigns.actor_state == :denied
      assert refused.assigns.acting_scope == nil
      out = html(view, refused)
      assert out =~ ~s(id="actor-denied")
      refute out =~ "Rate confirmation for load #4471"
    end

    [{_, _, _, inbox_socket}, {_, _, _, room_socket}] = sockets
    refused_inbox = H.params(ThreadsLive, inbox_socket, %{})
    refused_room = H.params(ThreadLive, room_socket, %{"id" => ctx.chat.thread.id})
    H.event(ThreadsLive, "new_conversation", %{"subject" => "after suspension"}, refused_inbox)
    H.event(ThreadsLive, "toggle_disclosure", %{"expose_identity" => "on"}, refused_inbox)
    H.event(ThreadLive, "send", %{"body" => "after suspension"}, refused_room)
    assert length(threads(ctx.org_id)) == thread_count
    assert message_count(ctx.chat.thread.id) == before
    refute disclosure_on?(ctx.org_id)
  end

  test "a failed membership lookup is the UNAVAILABLE state, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for {view, socket, extra} <- [
          {ThreadsLive, inbox(login, ctx) |> H.break_identity(), %{}},
          {ThreadLive, room(login, ctx) |> H.break_identity(), %{"id" => ctx.chat.thread.id}}
        ] do
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(view, socket, extra) end)
      assert refused.assigns.actor_state == :unavailable
      assert html(view, refused) =~ ~s(id="actor-unavailable")
      refute html(view, refused) =~ "Rate confirmation for load #4471"
    end
  end

  test "OPEN PAGE: a member demoted to viewer while the room is open posts nothing at the next event; an unchanged member does", ctx do
    thread_id = ctx.chat.thread.id
    before = message_count(thread_id)
    open = H.open_socket(H.log_in(ctx.member), ThreadLive, "/chat/:id", ctx.org_id, %{"id" => thread_id})
    assert open.assigns.can_write

    SpineAccounts.set_role!(ctx.member, ctx.org_id, :viewer)
    demoted = H.live_event(ThreadLive, "send", %{"body" => "demoted says hi"}, open)
    assert demoted.assigns.acting_scope.actor.role == :viewer
    refute demoted.assigns.can_write
    assert message_count(thread_id) == before

    SpineAccounts.set_role!(ctx.member, ctx.org_id, :member)
    fresh = H.open_socket(H.log_in(ctx.member), ThreadLive, "/chat/:id", ctx.org_id, %{"id" => thread_id})
    H.live_event(ThreadLive, "send", %{"body" => "member says hi"}, fresh)
    assert message_count(thread_id) == before + 1
  end

  test "OPEN PAGE: a member suspended while the room is open receives no further message", ctx do
    thread_id = ctx.chat.thread.id
    open = H.open_socket(H.log_in(ctx.member), ThreadLive, "/chat/:id", ctx.org_id, %{"id" => thread_id})

    envelope = Samen.Web.Chat.envelope(Seeds.append_chat_message(ctx.chat, ctx.org_id, "while acting"))
    {:noreply, delivered} = ThreadLive.handle_info({:chat_message, envelope}, open)
    assert Enum.any?(delivered.assigns.messages, &(&1.message.id == envelope.message_id)), "a delivery while acting is shown (vacuous control)"

    SpineAccounts.suspend!(ctx.member, ctx.org_id)
    envelope = Samen.Web.Chat.envelope(Seeds.append_chat_message(ctx.chat, ctx.org_id, "after the suspension"))
    {:noreply, refused} = ThreadLive.handle_info({:chat_message, envelope}, open)
    assert refused.assigns.actor_state == :denied
    assert refused.assigns.messages == []
    refute html(ThreadLive, refused) =~ "after the suspension"
  end
end
