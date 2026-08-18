defmodule Samen.Web.Settings.InvitationsLive do
  @moduledoc """
  The framework TEAM INVITATIONS settings LiveView (ADR-035 §5 A5; T05) —
  mounted at `/settings/invitations` by `Samen.Web.Router.samen_settings_routes/3`.

  Invite-by-email with role selection · list (pending/accepted/revoked/expired,
  `email` masked per plane — INV-1) · revoke a pending invite. Sending is
  tenant-plane, admin-gated (the `Invitation.:create` rank-ceiling policy); an
  operator-plane view is read-only, same posture as `ApiKeysLive`.

  The raw invite LINK is shown EXACTLY ONCE right after a successful invite
  (the `ApiKeysLive` show-once-raw-key precedent) — the DB stores only
  `token_digest`, so this is the only chance to hand it to the invitee until
  a real Delivery adapter is wired (dev/test captures via `LocalSink`).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1, operator_plane?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Settings.Invitations
  alias Samen.Web.Settings.Reads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok,
     socket
     |> assign(return_to: nil, invite_error: nil, invited_raw_token: nil, samen_session: session)
     |> load(org_id, user_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    user_id = Samen.Web.Settings.Reads.reresolve_user(socket, params)

    {:noreply,
     socket
     |> assign(return_to: return_path(uri))
     |> load(org_id, user_id)}
  end

  @doc false
  def load(socket, org_id, user_id) do
    mount = socket.assigns.samen_mount
    socket = assign(socket, org_id: org_id, user_id: user_id, invitations: [])

    if is_nil(org_id) do
      socket
    else
      scope = Mount.scope(mount, org_id)
      assign(socket, invitations: Invitations.list(mount, scope))
    end
  end

  @impl true
  def handle_event("invite", %{"invitation" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id, samen_session: session} = socket.assigns

    if operator_plane?(mount) do
      {:noreply, assign(socket, invite_error: "Invitations are sent from the tenant plane.")}
    else
      do_invite(socket, mount, org_id, user_id, session, params)
    end
  end

  def handle_event("revoke", %{"id" => invitation_id}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns

    if operator_plane?(mount) do
      {:noreply, socket}
    else
      scope = member_scope(mount, org_id, user_id)
      _ = Invitations.revoke(mount, scope, invitation_id)
      {:noreply, load(assign(socket, invited_raw_token: nil), org_id, user_id)}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, invited_raw_token: nil)}
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:invited_raw_token, fn -> nil end)
      |> assign_new(:invite_error, fn -> nil end)

    ~H"""
    <div id="settings-invitations">
      <.app_shell>
        <:sidebar>
          <.settings_sidebar mount={@samen_mount} org_id={@org_id} user_id={@user_id} active={:invitations} />
        </:sidebar>

        <.topbar title="Team invitations" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Settings", "Invitations"]}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="invitations-panel">
              <%= if @invited_raw_token do %>
                <div id="invitation-link-minted" style="border:1px solid #15803D;padding:12px;border-radius:6px;margin-bottom:14px">
                  <strong>Copy this invite link now — it is shown only once.</strong>
                  <pre id="invitation-raw-token" style="margin:8px 0;user-select:all">/invite/{@invited_raw_token}</pre>
                  <button type="button" phx-click="dismiss_token" class="btn" id="invitation-dismiss">Done</button>
                </div>
              <% end %>

              <p :if={@invite_error} id="invitation-error" style="color:#B91C1C">{@invite_error}</p>

              <%= if not operator_plane?(@samen_mount) do %>
                <form id="invite-form" phx-submit="invite" style="margin-bottom:16px">
                  <fieldset style="border:0;padding:0">
                    <legend style="font-weight:600;font-size:13px">Invite a teammate</legend>
                    <input type="email" name="invitation[email]" placeholder="teammate@example.com" required id="invite-email" />
                    <select name="invitation[role]" id="invite-role">
                      <option value="member" selected>member</option>
                      <option value="admin">admin</option>
                      <option value="viewer">viewer</option>
                    </select>
                    <.button type="submit" variant="primary" id="invite-submit">Send invite</.button>
                  </fieldset>
                  <p style="color:var(--muted);font-size:12px;margin-top:4px">
                    You can only invite a role you could yourself hold or manage — no invite above your own rank.
                  </p>
                </form>
              <% else %>
                <p id="invitations-operator-note" style="color:var(--muted)">
                  Inviting and revoking are tenant-plane actions.
                </p>
              <% end %>

              <table id="invitations-table" class="tbl">
                <thead>
                  <tr>
                    <th scope="col">Email</th>
                    <th scope="col">Role</th>
                    <th scope="col">Status</th>
                    <th scope="col">Expires</th>
                    <th scope="col"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={inv <- @invitations} class="invitation-row" id={"invitation-#{inv.id}"}>
                    <td class="invitation-email">{inv.email}</td>
                    <td>{inv.role}</td>
                    <td>
                      <span class={"status-pill status-#{inv.status}"}>{inv.status}</span>
                    </td>
                    <td>{inv.expires_at}</td>
                    <td>
                      <button
                        :if={inv.status == "pending" and not operator_plane?(@samen_mount)}
                        type="button"
                        phx-click="revoke"
                        phx-value-id={inv.id}
                        class="btn"
                        id={"invitation-revoke-#{inv.id}"}
                      >
                        Revoke
                      </button>
                    </td>
                  </tr>
                  <tr :if={@invitations == []}>
                    <td colspan="5" style="color:var(--muted)">No invitations yet.</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- private -----------------------------------------------------------------

  defp do_invite(socket, mount, org_id, user_id, session, params) do
    with {:ok, membership} <- membership(mount, org_id, user_id),
         scope <- invite_scope(user_id, org_id, membership.role, verified?(mount, session)),
         {:ok, _invitation, raw_token} <-
           Invitations.create(mount, scope, Map.get(params, "email", ""), Map.get(params, "role", "member")) do
      {:noreply,
       socket
       |> assign(invited_raw_token: raw_token, invite_error: nil)
       |> load(org_id, user_id)}
    else
      {:error, :not_found} ->
        {:noreply, assign(socket, invite_error: "No membership in context — cannot invite.")}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           invite_error: "Invite refused (admin role required, verified account required, or the invited role outranks yours)."
         )}
    end
  end

  defp membership(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    scope = Mount.scope(mount, org_id)
    Reads.current_membership(mount, scope, user_id, org_id)
  end

  defp membership(_mount, _org_id, _user_id), do: {:error, :not_found}

  defp member_scope(mount, org_id, user_id) do
    case membership(mount, org_id, user_id) do
      {:ok, membership} -> invite_scope(user_id, org_id, membership.role, true)
      {:error, _} -> invite_scope(user_id, org_id, :member, true)
    end
  end

  # The current admin's own actor — a tenant-plane scope carrying the REAL
  # membership role (so the create/revoke rank-ceiling policies see the real
  # inviter authority) plus `verified?` (the ADR-035 §5 A2 capability gate —
  # resolved from the spine's Credential when mounted; a BYO-auth host with no
  # spine Credential has no unverified state to enforce, so it defaults true).
  defp invite_scope(user_id, org_id, role, verified?) do
    %Samen.Scope{
      actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant, verified?: verified?}
    }
  end

  # B-SEC / S2 — the NO-PRINCIPAL branch is fail-CLOSED.
  #
  # This used to return `true` for "no principal resolved", on the reasoning that a BYO-auth host
  # with no spine `Credential` has no unverified state to enforce. But the same branch also
  # caught the case with no principal AT ALL — so an UNAUTHENTICATED attacker driving this
  # surface got `verified?: true` handed to the invite scope, satisfying the ADR-035 §5 A2
  # capability gate for free. The three cases are now distinguished:
  #
  #   * spine principal      → the REAL `Credential.verified_at` (unchanged);
  #   * legacy BYO principal → `true` (a BYO host genuinely has no verified state — unchanged
  #     for every authenticated BYO caller, which is the only caller that reaches it);
  #   * NO principal / error → `false` (fail CLOSED — the attacker's branch).
  defp verified?(mount, session) do
    session_mod = Mount.resource(mount, Session)

    case Samen.Web.Auth.resolve_principal(session, %{session: session_mod}) do
      {:ok, %{credential_id: credential_id}} ->
        case Ash.get(Mount.resource(mount, Credential), credential_id, authorize?: false) do
          {:ok, %{verified_at: v}} -> not is_nil(v)
          _ -> false
        end

      {:ok, %{user_id: user_id}} ->
        is_binary(user_id)

      _ ->
        not Samen.Web.CurrentOrg.tenant_gate_armed?(mount)
    end
  rescue
    _ -> not Samen.Web.CurrentOrg.tenant_gate_armed?(mount)
  end
end
