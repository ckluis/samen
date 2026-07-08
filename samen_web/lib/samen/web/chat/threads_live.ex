defmodule Samen.Web.Chat.ThreadsLive do
  @moduledoc """
  Framework Chat / inbox (ADR-012 §6.1) — lists the mount's chat threads for the current org,
  on the mount's plane. A tenant mount lists the org's own threads (clear); an operator-desk
  mount (impersonation over a tenant org) lists the SAME tenant-owned threads (cross-plane).

  No PII on the thread header (subject/kind/status), so the list itself is plane-neutral; the
  masking lives in the room (`Samen.Web.Chat.ThreadLive`) where bodies + identities render.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2]

  alias Samen.Web.Chat
  alias Samen.Web.Chat.Reads
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = Map.get(params, "org")
    {:ok, load(assign(socket, org_id: org_id, flash_note: nil), org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_flash()
    |> assign(no_org: true, org_id: nil, threads: [], expose_identity: false)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_flash()
    |> assign(
      no_org: false,
      org_id: org_id,
      threads: Reads.threads(mount, scope),
      expose_identity: Chat.disclosure_setting?(mount, scope)
    )
  end

  # `load/2` is called both from `mount/3` (flash already nil) and directly from the render
  # test harness (which never runs `mount/3`); default the flash so `render/1` is total.
  defp ensure_flash(socket) do
    if Map.has_key?(socket.assigns, :flash_note),
      do: socket,
      else: assign(socket, flash_note: nil)
  end

  # ---------------------------------------------------------------------------
  # The 3-state identity model, WRITE side (§5) — inherited by every host's inbox.
  # These events run only on the TENANT plane (the operator desk gets a read-only inbox;
  # a masked operator can neither flip an org's setting nor open a tenant conversation).
  # ---------------------------------------------------------------------------

  # State 3 — the tenant-wide setting: admin toggles org-wide identity disclosure to support.
  @impl true
  def handle_event("toggle_disclosure", params, socket) do
    if tenant_plane?(socket) do
      expose? = params["expose_identity"] in [true, "true", "on"]
      mount = socket.assigns.samen_mount
      scope = Mount.scope(mount, socket.assigns.org_id)

      case Chat.set_disclosure_setting(mount, scope, expose?) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> assign(expose_identity: expose?)
           |> assign(flash_note: disclosure_note(expose?))}

        {:error, _} ->
          {:noreply, assign(socket, flash_note: "Not permitted — admin only.")}
      end
    else
      {:noreply, socket}
    end
  end

  # State 2 — start a conversation with the per-conversation initiator opt-in.
  def handle_event("new_conversation", %{"subject" => subject} = params, socket)
      when is_binary(subject) and subject != "" do
    if tenant_plane?(socket) do
      mount = socket.assigns.samen_mount
      scope = Mount.scope(mount, socket.assigns.org_id)
      share? = params["share_identity"] in [true, "true", "on"]

      case Chat.start_conversation(mount, scope, %{
             org_id: socket.assigns.org_id,
             subject: subject,
             handle: default_handle(params),
             full_name: default_full_name(params),
             share_identity: share?
           }) do
        {:ok, _thread} ->
          {:noreply,
           socket
           |> load(socket.assigns.org_id)
           |> assign(flash_note: new_conversation_note(share?))}

        {:error, _} ->
          {:noreply, assign(socket, flash_note: "Could not start conversation.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_conversation", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-threads">
      <.app_shell>
        <:sidebar>
          <div class="side-min">
            <b>{Mount.label(@samen_mount, :title, "Workspace")}</b>
            <span>Chat</span>
          </div>
        </:sidebar>

        <.topbar title="Chat" crumbs={[Mount.label(@samen_mount, :crumb_root, "Workspace"), "Chat"]}>
          <:actions>
            <span class="lane">{plane_note(@samen_mount)}</span>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
        <% else %>
          <div class="wrap">
            <div :if={@flash_note} id="chat-flash" class="chat-flash">{@flash_note}</div>

            <%= if tenant_plane?(assigns) do %>
              <div class="card chat-settings" id="chat-identity-setting" style="margin-bottom:16px">
                <div class="gtitle" style="margin-top:0">
                  <h3>Identity disclosure to support</h3>
                  <.pill variant={if @expose_identity, do: "info", else: "mut"}>
                    {if @expose_identity, do: "org-wide", else: "masked"}
                  </.pill>
                </div>
                <p style="color:var(--muted);margin:6px 0 12px">
                  When ON, SaaS support sees the REAL identity of your team's chat participants
                  (state 3, tenant-wide). When OFF, participants stay <code>••••</code> unless the
                  person who starts a conversation opts to share their own name (state 2).
                </p>
                <form phx-change="toggle_disclosure" id="disclosure-form">
                  <label class="chat-switch">
                    <input
                      type="checkbox"
                      name="expose_identity"
                      checked={@expose_identity}
                      id="expose-identity-toggle"
                    />
                    <span>Expose participant identity to SaaS support (tenant-wide)</span>
                  </label>
                </form>
              </div>

              <div class="card chat-new" id="chat-new-conversation" style="margin-bottom:16px">
                <div class="gtitle" style="margin-top:0"><h3>New conversation</h3></div>
                <form phx-submit="new_conversation" id="new-conversation-form">
                  <input type="text" name="subject" placeholder="Subject…" autocomplete="off" required />
                  <input type="text" name="handle" placeholder="Your handle (e.g. dispatch)" autocomplete="off" />
                  <label class="chat-switch" style="margin:10px 0">
                    <input type="checkbox" name="share_identity" id="share-identity-optin" />
                    <span>Share MY identity with support for this conversation (initiator opt-in)</span>
                  </label>
                  <.button variant="primary" type="submit">Start conversation</.button>
                </form>
              </div>
            <% end %>

            <div id="threads">
              <div class="gtitle">
                <h3>Conversations</h3>
                <span class="n">{length(@threads)}</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:50%">Subject</th>
                  <th style="width:20%">Kind</th>
                  <th style="width:15%">Status</th>
                  <th style="width:15%">Disclosure</th>
                </:head>
                <tr :for={t <- @threads} class="thread-row" id={"thread-#{t.id}"}>
                  <td>
                    <a href={thread_path(@samen_mount, @org_id, t.id)} style="color:#3B4CCA;text-decoration:none">
                      {t.subject || "Conversation"}
                    </a>
                  </td>
                  <td style="color:var(--muted)">{t.kind}</td>
                  <td><.pill variant={status_variant(t.status)}>{t.status}</.pill></td>
                  <td style="color:var(--muted)">{t.disclosure_mode}</td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp thread_path(mount, org_id, id),
    do: "#{Mount.label(mount, :chat_path, "/chat")}/#{id}?org=#{org_id}"

  defp status_variant(:open), do: "ok"
  defp status_variant(_), do: "mut"

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator desk · masked"
  defp plane_note(_), do: "your org in the clear"

  # The write-side identity controls are TENANT-plane only: a masked operator can neither flip
  # an org's disclosure setting nor open a tenant conversation on the tenant's behalf. Accepts
  # either a `%Socket{}` (from `handle_event`) or an `assigns` map (from `render/1`).
  defp tenant_plane?(%Phoenix.LiveView.Socket{assigns: assigns}), do: tenant_plane?(assigns)
  defp tenant_plane?(%{samen_mount: %Mount{plane: %{kind: :operator}}}), do: false
  defp tenant_plane?(%{samen_mount: %Mount{}}), do: true
  defp tenant_plane?(_), do: false

  defp default_handle(%{"handle" => h}) when is_binary(h) and h != "", do: h
  defp default_handle(_), do: "tenant"

  defp default_full_name(%{"first" => f, "last" => l}) when is_binary(f) and is_binary(l),
    do: %Samen.Type.FullName{first: f, last: l}

  defp default_full_name(_), do: nil

  defp disclosure_note(true),
    do: "Identity disclosure ON — support sees participant identities on NEW conversations."

  defp disclosure_note(false),
    do: "Identity disclosure OFF — participants are masked to support (masked floor)."

  defp new_conversation_note(true),
    do: "Conversation started — you shared YOUR identity with support (initiator opt-in)."

  defp new_conversation_note(false),
    do: "Conversation started — your identity stays masked to support."
end
