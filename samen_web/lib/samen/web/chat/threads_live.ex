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
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, switcher: 1, return_path: 1]

  alias Samen.Web.Chat
  alias Samen.Web.Chat.Reads
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
    {:ok, load(assign(socket, org_id: org_id, flash_note: nil), org_id)}
  end

  # T153 — on the OPERATOR desk-chat plane, resolve the acting operator identity the
  # impersonation-session gate keys on (same seam the other per-tenant drill-ins use). The
  # TENANT plane never gates → left untouched (no new assigns, byte-for-byte the old mount).
  defp maybe_assign_operator_identity(socket, session, params) do
    if operator_plane?(socket.assigns[:samen_mount]) do
      Impersonation.assign_identity(socket, session, params)
    else
      socket
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_flash()
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, threads: [], expose_identity: false)
    # No tenant resolved → nothing to gate; render the no-org card, never the denied panel.
    |> assign(impersonation: :none, session_info: nil, open_error: nil)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount

    # T153 — the desk-chat inbox lists ONE resolved tenant's threads. On the OPERATOR plane that
    # is a per-tenant drill-in (peering into one tenant's conversation list) → it now requires a
    # real, audited `Samen.Impersonation` session for THIS org (deny-on-read), same accountability
    # gate the deliverability/automation/activity drill-ins carry (T150). Tenant plane: not gated.
    case gate(socket, mount, org_id) do
      :out_of_scope ->
        socket
        |> ensure_flash()
        |> ensure_return_to()
        |> assign(no_org: false, org_id: org_id, threads: [], expose_identity: false)
        |> assign(impersonation: :out_of_scope, session_info: nil, open_error: nil)

      :denied ->
        socket
        |> ensure_flash()
        |> ensure_return_to()
        |> assign(no_org: false, org_id: org_id, threads: [], expose_identity: false)
        |> assign(impersonation: :denied, session_info: nil, open_error: nil)

      {:ok, session_info} ->
        scope = Mount.scope(mount, org_id)

        socket
        |> ensure_flash()
        |> ensure_return_to()
        |> assign(
          no_org: false,
          org_id: org_id,
          threads: Reads.threads(mount, scope),
          expose_identity: Chat.disclosure_setting?(mount, scope)
        )
        |> assign(impersonation: ok_state(mount), session_info: session_info, open_error: nil)
    end
  end

  # The gate for the shared chat LiveView: TENANT plane is never gated (`{:ok, nil}` → render as
  # before); OPERATOR plane consults `Samen.Web.Operator.Impersonation.gate/2` keyed on the
  # RESOLVED tenant org (deny-on-read). Only the `{:ok, _} | :denied` distinction is used here —
  # the chat scope/masking is built from the mount, not the gate actor.
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

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
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

  # T153 — the open-session-with-reason affordance the OPERATOR denied state renders. Opens a
  # REAL `Samen.Impersonation` session (reason required, same-tx audit + auto-expire, tenant-
  # visible ledger) for the acting operator over this tenant org, then re-renders the inbox.
  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    org_id = socket.assigns[:org_id]
    operator_id = gate_operator_id(socket)

    # R-B: a scoped-out operator can never mint a session (§16.4a) — refuse before open. Inert
    # when no product scope is configured.
    if Impersonation.scope_ok?(socket, operator_id, org_id) do
      case Impersonation.open(operator_id, socket.assigns[:samen_operator_role], org_id, reason) do
        {:ok, _session} -> {:noreply, load(socket, org_id)}
        {:error, why} -> {:noreply, assign(socket, open_error: open_error_copy(why))}
      end
    else
      {:noreply, load(socket, org_id)}
    end
  end

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-threads">
      <.app_shell>
        <:sidebar>
          <div class="side-min">
            <b>{CurrentOrg.name(@samen_mount, @org_id)}</b>
            <span>Chat</span>
            <.switcher :if={tenant_plane?(assigns)} mount={@samen_mount} org_id={@org_id} return_to={@return_to} compact />
          </div>
        </:sidebar>

        <.topbar title="Chat" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Chat"]}>
          <:actions>
            <span class="lane">{plane_note(@samen_mount)}</span>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= cond do %>
          <% @impersonation == :out_of_scope -> %>
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
          <div class="wrap">
            <div class="card" id="impersonation-required" style="padding:22px 20px">
              <div style="color:var(--red);font-weight:600" id="no-session">
                Access denied — no active impersonation session for this tenant.
              </div>
              <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                Reading a specific tenant's chat is a per-tenant drill-in: it requires a short-TTL,
                reason-required <b>impersonation session</b>, recorded in the tenant's audit ledger
                (who / when / why). Start one below — the conversation still renders masked.
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
          <% true -> %>
          <%= if @no_org do %>
            <.no_org_card mount={@samen_mount} />
          <% else %>
          <div class="wrap">
            <div :if={@flash_note} id="chat-flash" class="chat-flash">{@flash_note}</div>

            <div :if={@session_info} id="session-accountability" class="card" style="padding:10px 14px;margin-bottom:12px;font-size:12px;color:var(--muted)">
              <b style="color:inherit">Masked impersonation session.</b>
              operator <span class="mono">{@session_info.operator_id}</span>
              · reason: <span id="session-reason">{@session_info.reason}</span>
              · expires <span id="session-expiry">{@session_info.expires_at}</span>
              — recorded in this tenant's audit ledger.
            </div>

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
              <.empty_state
                :if={@threads == []}
                class="threads-empty"
                icon="❝"
                title="No conversations yet."
                body="Start a conversation above — it shows up here for both sides of the thread."
              />
              <.data_table :if={@threads != []}>
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

  # T153 gate plumbing. `operator_plane?/1` inspects the MOUNT (not assigns), so it is total
  # for `load/2` (which only carries `:samen_mount`). The acting operator id keying the gate is
  # the authenticated operator principal (`:samen_operator_id`, production) OR — for the desk
  # mount whose plane BAKES the acting operator id at config time — the plane's `operator_id`.
  defp operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  defp operator_plane?(_), do: false

  defp gate_operator_id(socket) do
    present(socket.assigns[:samen_operator_id]) || plane_operator_id(socket.assigns[:samen_mount])
  end

  defp plane_operator_id(%Mount{plane: %{operator_id: id}}), do: id
  defp plane_operator_id(_), do: nil

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present(_), do: nil

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
