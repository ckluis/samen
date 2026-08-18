defmodule Samen.Web.Settings.RevealApprovalsLive do
  @moduledoc """
  The framework tenant REVEAL-APPROVER settings LiveView (PP-13; ADR-002 / ADR-040 §4) —
  mounted at `/settings/reveal-approvals` by `Samen.Web.Router.samen_settings_routes/3`.

  ## What it completes (the request → approve → unmask lifecycle)

  An operator files a reveal REQUEST from the impersonation console
  (`Samen.Reveal.Grants.request/1`, opening a PENDING `pii_reveal` approval); the grant
  engine + the DISTINCT-party rule already exist. What was missing (the PP-13 deferral) was
  the tenant surface where a SECOND party actually approves/denies — so in a real deploy no
  grant was ever minted and every reveal denied. THIS surface closes that: an org APPROVER
  sees the org's PENDING reveal-requests and approves (minting the time-boxed grant through
  the EXISTING `Samen.Reveal.Grants.approve/2`) or denies (`Samen.Reveal.Grants.deny/2`).

  ## NOT `Settings.SecurityLive` (RP-ST-4)

  SecurityLive is pinned READ-ONLY by the RP-ST-4 honesty red-path (it refutes every
  `phx-click`/`phx-submit`). Approve/deny are mutations, so they need their OWN LiveView —
  this one. The reveal-access LEDGER (who unmasked what, after the fact) stays on
  SecurityLive, read-only; the approve/deny DECISION lives here.

  ## Enforcement (three conjuncts, defence in depth)

    * **Org scope** — the pending read is `Samen.Reveal.Grants.pending_for_org/2`, which is
      `org_id`-filtered at `Samen.Approvals.list_pending/3`; a cross-org request never
      appears, and a decide on a `request_id` not in THIS org's pending queue is refused.
    * **Approver role** — decides are gated on a tenant `:admin`+ membership (`can_approve?`),
      resolved from the authenticated principal's real `Membership.role` (the `InvitationsLive`
      precedent). A `member`/`viewer`, or the operator plane, sees a read-only view.
    * **Distinct party** — the approver (a tenant member) is never the requesting operator;
      the kernel `Samen.Approvals` engine additionally refuses `decided_by == requested_by`
      (`{:error, :self_approval}`) at the policy layer AND the DB CHECK, so a self-approval is
      structurally impossible even if this surface were bypassed.

  ## MASKING — metadata only, the value is NEVER rendered (the whole point)

  Each row shows the requesting OPERATOR, the SUBJECT reference (an opaque UUID token), the
  FIELD (resource/action), and the operator's REASON. It NEVER renders the plaintext VALUE
  being requested — that value is exactly what the approver is deciding whether to unmask;
  showing it would defeat the control. No vault read happens here, and no `vt_*` token is
  ever placed in the DOM (`pending_for_org/2` projects token/id/metadata fields only).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1, operator_plane?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Reveal.Grants
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Settings.Reads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok,
     socket
     |> assign(return_to: nil, decision_notice: nil)
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

    socket =
      assign(socket,
        org_id: org_id,
        user_id: user_id,
        pending: [],
        can_approve?: false,
        approver_role: nil
      )

    if is_nil(org_id) do
      socket
    else
      role = approver_role(mount, org_id, user_id)

      assign(socket,
        pending: Grants.pending_for_org(org_id, repo: mount.repo),
        approver_role: role,
        can_approve?: can_approve?(mount, role)
      )
    end
  end

  @impl true
  def handle_event("approve", %{"request" => request_id}, socket) do
    decide(socket, request_id, :approve)
  end

  def handle_event("deny", %{"request" => request_id}, socket) do
    decide(socket, request_id, :deny)
  end

  # The decide chokepoint: every conjunct is re-checked SERVER-SIDE (the absence of a button
  # is never the security boundary). Org scope: the request MUST be in this org's pending
  # queue (a cross-org / stale id is refused). Role: tenant `:admin`+ only. Plane: tenant only.
  defp decide(socket, request_id, action) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id, can_approve?: can_approve?} =
      socket.assigns

    row = Enum.find(socket.assigns.pending, &(&1.request_id == to_string(request_id)))

    cond do
      operator_plane?(mount) ->
        {:noreply, notice(socket, "Approving and denying are tenant-plane actions.")}

      not can_approve? ->
        {:noreply, notice(socket, "An admin role is required to decide reveal requests.")}

      is_nil(row) ->
        # Org-scope refusal: not a pending request for THIS org (cross-org or already decided).
        {:noreply, notice(socket, "That reveal request is not in this org's pending queue.")}

      user_id == row.requestor_id ->
        # Distinct-party (belt over the engine's own refusal): the approver cannot be the
        # requesting party. A tenant member is never the operator, so this only ever guards a
        # degenerate mis-wire — but it is asserted here, not left solely to the engine.
        {:noreply, notice(socket, "The approver must be a different party than the requester.")}

      true ->
        run_decision(socket, mount, org_id, user_id, row, action)
    end
  end

  defp run_decision(socket, mount, org_id, user_id, row, :approve) do
    case Grants.approve(row.request_id, %{granted_by: user_id, org_id: org_id, repo: mount.repo}) do
      {:ok, _grant} ->
        {:noreply,
         socket
         |> notice("Reveal approved — a time-boxed grant was issued to #{row.requestor_id}.")
         |> load(org_id, user_id)}

      {:error, :self_approval} ->
        {:noreply, notice(socket, "Self-approval is refused — a distinct party must approve.")}

      {:error, _reason} ->
        {:noreply, notice(socket, "Could not approve the reveal request.")}
    end
  end

  defp run_decision(socket, mount, org_id, user_id, row, :deny) do
    case Grants.deny(row.request_id, %{denied_by: user_id, org_id: org_id, repo: mount.repo}) do
      {:ok, _req} ->
        {:noreply,
         socket
         |> notice("Reveal request denied — no grant was issued.")
         |> load(org_id, user_id)}

      {:error, _reason} ->
        {:noreply, notice(socket, "Could not deny the reveal request.")}
    end
  end

  defp notice(socket, msg), do: assign(socket, decision_notice: msg)

  # The approver's REAL tenant role, resolved from the authenticated principal's Membership
  # (the InvitationsLive precedent). Fail-closed: no membership → nil → not an approver.
  defp approver_role(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    scope = Mount.scope(mount, org_id)

    case Reads.current_membership(mount, scope, user_id, org_id) do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp approver_role(_mount, _org_id, _user_id), do: nil

  # Tenant plane + `:admin`+ rank. The operator (impersonation) plane is read-only, so an
  # operator can never approve their own requests here (they would also be blocked as
  # non-distinct, but the plane gate refuses first).
  defp can_approve?(mount, role) do
    not operator_plane?(mount) and Samen.Scope.Role.at_least?(role, :admin)
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :decision_notice, fn -> nil end)

    ~H"""
    <div id="settings-reveal-approvals">
      <.app_shell>
        <:sidebar>
          <.settings_sidebar mount={@samen_mount} org_id={@org_id} user_id={@user_id} active={:reveal_approvals} />
        </:sidebar>

        <.topbar title="Reveal approvals" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Settings", "Reveal approvals"]}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="reveal-approvals-panel">
              <div class="gtitle">
                <h3>Pending reveal requests</h3>
                <span class="lane">
                  an operator has asked to unmask a subject's PII in your org — approve to issue a
                  time-boxed grant, or deny. You see WHO, WHICH subject, WHICH field, and WHY —
                  never the value itself (that is what you are deciding to unmask).
                </span>
              </div>

              <p :if={@decision_notice} id="reveal-approval-notice" style="color:#26307a">{@decision_notice}</p>

              <p :if={operator_plane?(@samen_mount)} id="reveal-approvals-operator-note" style="color:var(--muted)">
                Approving and denying are tenant-plane actions.
              </p>

              <p
                :if={not operator_plane?(@samen_mount) and not @can_approve?}
                id="reveal-approvals-role-note"
                style="color:var(--muted)"
              >
                Deciding a reveal request requires an admin role — this is a read-only view for your role.
              </p>

              <table id="reveal-approvals-table" class="tbl">
                <thead>
                  <tr>
                    <th scope="col">Operator</th>
                    <th scope="col">Subject</th>
                    <th scope="col">Field</th>
                    <th scope="col">Reason</th>
                    <th scope="col">Requested</th>
                    <th scope="col"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={p <- @pending} class="reveal-approval-row" id={"reveal-approval-#{p.request_id}"}>
                    <td class="ra-operator">{p.requestor_id}</td>
                    <td class="ra-subject mono" style="font-size:12px">{p.subject_id}</td>
                    <td class="ra-field" style="font-size:12px">{field_label(p.resource, p.action)}</td>
                    <td class="ra-reason" style="font-size:12px">{p.reason}</td>
                    <td class="ra-requested">{fmt(p.requested_at)}</td>
                    <td>
                      <%= if @can_approve? do %>
                        <button
                          type="button"
                          phx-click="approve"
                          phx-value-request={p.request_id}
                          class="btn"
                          id={"approve-btn-#{p.request_id}"}
                        >
                          Approve
                        </button>
                        <button
                          type="button"
                          phx-click="deny"
                          phx-value-request={p.request_id}
                          class="btn"
                          id={"deny-btn-#{p.request_id}"}
                        >
                          Deny
                        </button>
                      <% end %>
                    </td>
                  </tr>
                  <tr :if={@pending == []}>
                    <td colspan="6" id="reveal-approvals-empty" style="color:var(--muted)">
                      No pending reveal requests for this org.
                    </td>
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

  # The requested FIELD, human-legible: strip the "Elixir." module prefix from `resource`
  # and pair it with the `action`. Both are token/metadata (a module + action name) — never
  # a vault value.
  defp field_label(resource, action) do
    res = resource |> to_string() |> String.replace_prefix("Elixir.", "")
    [res, action] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  defp fmt(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp fmt(_), do: "—"
end
