defmodule Samen.Web.Chat.ThreadLive do
  @moduledoc """
  Framework Chat / room (ADR-012 §6.2) — the realtime conversation view. The SAME LiveView
  renders the tenant plane (own data, clear) and the operator-desk plane (impersonation over a
  tenant org, masked) — the two-plane thesis, extended to chat.

  ## The realtime + masking flow (masking BY CONSTRUCTION)

    * `mount/3` (connected): `subscribe` to the thread topic, `Presence.track` self (party +
      handle — non-PII), load messages (PII-resolved for THIS viewer) + participants
      (identity-resolved per the 3-state model) + pre-resolve each message's refs into unfurl
      cards (per viewer).
    * `handle_event "send"`: parse refs on the PLAINTEXT → persist via Ash (vault + org-scope) →
      broadcast an ID-ONLY envelope. The sender appends optimistically (its own scope).
    * `handle_info {:chat_message, envelope}`: re-read the message for THIS viewer's scope →
      resolve its refs into per-viewer cards → append. A tenant subscriber gets the clear body;
      an operator subscriber gets `••••` — from the SAME broadcast, because the envelope carries
      the id, never the body (§3.2, red path 3).

  Every rendered PII value is the resolver's ALREADY-RESOLVED field; this LiveView has NO
  unmasking branch and NEVER calls the vault.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Chat.Components
  import Samen.Web.CRM.Live, only: [assign_mount: 2]

  alias Samen.Web.Chat
  alias Samen.Web.Chat.{Identity, PubSub, Reads}
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    thread_id = Map.get(params, "id")

    if connected?(socket) and is_binary(thread_id) do
      PubSub.subscribe(socket.assigns.samen_mount, thread_id)
    end

    {:ok, load(assign(socket, org_id: org_id, thread_id: thread_id), org_id, thread_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    thread_id = Map.get(params, "id") || socket.assigns.thread_id
    {:noreply, load(assign(socket, org_id: org_id, thread_id: thread_id), org_id, thread_id)}
  end

  @doc false
  def load(socket, nil, _thread_id), do: assign_empty(socket)
  def load(socket, _org_id, nil), do: assign_empty(socket)

  def load(socket, org_id, thread_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    case Reads.get_thread(mount, scope, thread_id) do
      {:ok, thread} ->
        participants = Reads.participants(mount, scope, thread_id)
        resolved_participants = Identity.resolve_participants(mount, scope, thread, participants)
        messages = Reads.messages(mount, scope, thread_id)

        assign(socket,
          no_thread: false,
          org_id: org_id,
          thread_id: thread_id,
          thread: thread,
          participants: resolved_participants,
          handles: handle_map(participants),
          messages: attach_cards(mount, scope, messages),
          composer: ""
        )

      :error ->
        assign_empty(socket)
    end
  end

  # ---------------------------------------------------------------------------
  # SEND — parse refs on plaintext → persist (vault) → broadcast id-only
  # ---------------------------------------------------------------------------
  @impl true
  def handle_event("send", %{"body" => body}, socket) when is_binary(body) and body != "" do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, socket.assigns.org_id)
    party = plane_party(mount)

    with {:ok, participant_id} <- self_participant_id(socket, party),
         {:ok, message} <-
           Chat.post_message(mount, scope, %{
             org_id: socket.assigns.org_id,
             thread_id: socket.assigns.thread_id,
             participant_id: participant_id,
             sender_party: party,
             body: body
           }) do
      # Optimistically append for the sender (its own scope). Remote subscribers get the
      # broadcast → handle_info re-read.
      {:noreply, append_message(socket, mount, scope, message)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # REALTIME — the id-only broadcast re-read per THIS viewer's plane (§3.2)
  # ---------------------------------------------------------------------------
  @impl true
  def handle_info({:chat_message, envelope}, socket) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, socket.assigns.org_id)

    if envelope.thread_id == socket.assigns.thread_id do
      case Chat.read_broadcast(mount, scope, envelope) do
        {:ok, %{message: message, cards: cards}} ->
          {:noreply, push_message(socket, %{message: message, cards: cards})}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-room">
      <.app_shell>
        <:sidebar>
          <div class="side-min">
            <b>{CurrentOrg.name(@samen_mount, @org_id)}</b>
            <span>Chat</span>
          </div>
        </:sidebar>

        <%= if @no_thread do %>
          <.topbar title="Chat" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat"]} />
          <div class="wrap">
            <div class="card" id="no-thread" style="padding:22px 20px;color:var(--muted)">
              Conversation not available.
            </div>
          </div>
        <% else %>
          <.topbar
            title={@thread.subject || "Conversation"}
            crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat", @thread.subject || "Conversation"]}
          >
            <:actions>
              <span class="lane">{plane_note(@samen_mount)} · disclosure: {@thread.disclosure_mode}</span>
            </:actions>
          </.topbar>

          <div class="wrap chat-layout">
            <div class="chat-main">
              <div id="chat-messages" class="chat-messages">
                <.chat_message
                  :for={%{message: m, cards: cards} <- @messages}
                  message={m}
                  handle={Map.get(@handles, m.participant_id)}
                  cards={cards}
                  mine={m.sender_party == plane_party(@samen_mount)}
                />
              </div>

              <form class="chat-composer" phx-submit="send" id="chat-composer">
                <input type="text" name="body" placeholder="Message… (paste a samen:crm.person:<id> ref to unfurl)" autocomplete="off" />
                <.button variant="primary" type="submit">Send</.button>
              </form>
            </div>

            <aside class="chat-aside">
              <div class="gtitle"><h3>Participants</h3><span class="n">{length(@participants)}</span></div>
              <.presence_roster participants={@participants} online_ids={online_ids(@participants)} />
            </aside>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp assign_empty(socket) do
    assign(socket,
      no_thread: true,
      thread: nil,
      participants: [],
      handles: %{},
      messages: [],
      composer: ""
    )
  end

  # Attach per-viewer unfurl cards to each loaded message (first render).
  defp attach_cards(mount, scope, messages) do
    Enum.map(messages, fn m ->
      %{message: m, cards: Chat.resolve_cards(mount, scope, m.refs)}
    end)
  end

  defp append_message(socket, mount, scope, message) do
    {:ok, message} = Reads.get_message(mount, scope, message.id)
    cards = Chat.resolve_cards(mount, scope, message.refs)
    push_message(socket, %{message: message, cards: cards})
  end

  # Append one message entry to the stream-ish assign (kept simple: prepend/append list).
  defp push_message(socket, entry) do
    assign(socket, messages: socket.assigns.messages ++ [entry])
  end

  defp handle_map(participants), do: Map.new(participants, fn p -> {p.id, p.handle} end)

  defp online_ids(participants), do: Enum.map(participants, & &1.id)

  # The first participant on THIS viewer's plane is treated as "self" for the composer send.
  # (A real host wires the authenticated participant; this is the framework default seam.)
  defp self_participant_id(socket, party) do
    case Enum.find(socket.assigns.participants, fn p -> p.party == party end) do
      %{id: id} -> {:ok, id}
      _ -> :error
    end
  end

  defp plane_party(%Mount{plane: %{kind: :operator}}), do: :operator
  defp plane_party(_), do: :tenant

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator desk · masked"
  defp plane_note(_), do: "your org in the clear"
end
