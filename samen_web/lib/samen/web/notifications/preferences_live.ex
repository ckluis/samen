defmodule Samen.Web.Notifications.PreferencesLive do
  @moduledoc """
  Framework NOTIFICATION PREFERENCES — the `/notifications/settings` panel (WS-A
  design §2.4 "Preferences UI"; ADR-016 §4) every vertical inherits via
  `Samen.Web.Router.samen_notifications_routes/3`. NO PII on this surface: a
  `NotificationPreference` row is a bounded id + enums + bools by construction.

  ## Per-event-type granularity (the design contract)

  One toggle row per EVENT TYPE × channel (in-app / email), over the kernel
  `NotificationPreference` resource. The grid is the union of the framework's
  wired event sources (SLA breach, chat mentions, the send/invoice system events)
  and any event types the recipient already holds rows for — so a host-minted
  event type never becomes invisible/unmanageable. Absent a row, the engine
  defaults apply and are shown honestly: in-app ON (opt-out), email OFF (opt-in).

  ## The write path (A2 kit; kernel-enforced)

  The grid is a kit `simple_form/1` of `form_field/1` selects (`phx-change` — each
  toggle persists immediately via `Reads.set_preference/4`, an Ash upsert under
  `OrgScope` + `RoleAtLeast :member`). This LiveView adds NO policy of its own;
  the operator/impersonation plane gets a read-only grid (`writable?/1` posture —
  disabled controls, no save handling) and the kernel policy enforces regardless.

  ## The recipient seam

  Preferences are PER-RECIPIENT (`recipient_id`, an opaque UUID). The framework
  resolves it from the mount's `:recipient_id` label (the host wires its
  authenticated user — the same seam posture as chat's participant identity) or a
  `?recipient=` param; with NEITHER, the panel renders an honest "no recipient
  wired" card rather than guessing an identity.
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.Notifications.Live,
    only: [assign_mount: 2, notifications_sidebar: 1, writable?: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.Reads

  # The framework's WIRED event sources (design §2.3): SLA breach, chat mentions,
  # and the listed system events (blocked/failed sends, invoice state changes).
  # Bounded labels — a host's extra event types join the grid via existing rows.
  @default_event_types [
    {"sla_breach", "Support SLA breach"},
    {"chat_mention", "Chat mention"},
    {"marketing.send.blocked", "Marketing send blocked"},
    {"marketing.send.failed", "Marketing send failed"},
    {"invoice.open", "Invoice issued"},
    {"invoice.paid", "Invoice paid"}
  ]

  @doc false
  def default_event_types, do: @default_event_types

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id, recipient_id(socket, params))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)

    {:noreply,
     load(
       assign(socket, org_id: org_id, return_to: return_path(uri)),
       org_id,
       recipient_id(socket, params)
     )}
  end

  # The recipient seam: an explicit ?recipient= param wins; else the host-wired
  # mount label; else nil (the honest "no recipient wired" card).
  defp recipient_id(socket, params) do
    Map.get(params, "recipient") ||
      Mount.label(socket.assigns.samen_mount, :recipient_id, nil) ||
      socket.assigns[:recipient_id]
  end

  @doc false
  def load(socket, nil, _recipient_id) do
    socket
    |> default_return_to()
    |> assign(no_org: no_org?(socket), org_id: nil, recipient_id: nil, rows: [], form: blank_form())
  end

  def load(socket, org_id, nil) do
    socket
    |> default_return_to()
    |> assign(no_org: false, org_id: org_id, recipient_id: nil, rows: [], form: blank_form())
  end

  def load(socket, org_id, recipient_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    prefs = Reads.preferences(mount, scope, recipient_id)
    rows = grid_rows(prefs)

    socket
    |> default_return_to()
    |> assign(no_org: false, org_id: org_id, recipient_id: recipient_id)
    |> assign(rows: rows, form: to_form(form_params(rows), as: :prefs))
  end

  # -- events ----------------------------------------------------------------

  @impl true
  def handle_event("save", %{"_target" => ["prefs", field]} = params, socket) do
    %{samen_mount: mount, org_id: org_id, recipient_id: recipient_id} = socket.assigns

    with true <- writable?(mount) and org_id != nil and recipient_id != nil,
         {:ok, event_type, changes} <- toggle_changes(field, get_in(params, ["prefs", field])) do
      _ =
        Reads.set_preference(mount, Mount.scope(mount, org_id), %{
          org_id: org_id,
          recipient_id: recipient_id,
          event_type: event_type,
          changes: changes
        })

      {:noreply, load(socket, org_id, recipient_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # "chat_mention__in_app" → {:ok, "chat_mention", %{in_app_enabled: bool}}.
  # Event types never contain "__" (bounded dotted/underscored labels), so the
  # LAST "__" segment is the channel — reject anything else (no oracle, no crash).
  defp toggle_changes(field, value) when is_binary(field) do
    enabled = value == "on"

    case String.split(field, "__") do
      parts when length(parts) >= 2 ->
        case List.last(parts) do
          "in_app" -> {:ok, event_of(parts), %{in_app_enabled: enabled}}
          "email" -> {:ok, event_of(parts), %{email_enabled: enabled}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp toggle_changes(_field, _value), do: :error

  defp event_of(parts), do: parts |> Enum.drop(-1) |> Enum.join("__")

  # -- grid shaping ------------------------------------------------------------

  # Union of the framework event types and the recipient's existing rows, each
  # carrying the EFFECTIVE values (engine defaults where no row exists).
  defp grid_rows(prefs) do
    by_event = Map.new(prefs, fn p -> {p.event_type, p} end)

    known = Enum.map(@default_event_types, fn {event, label} -> {event, label} end)

    extra =
      prefs
      |> Enum.map(& &1.event_type)
      |> Enum.reject(fn event -> Enum.any?(known, fn {e, _} -> e == event end) end)
      |> Enum.sort()
      |> Enum.map(fn event -> {event, event} end)

    Enum.map(known ++ extra, fn {event, label} ->
      pref = Map.get(by_event, event)

      %{
        event_type: event,
        label: label,
        in_app: if(pref, do: pref.in_app_enabled, else: true),
        email: if(pref, do: pref.email_enabled, else: false),
        explicit: pref != nil
      }
    end)
  end

  defp form_params(rows) do
    Map.new(
      Enum.flat_map(rows, fn row ->
        [
          {"#{row.event_type}__in_app", on_off(row.in_app)},
          {"#{row.event_type}__email", on_off(row.email)}
        ]
      end)
    )
  end

  defp blank_form, do: to_form(%{}, as: :prefs)

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  defp default_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notification-preferences">
      <.app_shell>
        <:sidebar>
          <.notifications_sidebar
            mount={@samen_mount}
            org_id={@org_id}
            active={:notifications}
            return_to={@return_to}
          />
        </:sidebar>

        <.topbar title="Notification settings" crumbs={crumbs(@samen_mount, @org_id)} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="preferences-panel" class="card" style="padding:18px 20px">
              <div class="gtitle">
                <h3>Notification preferences</h3>
                <span class="lane">per event type · in-app default on · email opt-in · {plane_note(@samen_mount)}</span>
              </div>

              <%= if @recipient_id == nil do %>
                <div id="no-recipient" style="padding:14px 0;color:var(--muted)">
                  No recipient is wired on this mount. Pass a <code>:recipient_id</code>
                  mount label (the authenticated user) or a <code>?recipient=</code> param
                  to manage per-user notification preferences.
                </div>
              <% else %>
                <span id="preferences-recipient" style="display:none">{@recipient_id}</span>
                <.simple_form for={@form} id="preferences-form" phx-change="save">
                  <table class="tbl" id="preferences-grid">
                    <thead>
                      <tr>
                        <th scope="col" style="width:50%">Event</th>
                        <th scope="col" style="width:25%">In-app</th>
                        <th scope="col" style="width:25%">Email</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={row <- @rows} id={"pref-#{row.event_type}"} class="pref-row">
                        <td>
                          <span style="font-weight:600;font-size:13px">{row.label}</span>
                          <span class="pref-event" style="display:block;font-size:11px;color:var(--muted)">
                            {row.event_type}<span :if={!row.explicit}> · default</span>
                          </span>
                        </td>
                        <td>
                          <.form_field
                            field={@form["#{row.event_type}__in_app"]}
                            type="select"
                            options={[{"On", "on"}, {"Off", "off"}]}
                            disabled={!writable?(@samen_mount)}
                          />
                        </td>
                        <td>
                          <.form_field
                            field={@form["#{row.event_type}__email"]}
                            type="select"
                            options={[{"On", "on"}, {"Off", "off"}]}
                            disabled={!writable?(@samen_mount)}
                          />
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </.simple_form>
                <p style="margin-top:10px;font-size:12px;color:var(--muted)">
                  Toggles save immediately. An event switched off writes no notification
                  record at all (suppressed at dispatch, not hidden in the inbox).
                </p>
              <% end %>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id),
    do: [CurrentOrg.name(mount, org_id), "Inbox", "Notification settings"]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · read-only"
  defp plane_note(_), do: "your org"
end
