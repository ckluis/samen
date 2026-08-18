defmodule Samen.Web.ChatThreadSubscribeGateTest do
  @moduledoc """
  S13 (luminary panel-2 HIGH-triaged-MED) — the chat room's realtime delivery + send paths
  are GATED, and an operator socket whose impersonation session lapses mid-flight can neither
  receive further messages nor post.

  ## The hole this closes

  `Samen.Web.Chat.ThreadLive` subscribed to the thread's PubSub topic in `mount/3` BEFORE the
  T153 impersonation gate ran, and neither `handle_info({:chat_message, …})` nor
  `handle_event("send", …)` re-consulted the gate — they built a plain `Mount.scope/2` from
  the org id and delivered/persisted unconditionally. So an operator whose session expired (or
  was revoked) mid-flight kept STREAMING messages and could still POST into the tenant's
  conversation — authorization was decided once, at first render, and never again.

  ## The fix under test (the on_mount/gate re-check pattern)

  One chokepoint — `gate/3`, the SAME deny-on-read T153 gate `load/*` runs — now guards every
  delivery edge:

    * `mount/3` subscribes to the topic ONLY after the gate passes (no subscription on an
      unauthorized socket in the first place);
    * `handle_info/2` re-runs the gate before delivering a broadcast — a lapsed session drops
      the message.

  ## The SEND edge — covered structurally by WriteGuard, deliberately NOT asserted here

  `handle_event("send", …)` also consults the gate, but that conjunct is defense-in-depth
  BEHIND `Samen.Pii.WriteGuard` (no-operator-plaintext-write, MC-1 / ADR-016 L1): every
  operator-plane chat post is refused at the vault write chokepoint REGARDLESS of session
  state, so "a lapsed-session operator cannot post" is true with or without the gate conjunct
  — a test asserting it can never go red (the CLAUDE.md anti-tautology rule) and none exists
  here on purpose. The refusal itself is proven refutable in the chokepoint's own suite
  (`samen_core/test/pii_write_guard_test.exs`: `plane: :operator` PII create/update REFUSED,
  paired with its allowed-plane positive controls).

  The tenant plane is never gated (`gate` returns `{:ok, nil}`), so tenant realtime is
  unchanged — the anti-tautology positive controls below prove the authorized paths still work.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat.ThreadLive
  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id, disclosure_mode: :tenant_wide, person_id: seeded.crm.person.id)
    %{org_id: seeded.org_id, chat: chat}
  end

  # ==========================================================================
  # RED — an operator whose session LAPSES mid-flight is cut off
  # ==========================================================================

  test "handle_info does NOT deliver a broadcast to an operator whose session has lapsed", %{org_id: org_id, chat: chat} do
    session = open_impersonation!("op-1", org_id)
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])

    # The session lapses AFTER the socket loaded (revocation / expiry mid-flight).
    {:ok, _} = Samen.Impersonation.close(session.id)

    before = length(socket.assigns.messages)
    envelope = Samen.Web.Chat.envelope(chat.message)
    {:noreply, socket} = ThreadLive.handle_info({:chat_message, envelope}, socket)

    assert length(socket.assigns.messages) == before,
           "S13 regression: a lapsed-session operator socket kept receiving realtime messages"
  end

  test "handle_info does NOT deliver to an operator with NO session at all (denied at the door)", %{org_id: org_id, chat: chat} do
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])

    before = length(socket.assigns.messages)
    envelope = Samen.Web.Chat.envelope(chat.message)
    {:noreply, socket} = ThreadLive.handle_info({:chat_message, envelope}, socket)

    assert length(socket.assigns.messages) == before,
           "S13 regression: an ungated operator socket received a broadcast with no session"
  end

  # ==========================================================================
  # POSITIVE CONTROLS (anti-tautology) — the authorized paths still deliver
  # ==========================================================================

  test "POSITIVE CONTROL — an operator WITH an active session still receives (masked)", %{org_id: org_id, chat: chat} do
    open_impersonation!("op-1", org_id)
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])

    before = length(socket.assigns.messages)
    envelope = Samen.Web.Chat.envelope(chat.message)
    {:noreply, socket} = ThreadLive.handle_info({:chat_message, envelope}, socket)

    assert length(socket.assigns.messages) == before + 1,
           "an active-session operator must still receive realtime messages"

    appended = List.last(socket.assigns.messages)
    assert match?(%Samen.Masked{}, appended.message.body),
           "the delivered body must be masked by construction on the operator plane"
  end

  test "POSITIVE CONTROL — the TENANT plane delivers + posts, never gated", %{org_id: org_id, chat: chat} do
    mount = chat_mount(plane: :tenant)
    socket = build_socket(ThreadLive, mount, [org_id, chat.thread.id])

    # deliver
    before = length(socket.assigns.messages)
    envelope = Samen.Web.Chat.envelope(chat.message)
    {:noreply, socket} = ThreadLive.handle_info({:chat_message, envelope}, socket)
    assert length(socket.assigns.messages) == before + 1

    # post
    posted_before = message_count(chat.thread.id)
    {:noreply, _socket} =
      ThreadLive.handle_event("send", %{"body" => "TENANT-CLEAR-POST"}, socket)

    assert message_count(chat.thread.id) == posted_before + 1,
           "the tenant plane must still persist a sent message"
  end

  # -- helpers -----------------------------------------------------------------

  defp build_socket(module, mount, load_args) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> then(&apply(module, :load, [&1 | load_args]))
  end

  defp message_count(thread_id) do
    require Ash.Query

    Samen.WebTest.Chat.ChatMessage
    |> Ash.Query.filter(thread_id == ^thread_id)
    |> Ash.count!(authorize?: false)
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
