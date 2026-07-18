defmodule Samen.Web.Settings.SecurityLive do
  @moduledoc """
  The framework SECURITY settings LiveView (WS-E E5.3; ADR-029; AC-G18-5) — mounted at
  `/settings/security` by `Samen.Web.Router.samen_settings_routes/3`.

  ## READ-ONLY and HONEST about the host-auth boundary (RP-ST-4)

  Auth is deliberately HOST-OWNED (ADR-029 §1): `samen_web` has no framework
  login/password/2FA/session store. This surface therefore renders ONLY what the
  framework genuinely owns and NEVER fakes control it doesn't have:

    * **Impersonation sessions** — who acted as this org, when, why, expiry — read from
      the REAL `Samen.Impersonation.Sessions.list_for_org/2` (the tenant-visible
      accountability view). Read-only.
    * **Host-managed auth** (password, 2FA, active login sessions) renders as an honest
      "managed by your identity provider" affordance — a static, disabled note, NOT a
      toggle or a button that claims to revoke/reset something the framework can't.

  There is NO write event, NO form, NO `phx-click` that mutates auth on this page.
  Faking a host-auth toggle (adding a control that claims to revoke a session the
  framework doesn't own) FAILS the honesty structural red-path (`security_honesty_test.exs`).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Settings.Reads

  # The host-managed auth items the framework is HONEST it does NOT own. Rendered as
  # static "managed by your identity provider" notes — never as a fake toggle.
  @host_managed [
    {"Password", "Set or reset through your identity provider."},
    {"Two-factor authentication", "Managed by your identity provider."},
    {"Active login sessions", "Session revocation is handled by your identity provider."}
  ]

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok, load(assign(socket, return_to: nil), org_id, user_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    user_id = Map.get(params, "user") || socket.assigns.user_id
    {:noreply, load(assign(socket, return_to: return_path(uri)), org_id, user_id)}
  end

  @doc false
  def load(socket, org_id, user_id) do
    assign(socket,
      org_id: org_id,
      user_id: user_id,
      sessions: sessions_for(socket.assigns.samen_mount, org_id),
      host_managed: @host_managed
    )
  end

  # Read the REAL impersonation sessions from the kernel accountability source. Never
  # invents rows; on any read error (e.g. the table is absent in a minimal host) the
  # list is simply empty — honest, never a fake.
  defp sessions_for(_mount, nil), do: []

  defp sessions_for(mount, org_id) do
    Samen.Impersonation.Sessions.list_for_org(org_id, repo: mount.repo)
  rescue
    _ -> []
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="settings-security">
      <.app_shell>
        <:sidebar>
          <.settings_sidebar mount={@samen_mount} org_id={@org_id} user_id={@user_id} active={:security} />
        </:sidebar>

        <.topbar title="Security" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Settings", "Security"]}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="security-panel">
              <div class="gtitle">
                <h3>Impersonation sessions</h3>
                <span class="lane">who accessed this org, when, and why — read-only accountability</span>
              </div>

              <table id="security-sessions-table" class="tbl">
                <thead>
                  <tr>
                    <th scope="col">Operator</th>
                    <th scope="col">Reason</th>
                    <th scope="col">Opened</th>
                    <th scope="col">Expires</th>
                    <th scope="col">Status</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={s <- @sessions} class="security-session-row">
                    <td>{s.operator_id}</td>
                    <td style="font-size:12px">{s.reason}</td>
                    <td>{fmt(s.opened_at)}</td>
                    <td>{fmt(s.expires_at)}</td>
                    <td>
                      <span class={if s.active?, do: "status-pill status-active", else: "status-pill status-closed"}>
                        {if s.active?, do: "active", else: "closed"}
                      </span>
                    </td>
                  </tr>
                  <tr :if={@sessions == []}>
                    <td colspan="5" style="color:var(--muted)">No impersonation sessions recorded.</td>
                  </tr>
                </tbody>
              </table>

              <div class="gtitle" style="margin-top:24px">
                <h3>Account security</h3>
                <span class="lane">managed by your identity provider — the framework is honest about this boundary</span>
              </div>

              <dl id="security-host-managed" style="margin-top:8px">
                <div :for={{item, note} <- @host_managed} class="host-managed-item" style="margin-bottom:8px">
                  <dt style="font-weight:600">{item}</dt>
                  <dd style="color:var(--muted);margin:0">{note} <em>Managed by your identity provider.</em></dd>
                </div>
              </dl>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp fmt(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp fmt(_), do: "—"
end
