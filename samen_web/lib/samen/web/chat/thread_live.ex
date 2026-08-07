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
  alias Samen.Web.Operator.Impersonation

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign_mount(session)
      |> maybe_assign_operator_identity(session, params)

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

    # T153 — the room is tenant chat CONTENT (message bodies + participant identities). On the
    # OPERATOR desk-chat plane, resolving a SPECIFIC tenant's conversation is the per-tenant
    # drill-in: it now requires a real, audited `Samen.Impersonation` session for THIS org
    # (deny-on-read), same accountability gate the other drill-ins carry (T150). Tenant: not gated.
    case gate(socket, mount, org_id) do
      :out_of_scope ->
        socket
        |> assign_empty()
        |> assign(org_id: org_id, thread_id: thread_id, impersonation: :out_of_scope, session_info: nil, open_error: nil)

      :denied ->
        socket
        |> assign_empty()
        |> assign(org_id: org_id, thread_id: thread_id, impersonation: :denied, session_info: nil, open_error: nil)

      {:ok, session_info} ->
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
              composer: "",
              impersonation: ok_state(mount),
              session_info: session_info,
              open_error: nil
            )

          :error ->
            assign(assign_empty(socket), org_id: org_id, thread_id: thread_id)
        end
    end
  end

  # The gate for the shared chat room: TENANT plane never gated (`{:ok, nil}`); OPERATOR plane
  # consults `Samen.Web.Operator.Impersonation.gate/2` keyed on the RESOLVED tenant org.
  defp gate(socket, mount, org_id) do
    if operator_plane?(mount) do
      case Impersonation.gate_socket(socket, gate_operator_id(socket), org_id) do
        {:ok, _actor, info} -> {:ok, info}
        :out_of_scope -> :out_of_scope
        :denied -> :denied
      end
    else
      {:ok, nil}
    end
  end

  defp ok_state(mount), do: if(operator_plane?(mount), do: :active, else: :tenant)

  # T153 — on the OPERATOR desk-chat plane, resolve the acting operator identity the gate keys on.
  defp maybe_assign_operator_identity(socket, session, params) do
    if operator_plane?(socket.assigns[:samen_mount]) do
      Impersonation.assign_identity(socket, session, params)
    else
      socket
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

  # T153 — the open-session-with-reason affordance the OPERATOR denied state renders.
  def handle_event("open_session", %{"reason" => reason}, socket) do
    org_id = socket.assigns[:org_id]
    operator_id = gate_operator_id(socket)

    # R-B: a scoped-out operator can never mint a session (§16.4a) — refuse before open even on
    # a crafted submit. Inert when no product scope is configured.
    if Impersonation.scope_ok?(socket, operator_id, org_id) do
      case Impersonation.open(operator_id, socket.assigns[:samen_operator_role], org_id, reason) do
        {:ok, _session} -> {:noreply, load(socket, org_id, socket.assigns[:thread_id])}
        {:error, why} -> {:noreply, assign(socket, open_error: open_error_copy(why))}
      end
    else
      {:noreply, load(socket, org_id, socket.assigns[:thread_id])}
    end
  end

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

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

        <%= cond do %>
          <% @impersonation == :out_of_scope -> %>
            <.topbar title="Chat" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat"]} />
            <div class="wrap">
              <div class="card" id="out-of-scope" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="not-in-scope">
                  This account is not in your scope.
                </div>
                <p style="color:var(--muted);margin:10px 0 0;font-size:13px">
                  Your operator assignment does not cover this tenant, so its conversations are not
                  available to you and no impersonation session can be opened for it.
                </p>
              </div>
            </div>
          <% @impersonation == :denied -> %>
            <.topbar title="Chat" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat"]} />
            <div class="wrap">
              <div class="card" id="impersonation-required" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="no-session">
                  Access denied — no active impersonation session for this tenant.
                </div>
                <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                  Reading a specific tenant's conversation is a per-tenant drill-in: it requires a
                  short-TTL, reason-required <b>impersonation session</b>, recorded in the tenant's
                  audit ledger (who / when / why). Start one below — the conversation still renders masked.
                </p>
                <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">
                  {@open_error}
                </div>
                <form phx-submit="open_session" id="open-session-form" style="display:flex;gap:8px;align-items:flex-start">
                  <input
                    type="text"
                    name="reason"
                    id="session-reason-input"
                    placeholder="Reason (e.g. ticket #1234: dispatch dispute)"
                    style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px"
                  />
                  <button type="submit" id="start-session-btn" style="padding:8px 14px;border-radius:8px;background:#3B4CCA;color:#fff;font-size:13px">
                    Start session (masked)
                  </button>
                </form>
              </div>
            </div>
          <% @no_thread -> %>
            <.topbar title="Chat" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat"]} />
            <div class="wrap">
              <div class="card" id="no-thread" style="padding:22px 20px;color:var(--muted)">
                Conversation not available.
              </div>
            </div>
          <% true -> %>
            <.topbar
              title={@thread.subject || "Conversation"}
              crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat", @thread.subject || "Conversation"]}
            >
              <:actions>
                <span class="lane">{plane_note(@samen_mount)} · disclosure: {@thread.disclosure_mode}</span>
              </:actions>
            </.topbar>

            <div :if={@session_info} id="session-accountability" class="wrap" style="padding-bottom:0">
              <div class="card" style="padding:10px 14px;font-size:12px;color:var(--muted)">
                <b style="color:inherit">Masked impersonation session.</b>
                operator <span class="mono">{@session_info.operator_id}</span>
                · reason: <span id="session-reason">{@session_info.reason}</span>
                · expires <span id="session-expiry">{@session_info.expires_at}</span>
                — recorded in this tenant's audit ledger.
              </div>
            </div>

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
      composer: "",
      impersonation: :none,
      session_info: nil,
      open_error: nil
    )
  end

  # T153 gate plumbing (see `Samen.Web.Chat.ThreadsLive` for the identity-resolution note).
  defp operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  defp operator_plane?(_), do: false

  defp gate_operator_id(socket) do
    present(socket.assigns[:samen_operator_id]) || plane_operator_id(socket.assigns[:samen_mount])
  end

  defp plane_operator_id(%Mount{plane: %{operator_id: id}}), do: id
  defp plane_operator_id(_), do: nil

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present(_), do: nil

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
