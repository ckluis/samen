defmodule Samen.Web.Notifications.InboxLive do
  @moduledoc """
  Framework NOTIFICATIONS INBOX — 🔒 PII: `rendered_body` (vault `:pii_body`) —
  WS-A design §2.4, ADR-016 §4. Mounted at `/notifications` by
  `Samen.Web.Router.samen_notifications_routes/3` so every vertical inherits it, on
  BOTH planes (tenant clear / operator drill-in masked).

  ## The A2/A3 kit contract

  Built on `Samen.Web.ListLive` + `list_view/1` (bounded reads BY CONSTRUCTION):
  `Reads.notifications_page/3` routes through `Samen.Web.Reads.page!/3`, so this view
  carries NO `handle_event/3` for list ergonomics and NO unbounded read. The empty
  state is the kit default.

  ## Realtime (the mandated chat pattern, ADR-012 §3 / Invariant N1)

  `mount/3` (connected) subscribes to the org's notifications topic. The broadcast
  envelope is **id-only** — the vaulted body NEVER transits PubSub. On
  `{:notification_created, %{id}}` this view RE-READS that notification through its
  OWN scope (`Reads.get_notification/3`), so the body resolves per the RECEIVING
  viewer's plane: a tenant session gets the clear body, an operator session gets
  `%Masked{}` (→ `••••`) — from the SAME broadcast. Masking survives the realtime
  path by construction. A cross-org envelope re-reads to zero rows under OrgScope and
  is ignored (no existence oracle).

  ## Masking (MC-3 + MC-4)

    * **MC-3 (body):** `rendered_body` reaches this view ALREADY RESOLVED through
      `Samen.Api.PiiResolution` (in `Reads`). A `%Samen.Masked{}` renders `••••` via
      `Phoenix.HTML.Safe`. This LiveView NEVER calls `Samen.Vault.reveal/3`, never
      unwraps a `%Masked{}`, and has no "show plaintext" branch.
    * **MC-4 (unfurl):** a notification's `metadata["subject_ref"]`
      (`samen:crm.person:<id>`) unfurls through the EXISTING
      `Samen.Web.ObjectRef.resolve/3 → object_card` path — every field resolved
      through `PiiResolution` per viewer plane, org-scoped by the kernel policy. The
      notification card is per-viewer masked BY CONSTRUCTION (operator `••••`,
      tenant clear); a cross-org/unknown ref renders the inert "not available" chip.

  ## Unread badge (AC-G2-7)

  `Reads.unread_count/2` feeds the sidebar `nav_item` `count` affordance; `mark_read`
  / `mark_all_read` (tenant-plane affordances; kernel-enforced writes that touch NO
  vaulted attribute) decrement it, and a realtime envelope re-count increments it.
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.Notifications.Live,
    only: [assign_mount: 2, notifications_sidebar: 1, writable?: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.PubSub, as: NotificationsPubSub
  alias Samen.Web.Notifications.Reads
  alias Samen.Web.ObjectRef

  use Samen.Web.ListLive,
    resource: Notification,
    reads: &Samen.Web.Notifications.Reads.notifications_page/3,
    sortable: [:inserted_at, :event_type, :status],
    filter_fields: [:event_type],
    default_sort: {:inserted_at, :desc}

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    # Realtime: subscribe to the org's notifications topic (id-only envelopes;
    # Invariant N1). Tolerates a missing PubSub server (dead render / plain test).
    if connected?(socket) and org_id != nil do
      NotificationsPubSub.subscribe_org(socket.assigns.samen_mount, org_id)
    end

    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> default_return_to()
    |> assign(no_org: no_org?(socket), org_id: nil, unread_count: 0)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> default_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign(unread_count: Reads.unread_count(mount, scope))
    |> init_list(mount, scope)
  end

  # -- events (list events belong to the ListLive hook) -------------------------

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    _ = Reads.mark_read(mount, Mount.scope(mount, org_id), id)
    {:noreply, refresh(socket)}
  end

  def handle_event("mark_all_read", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    _ = Reads.mark_all_read(mount, Mount.scope(mount, org_id))
    {:noreply, refresh(socket)}
  end

  # -- realtime ------------------------------------------------------------------

  # The id-only envelope (Invariant N1). Re-read THAT notification through THIS
  # session's OWN scope — the per-plane masking re-read (design §2.4). A cross-org /
  # unreadable id resolves to :error and is ignored (OrgScope; no existence oracle).
  @impl true
  def handle_info({:notification_created, %{id: id}}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case org_id && Reads.get_notification(mount, Mount.scope(mount, org_id), id) do
      {:ok, _notification} -> {:noreply, refresh(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Re-run the CURRENT bounded read (preserving sort/filter/cursor — unlike a full
  # load/2, which would reset the list state) and re-count the badge.
  defp refresh(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)
    state = socket.assigns.list_state
    page = Reads.notifications_page(mount, scope, state)

    assign(socket,
      page: %{page | prev_cursor: List.first(state.cursor_stack)},
      unread_count: Reads.unread_count(mount, scope)
    )
  end

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  defp default_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notifications-inbox">
      <.app_shell>
        <:sidebar>
          <.notifications_sidebar
            mount={@samen_mount}
            org_id={@org_id}
            active={:notifications}
            return_to={@return_to}
            unread={@unread_count}
          />
        </:sidebar>

        <.topbar title="Notifications" crumbs={crumbs(@samen_mount, @org_id)}>
          <:actions>
            <.button
              :if={writable?(@samen_mount) and not @no_org and @unread_count > 0}
              variant="primary"
              phx-click="mark_all_read"
              id="mark-all-read"
            >
              Mark all read
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Notifications org: {@org_id}</span>

          <div class="wrap">
            <div id="notifications-panel">
              <div class="gtitle">
                <h3>Inbox</h3>
                <span class="n" id="notifications-unread">{@unread_count}</span>
                <span class="lane">unread · body via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="notifications"
                page={@page}
                state={@list_state}
                row_class="notification-row"
                filter_placeholder="Filter by event type…"
                empty_text="No notifications yet."
                empty_icon="✶"
                empty_body="System events, mentions, and SLA alerts land here as they happen — nothing needs your attention yet."
              >
                <:head>
                  <.sort_header field={:event_type} label="Event" sort={@list_state.sort} width="16%" />
                  <th scope="col" style="width:44%">Notification</th>
                  <th scope="col" style="width:10%">Channel</th>
                  <.sort_header field={:inserted_at} label="Received" sort={@list_state.sort} width="16%" />
                  <th scope="col" style="width:14%"><span class="sr-only">Read state</span></th>
                </:head>
                <:row :let={n}>
                  <td class="n-event">
                    <span class="n-event-type" style="font-size:12px;font-weight:600">{n.event_type}</span>
                  </td>
                  <td class="n-body-cell">
                    <span class="n-body">{n.rendered_body || "—"}</span>
                    <.subject_card mount={@samen_mount} org_id={@org_id} notification={n} />
                  </td>
                  <td class="n-channel" style="font-size:12px;color:var(--muted)">{n.channel}</td>
                  <td class="n-received" style="font-size:12px;color:var(--muted)">{received_at(n)}</td>
                  <td class="n-read">
                    <%= if n.read_at do %>
                      <span class="n-read-state" style="font-size:12px;color:var(--muted)">read</span>
                    <% else %>
                      <span class="n-unread-dot" aria-label="unread" style="color:#B45309;font-weight:700">●</span>
                      <.button
                        :if={writable?(@samen_mount)}
                        phx-click="mark_read"
                        phx-value-id={n.id}
                        aria-label="Mark read"
                      >
                        Mark read
                      </.button>
                    <% end %>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- unfurl (MC-4) -------------------------------------------------------------

  # A notification's subject_ref unfurls through the EXISTING ObjectRef path — the
  # resolve is org-scoped (kernel OrgScope) and every field is plane-resolved
  # (PiiResolution), so the card is per-viewer masked BY CONSTRUCTION. Resolved at
  # render time so EVERY page (initial, sorted, filtered, realtime-refreshed) unfurls
  # per the CURRENT viewer — bounded by the page size. No ref → no card.
  attr :mount, Mount, required: true
  attr :org_id, :string, required: true
  attr :notification, :any, required: true

  defp subject_card(assigns) do
    assigns = assign(assigns, :card, unfurl(assigns.mount, assigns.org_id, assigns.notification))

    ~H"""
    <div :if={@card} class="n-subject" style="margin-top:4px">
      <.object_card card={@card} />
    </div>
    """
  end

  # nil (no ref / malformed ref) | {:ok, card} → the card | {:error, _} → the inert
  # chip. NEVER plaintext on failure; never a raise.
  defp unfurl(mount, org_id, notification) do
    with %{} = metadata <- notification.metadata,
         ref_string when is_binary(ref_string) <- Map.get(metadata, "subject_ref"),
         {:ok, ref} <- ObjectRef.from_string(ref_string) do
      case ObjectRef.resolve(mount, Mount.scope(mount, org_id), ref) do
        {:ok, card} -> card
        {:error, _} = error -> error
      end
    else
      _ -> nil
    end
  end

  defp crumbs(mount, org_id), do: [CurrentOrg.name(mount, org_id), "Inbox", "Notifications"]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

  defp received_at(%{sent_at: %DateTime{} = at}), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  defp received_at(%{inserted_at: %DateTime{} = at}),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  defp received_at(_), do: "—"
end
