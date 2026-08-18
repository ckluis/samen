defmodule Samen.Web.Settings.SecurityLive do
  @moduledoc """
  The framework SECURITY settings LiveView (WS-E E5.3; ADR-029; AC-G18-5) — mounted at
  `/settings/security` by `Samen.Web.Router.samen_settings_routes/3`.

  ## READ-ONLY and HONEST about the host-auth boundary (RP-ST-4) — the DEFAULT

  Auth is deliberately HOST-OWNED (ADR-029 §1): `samen_web` has no framework
  login/password/2FA/session store BY DEFAULT. This surface therefore renders ONLY
  what the framework genuinely owns and NEVER fakes control it doesn't have:

    * **Impersonation sessions** — who acted as this org, when, why, expiry — read from
      the REAL `Samen.Impersonation.Sessions.list_for_org/2` (the tenant-visible
      accountability view). Read-only.
    * **Host-managed auth** (password, 2FA, active login sessions) renders as an honest
      "managed by your identity provider" affordance — a static, disabled note, NOT a
      toggle or a button that claims to revoke/reset something the framework can't.

  There is NO `phx-click`/`phx-submit` that mutates auth on this page BY DEFAULT.
  Faking a host-auth toggle (adding a LiveView-driven control that claims to revoke a
  session the framework doesn't own) FAILS the honesty structural red-path
  (`settings_surface_test.exs`).

  ## The ADR-035 §4.3 inversion — EXPLICIT opt-in only (`spine_sessions:`)

  When a host mounts the framework identity spine AND deliberately opts in
  (`samen_settings_routes ..., spine_sessions: true` — `Samen.Web.Router`), the
  "Active login sessions" placeholder is replaced by the REAL session list
  (`Samen.Auth.SessionList.list_live/2`: device/created/last-seen metadata) with
  individual-revoke + revoke-others controls. These are PLAIN HTML `<form
  method="post">`s targeting `Samen.Web.Auth.SessionController` (a LiveView cannot
  set a cookie mid-mount, so the mutation is never a `phx-click`/`phx-submit` —
  the honesty red-path's literal refutation target stays true even in real mode:
  no LiveView-driven auth mutation, ever). This is opt-in, NOT inferred from
  whether `Identity.Session` happens to be compiled into the mount's namespace —
  inferring it would silently flip the ALREADY-GREEN `settings_surface_test.exs`
  RP-ST-4 assertions the moment ANY host (including this library's own test host)
  materializes the resource, which is exactly the "spine mounted but not actually
  wired for login" state T04 ships in.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Settings.Reads

  # The host-managed auth items the framework is HONEST it does NOT own, absent the
  # `spine_sessions:` opt-in. Rendered as static "managed by your identity provider"
  # notes — never as a fake toggle.
  @host_managed_default [
    {"Password", "Set or reset through your identity provider."},
    {"Two-factor authentication", "Managed by your identity provider."},
    {"Active login sessions", "Session revocation is handled by your identity provider."}
  ]

  # With the spine wired, password/2FA stay host-owned (A4 is sessions only) — only
  # the "Active login sessions" row's placeholder is dropped, replaced by the real
  # session-sessions-table block below.
  @host_managed_spine [
    {"Password", "Set or reset through your identity provider."},
    {"Two-factor authentication", "Managed by your identity provider."}
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
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    user_id = Samen.Web.Settings.Reads.reresolve_user(socket, params)
    {:noreply, load(assign(socket, return_to: return_path(uri)), org_id, user_id)}
  end

  @doc false
  def load(socket, org_id, user_id) do
    mount = socket.assigns.samen_mount
    spine? = Mount.label(mount, :spine_sessions, false)
    # ADR-035 §5 A7 — the EXPLICIT `spine_totp` opt-in (a host mounting the
    # Identity spine's `Credential`) flips the "Two-factor authentication —
    # managed by your identity provider" placeholder into a REAL enrollment link
    # (`Samen.Web.Auth.TotpEnrollLive`, mounted by `samen_settings_routes`). A
    # plain `<a>` navigation — NEVER a `phx-click` auth mutation — so the RP-ST-4
    # honesty red-path stays literally true (the enrollment page owns the write).
    totp? = Mount.label(mount, :spine_totp, false)

    {reveal_events, reveal_unavailable?} = reveal_events_for(mount, org_id)

    # S6 — the org-resolved tenant scope every credential read on this page is governed by
    # (`credential_id_for/3` below). No resolved org → no scope → the seam fails closed.
    scope = if is_binary(org_id), do: Mount.scope(mount, org_id)

    assign(socket,
      org_id: org_id,
      user_id: user_id,
      sessions: sessions_for(mount, org_id),
      reveal_events: reveal_events,
      reveal_ledger_unavailable?: reveal_unavailable?,
      host_managed: if(spine?, do: @host_managed_spine, else: @host_managed_default),
      spine_sessions?: spine?,
      spine_totp?: totp?,
      settings_path: Mount.label(mount, :settings_path, "/settings"),
      totp_enroll_path: totp_enroll_path(mount, scope, totp?, user_id),
      login_sessions: login_sessions_for(mount, scope, spine?, user_id),
      csrf_token: safe_csrf_token()
    )
  end

  # The `/settings/security/2fa` enrollment link, only when `spine_totp` is on.
  # Carries the resolved `credential_id` (the SAME `credential_id_for/2` seam the
  # spine session list uses) so TotpEnrollLive enrolls the right account; degrades
  # to the bare path when the credential can't be resolved (honest, never a crash).
  defp totp_enroll_path(_mount, _scope, false, _user_id), do: nil

  defp totp_enroll_path(mount, scope, true, user_id) do
    base = Mount.label(mount, :settings_path, "/settings") <> "/security/2fa"

    case credential_id_for(mount, scope, user_id) do
      nil -> base
      credential_id -> base <> "?credential_id=#{credential_id}"
    end
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

  # PP-11 (T150) — the REVEAL-access ledger. An impersonation session records the MASKED
  # view; a reveal is the moment tenant PII actually becomes plaintext to an operator. Read
  # the org-scoped reveal-grant lifecycle from the tenant-readable audit chain.
  #
  # O10 — HONEST empty vs unavailable. This is a tenant TRUST surface, so a FAILED read
  # (a host that has not migrated `aud_chain`, a DB outage) must NOT be shown as a clean,
  # empty ledger — that false all-clear is the O10 defect. `reveal_events_result/2` returns
  # `{:ok, events}` (an empty list is the honest "no reveals") vs `{:error, :unavailable}`
  # (the read itself failed); we thread that into `{events, unavailable?}` so the render can
  # say "ledger temporarily unavailable" instead of "no reveal access recorded". The reserved
  # `__global__` partition is a legitimate empty-OK. READ-ONLY — no mutation.
  defp reveal_events_for(_mount, nil), do: {[], false}

  defp reveal_events_for(mount, org_id) do
    case Samen.AuditChain.reveal_events_result(org_id, repo: mount.repo) do
      {:ok, events} ->
        decorated =
          Enum.map(events, fn e ->
            {label, reason} = reveal_row(e.detail)
            Map.merge(e, %{label: label, reason: reason})
          end)

        {decorated, false}

      {:error, _} ->
        {[], true}
    end
  rescue
    _ -> {[], true}
  end

  # Turn the token-only `detail` ("event=requested <reason>") into a tenant-legible
  # {label, reason} pair for the ledger row.
  defp reveal_row(detail) do
    case detail || "" do
      "event=requested " <> reason -> {"Reveal requested", reason}
      "event=requested" -> {"Reveal requested", ""}
      # PP-13: the approve-moment (a distinct approver GRANTED the reveal) now rides the
      # tenant chain too; label it explicitly rather than falling to the generic bucket.
      "event=granted" <> rest -> {"Reveal granted", String.trim(rest)}
      "event=revoked" <> rest -> {"Reveal revoked", String.trim(rest)}
      "event=expired" <> rest -> {"Reveal window expired", String.trim(rest)}
      "event=denied" <> rest -> {"Reveal denied", String.trim(rest)}
      other -> {"Reveal event", String.trim(other)}
    end
  end

  # ADR-035 §4.3 — the REAL `Identity.Session` list for the current user's
  # credential, spine-opt-in ONLY. Never invents rows; any read error (host hasn't
  # actually mounted Credential/Session under this namespace) degrades to an empty
  # list — honest, matching the impersonation-sessions precedent above.
  defp login_sessions_for(_mount, _scope, false, _user_id), do: []
  defp login_sessions_for(_mount, _scope, true, nil), do: []

  defp login_sessions_for(mount, scope, true, user_id) do
    case credential_id_for(mount, scope, user_id) do
      nil -> []
      credential_id -> Samen.Auth.SessionList.list_live(Mount.resource(mount, Session), credential_id)
    end
  rescue
    _ -> []
  end

  # Nil guard: without it, a nil `user_id` (unresolved/unauthenticated) still hits
  # the DB with `id == ^user_id` binding to `nil`, which Ash/AshPostgres flags at
  # runtime ("Comparing values with nil will always return false (id == nil)")
  # since SQL's `= NULL` is never true — the query was always doomed to return
  # zero rows. Short-circuiting here keeps the same nil result, skips the wasted
  # round-trip, and silences the warning (no behaviour change).
  defp credential_id_for(_mount, _scope, nil), do: nil

  # S6 — no org-resolved scope (org_id was nil) → fail closed: never fall back to an
  # ungoverned read.
  defp credential_id_for(_mount, nil, _user_id), do: nil

  # S6 (luminary panel-2) — this read was `Ash.read!(authorize?: false)` with no org
  # scope: a global `user_id → credential_id` oracle (the pivot in the S3 chain). It is
  # now GOVERNED, the same pattern as `Samen.Web.Settings.Reads.get_user/3`: the read
  # runs under the caller's org-resolved tenant scope, so `Samen.Policy.OrgScope` on the
  # Identity `User` makes a cross-org `user_id` read ZERO rows — the seam answers `nil`,
  # the 2FA link degrades to the bare path, the session list stays empty. Same-org
  # resolution is unchanged (never widened).
  defp credential_id_for(mount, scope, user_id) do
    require Ash.Query

    Mount.resource(mount, User)
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:credential_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> case do
      [%{credential_id: credential_id}] -> credential_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_csrf_token do
    Phoenix.Controller.get_csrf_token()
  rescue
    _ -> nil
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
                <h3>Reveal access</h3>
                <span class="lane">when an operator unmasked customer PII in your org — who, which subject, when, and the reason — read-only accountability</span>
              </div>

              <table id="security-reveal-table" class="tbl">
                <thead>
                  <tr>
                    <th scope="col">Event</th>
                    <th scope="col">Operator</th>
                    <th scope="col">Subject</th>
                    <th scope="col">Reason</th>
                    <th scope="col">When</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={e <- @reveal_events} class="security-reveal-row">
                    <td>{e.label}</td>
                    <td>{e.actor_id}</td>
                    <td class="mono" style="font-size:12px">{e.subject_id}</td>
                    <td style="font-size:12px">{e.reason}</td>
                    <td>{fmt(e.occurred_at)}</td>
                  </tr>
                  <tr :if={@reveal_ledger_unavailable?} id="security-reveal-unavailable">
                    <td colspan="5" style="color:var(--muted)">
                      Reveal ledger temporarily unavailable — this is a read error, not a clean record. Retry shortly.
                    </td>
                  </tr>
                  <tr :if={@reveal_events == [] and not @reveal_ledger_unavailable?}>
                    <td colspan="5" style="color:var(--muted)">No reveal access recorded for this org.</td>
                  </tr>
                </tbody>
              </table>

              <div :if={@spine_sessions?} class="gtitle" style="margin-top:24px">
                <h3>Active login sessions</h3>
                <span class="lane">devices signed in to your account — revoke any you don't recognize</span>
              </div>

              <div :if={@spine_sessions?} id="security-login-sessions">
                <table id="login-sessions-table" class="tbl">
                  <thead>
                    <tr>
                      <th scope="col">Device</th>
                      <th scope="col">Created</th>
                      <th scope="col">Last seen</th>
                      <th scope="col"></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={s <- @login_sessions} class="login-session-row" id={"login-session-#{s.id}"}>
                      <td>{s.device_label || "Unknown device"}</td>
                      <td>{fmt(s.inserted_at)}</td>
                      <td>{fmt(s.last_seen_at)}</td>
                      <td>
                        <form
                          method="post"
                          action={"#{@settings_path}/security/sessions/#{s.id}/revoke"}
                          id={"revoke-session-#{s.id}"}
                        >
                          <input type="hidden" name="_csrf_token" value={@csrf_token} />
                          <button type="submit" class="btn btn-sm" id={"revoke-session-btn-#{s.id}"}>Revoke</button>
                        </form>
                      </td>
                    </tr>
                    <tr :if={@login_sessions == []}>
                      <td colspan="4" style="color:var(--muted)">No active sessions.</td>
                    </tr>
                  </tbody>
                </table>

                <form
                  :if={@login_sessions != []}
                  method="post"
                  action={"#{@settings_path}/security/sessions/revoke_others"}
                  id="revoke-others-form"
                  style="margin-top:10px"
                >
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <button type="submit" class="btn" id="revoke-others-submit">Revoke all other sessions</button>
                </form>
              </div>

              <div class="gtitle" style="margin-top:24px">
                <h3>Account security</h3>
                <span class="lane">managed by your identity provider — the framework is honest about this boundary</span>
              </div>

              <dl id="security-host-managed" style="margin-top:8px">
                <div :for={{item, note} <- @host_managed} class="host-managed-item" style="margin-bottom:8px">
                  <dt style="font-weight:600">{item}</dt>
                  <%= if item == "Two-factor authentication" and @totp_enroll_path do %>
                    <dd style="margin:0">
                      <.link navigate={@totp_enroll_path} id="security-2fa-enroll-link">
                        Set up two-factor authentication →
                      </.link>
                    </dd>
                  <% else %>
                    <dd style="color:var(--muted);margin:0">{note} <em>Managed by your identity provider.</em></dd>
                  <% end %>
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
