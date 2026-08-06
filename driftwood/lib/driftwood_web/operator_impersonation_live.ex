defmodule DriftwoodWeb.OperatorImpersonationLive do
  @moduledoc """
  The OPERATOR plane (T5.3 clause (b); T4.1 mounted over a Driftwood tenant): an operator
  opens a masked impersonation session over ONE brokerage tenant org and sees its REAL
  load board + driver roster — with `••••` PII, because the impersonation scope carries
  no reveal grant.

  ## What this proves (T5.3 red paths, on the LIVE freight app)

    * The operator sees the tenant's REAL data SHAPE — its actual `Driftwood.Freight.Driver`
      + Load rows — via the SAME `Driftwood.Reads` functions the broker's own console uses.
    * Driver NAME + CDL NUMBER render `••••` (they are vault-routed and the impersonation
      scope has no reveal grant — masked BY CONSTRUCTION, no path leaks by omission).
    * The FMCSA status badge is visible (non-PII), so the operator can support the tenant
      without seeing driver PII.
    * A tenant-visible accountability line (who / why / expiry) shows the impersonation is
      bounded and recorded.

  ## Reveal (T1.6 second-party grant, end-to-end)

  Below the roster is a per-driver reveal control. When a DISTINCT second party has
  approved a reveal grant for `(operator, driver)`, the operator can unmask that driver's
  vaulted PII end-to-end via `Samen.Reveal.reveal/5` (the single decrypt chokepoint).
  Without an approving grant it denies — `••••` stays. The dogfood / adversarial tests
  drive both the granted and ungranted paths.

  ## Reveal-window legibility + honest scope (R-P6; persona-6 findings P6-F1/F2/F3/F5)

  A reveal grant is **subject-wide**, not field-narrow: `Samen.Reveal.Grants.active?/3`
  keys on `(subject_id, requestor_id)` with no field filter, so an active grant authorizes
  resolving the WHOLE subject record — the driver's NAME as well as the CDL number, and it
  resolves them **passively on any roster load** (no click needed). The UI therefore states
  the true scope: the control reads "Reveal driver record" (not "Reveal CDL"), and while a
  window is open a visible banner announces it, names the approver (`granted_by`), shows the
  expiry + a live countdown, and every already-resolved row reads "revealed" regardless of
  whether it was unmasked by a click or by the passive grant-gated read. The per-second
  `:tick` recomputes the open windows and, the instant one expires, reloads the roster so
  the value re-masks mid-session (closing the P6-F5 "stale plaintext until reload" residual)
  — a fresh mount already re-masked correctly; this closes it live too.

  ## Mount contract

  `mount/3` reads `operator_id` + `org_id` from params/session (a real deploy sets these
  from the operator's authenticated session + the org they chose). It builds the
  impersonation scope PER MOUNT (deny-on-read): an expired/absent session yields
  `{:error, :session_inactive}` and the view renders the access-denied state, no data.
  """
  use Phoenix.LiveView

  # ADR-009 — the component kit is now framework-level (`Samen.UI`).
  import Samen.UI

  alias Samen.Impersonation
  alias Driftwood.Reads

  # A live reveal window is time-boxed; the countdown + mid-session re-mask ride a
  # per-second server tick (no JS — ADR-042 progressive enhancement). Only a connected
  # LiveView ticks; the first (static) mount and the render-only tests do not.
  @tick_ms 1000

  @impl true
  def mount(params, session, socket) do
    operator_id = fetch(params, session, "operator_id")
    org_id = fetch(params, session, "org_id")
    if connected?(socket), do: schedule_tick()
    {:ok, load(socket, operator_id, org_id)}
  end

  # Extracted so the dogfood test drives the exact same load path.
  #
  # Gate-5 F3 fix: a request with no `operator_id`/`org_id` (the default when a session
  # is missing/mis-configured) must render the SAME fail-closed access-denied state as
  # an inactive session — NOT crash. Without this guard, `Impersonation.scope(nil, …)`
  # raises `FunctionClauseError` and the page 500s (the moduledoc's "renders the
  # access-denied state" contract was untrue on the nil path). `for_session/3` can also
  # return `{:error, :operator_suspended}` (a suspended operator mid-session), which is
  # the same access-denied shape — both are handled below.
  @doc false
  def load(socket, operator_id, org_id)
      when not is_binary(operator_id) or not is_binary(org_id) do
    denied(socket, operator_id, org_id)
  end

  def load(socket, operator_id, org_id) do
    case Impersonation.scope(operator_id, org_id) do
      {:ok, scope} ->
        now = DateTime.utc_now()

        assign(socket,
          impersonating: true,
          session_inactive: false,
          operator_id: operator_id,
          org_id: org_id,
          org_name: org_name(org_id),
          open_error: nil,
          drivers: Reads.driver_roster(scope),
          loads: Reads.load_board(scope),
          revealed: %{},
          now: now,
          reveal_windows: reveal_windows(operator_id, now),
          request_notice: socket.assigns[:request_notice],
          session_info: session_info(org_id, operator_id)
        )

      # Both fail-closed shapes render access-denied with NO tenant data:
      #   :session_inactive — never opened / closed / expired mid-flight
      #   :operator_suspended — the operator lost operator-plane standing (F4.2)
      {:error, reason} when reason in [:session_inactive, :operator_suspended] ->
        denied(socket, operator_id, org_id)
    end
  end

  # The fail-closed access-denied assign: no data, no reveal, no session info.
  defp denied(socket, operator_id, org_id) do
    assign(socket,
      impersonating: false,
      session_inactive: true,
      operator_id: operator_id,
      org_id: org_id,
      org_name: org_name(org_id),
      open_error: nil,
      drivers: [],
      loads: [],
      revealed: %{},
      now: DateTime.utc_now(),
      reveal_windows: [],
      request_notice: socket.assigns[:request_notice],
      session_info: nil
    )
  end

  # T150 F3 — resolve the target tenant org id to its display NAME (via the operator
  # directory), so the console names WHOSE house the operator is in rather than showing a
  # raw UUID. Fail-safe: an unresolvable id renders as itself.
  defp org_name(org_id) when is_binary(org_id) do
    case List.keyfind(Driftwood.Directory.orgs(), org_id, 0) do
      {_id, name} when is_binary(name) and name != "" -> name
      _ -> org_id
    end
  rescue
    _ -> org_id
  end

  defp org_name(org_id), do: org_id

  # The tenant-visible accountability entry for THIS operator over THIS org.
  defp session_info(org_id, operator_id) do
    org_id
    |> Impersonation.list_for_org()
    |> Enum.find(fn e -> e.operator_id == operator_id and e.active? end)
  end

  # The ACTIVE reveal windows this operator holds — who approved, until when. Read-only
  # accountability projection over `Samen.Reveal.Grants` (does NOT change the reveal gate).
  defp reveal_windows(operator_id, now) when is_binary(operator_id) do
    Samen.Reveal.Grants.active_windows(operator_id, repo: Driftwood.Repo, now: now)
  rescue
    _ -> []
  end

  defp reveal_windows(_operator_id, _now), do: []

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp fetch(params, session, key), do: Map.get(params, key) || Map.get(session, key)

  # ADR-036 §4.5(4): l.value is now the Money composite (dollars(l.value)).
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp dollars(_), do: "$0.00"

  # --- Presentation helpers (non-PII display only) --------------------------

  # Load status → pill variant (violet for en-route/on_load, mut for open/booked, ...).
  defp status_variant(s) when s in [:on_load, "on_load", :en_route, "en_route"], do: "info"
  defp status_variant(s) when s in [:delivered, "delivered", :available, "available"], do: "ok"
  defp status_variant(s) when s in [:out_of_service, "out_of_service", :terminated, "terminated"], do: "bad"
  defp status_variant(_), do: "mut"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-impersonation">
      <.app_shell>
        <:sidebar>
          <.sidebar title="Driftwood Ops" subtitle="Operator control plane">
            <:search>
              <div class="search">
                <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
                </svg>
                Search tenants, drivers…
                <span class="kbd">⌘K</span>
              </div>
            </:search>

            <.nav_group label="Operator plane">
              <.nav_item label="Tenants" href="/operator/aggregate" count="42">
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
                </:icon>
              </.nav_item>
              <.nav_item label="Impersonation" href="/operator/impersonate" active dot>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3a9 9 0 1 0 9 9" /><path d="M12 7v5l3 2" /></svg>
                </:icon>
              </.nav_item>
              <.nav_item label="Aggregate · MRR" href="/operator/aggregate">
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9m6 10V5m6 14v-7" /></svg>
                </:icon>
              </.nav_item>
            </.nav_group>

            <.nav_group label="Viewing as tenant">
              <.nav_item label="Loads" count={length(@loads)}>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 7h13l5 5v5H3z" /><circle cx="7.5" cy="17.5" r="1.5" /><circle cx="17.5" cy="17.5" r="1.5" /></svg>
                </:icon>
              </.nav_item>
              <.nav_item label="Drivers" active count={length(@drivers)}>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" /></svg>
                </:icon>
              </.nav_item>
              <.nav_item label="Settlements">
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
                </:icon>
              </.nav_item>
            </.nav_group>

            <:footer>
              <div class="foot">
                <div class="av">CK</div>
                <div class="m"><b>C. Kluis</b><span>operator · support role</span></div>
              </div>
            </:footer>
          </.sidebar>
        </:sidebar>

        <.topbar
          title="Driver roster"
          crumbs={["Operator plane", "Impersonation", @org_name, "Drivers"]}
        >
          <:actions>
            <.button>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M7 12h10M10 18h4" /></svg>
              </:icon>
              Filter
            </.button>
          </:actions>
        </.topbar>

        <%= if @session_inactive do %>
          <div class="wrap">
            <div class="card" id="session-state" style="padding:22px 20px">
              <div style="color:var(--red);font-weight:600">
                access denied — no active impersonation session (expired or never opened).
              </div>
              <%!--
                T150 F2 — the OPEN-SESSION-WITH-REASON affordance. Nothing else in a real deploy
                calls `Samen.Impersonation.open/3`; this is the human entry point. Opening writes a
                short-TTL, reason-required session recorded in the tenant's audit ledger, after
                which the roster renders MASKED. --%>
              <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                Start a masked impersonation session over <b>{@org_name}</b>. The reason is required
                and is written to this tenant's audit log (who / when / why).
              </p>
              <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">
                {@open_error}
              </div>
              <form phx-submit="open_session" id="open-session-form" style="display:flex;gap:8px;align-items:flex-start;max-width:640px">
                <input type="text" name="reason" id="session-reason-input"
                  placeholder="Reason (e.g. ticket #7781: dispatch dispute)"
                  style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px" />
                <button type="submit" id="start-session-btn" style="padding:8px 14px;border-radius:8px;background:var(--brand,#3B4CCA);color:#fff;font-size:13px">
                  Start session (masked)
                </button>
              </form>
            </div>
          </div>
        <% else %>
          <.mask_bar chip={session_chip(@session_info)}>
            <b>Masked impersonation.</b>
            <span id="banner">
              Impersonating brokerage <b>{@org_name}</b> as operator {@operator_id}. PII is masked (••••).
            </span>
            Unmasking a subject needs a second-party reveal grant, is time-boxed, and is written to the tenant-readable audit log.
            <span :if={@session_info} id="session-reason" class="acct">Reason: {@session_info.reason}</span>
            <span :if={@session_info} id="session-expiry" class="acct">Session expires: {@session_info.expires_at}</span>
          </.mask_bar>

    <%!-- R-P6: a privileged reveal window is legible while OPEN — who approved it, when it
          expires, a live countdown, and the HONEST subject-wide scope (name + CDL, not just
          the CDL). Absent when no window is open (the ungranted masked-only view). --%>
          <div :if={@reveal_windows != []} id="reveal-window-banner" class="reveal-window-open"
               style="margin:0 20px 14px;padding:12px 16px;border:1px solid #C9A227;border-radius:10px;background:#FFF8E1;color:#6B5200">
            <b>⚠ Privileged reveal window OPEN.</b>
            A second-party grant is unmasking the FULL subject record (driver name AND CDL number — reveal is subject-wide, not field-narrow) for {length(@reveal_windows)} subject(s):
            <ul style="margin:8px 0 0;padding-left:18px">
              <li :for={w <- @reveal_windows} class="reveal-window-entry">
                subject <span class="mono">{w.subject_id}</span>
                · <span class="approved-by">approved by <b>{w.granted_by}</b></span>
                · expires <span class="expires-at">{clock(w.expires_at)}</span>
                · <span class="countdown">{countdown(w.expires_at, @now)} left</span>
              </li>
            </ul>
          </div>

    <%!-- T149 B5: the outcome of a "Request reveal" — the REQUEST side of the existing
          reveal-grant lifecycle. It grants nothing; a DISTINCT second party must approve. --%>
          <div :if={@request_notice} id="reveal-request-notice" class="reveal-request-open"
               style="margin:0 20px 14px;padding:12px 16px;border:1px solid #3B4CCA;border-radius:10px;background:#EEF1FF;color:#26307a">
            {@request_notice}
          </div>

          <div class="wrap">
            <div class="gtitle">
              <h3>Driver roster</h3><span class="n">{length(@drivers)}</span>
              <span class="lane">· real tenant data, personal fields render ••••</span>
            </div>

            <.data_table>
              <:head>
                <th style="width:26%">Driver</th>
                <th style="width:16%">CDL #</th>
                <th style="width:12%">CDL state</th>
                <th style="width:12%">CDL expiry</th>
                <th style="width:12%">Status</th>
                <th style="width:12%">FMCSA</th>
                <th style="width:10%">Reveal</th>
              </:head>

              <tr :for={d <- @drivers} class="driver-row" id={"driver-#{d.id}"}>
                <td>
                  <div class="drv">
                    <div class="av"></div>
                    <span class="nm masked d-name">{fmt_name(d.full_name)}</span>
                  </div>
                </td>
                <td class="d-cdl"><span class="mono masked">{Map.get(@revealed, d.id) || d.cdl_number}</span></td>
                <td class="d-cdl-state carrier">{d.cdl_state}</td>
                <td class="d-cdl-expiry carrier">{d.cdl_expiry}</td>
                <td class="d-status">
                  <.pill variant={status_variant(d.status)}>{d.status}</.pill>
                </td>
                <td class="d-fmcsa">
                  <%= case d.__fmcsa__ do %>
                    <% :ok -> %>
                      <span class="fmcsa-ok"><.pill variant="ok">OK</.pill></span>
                    <% {:blocked, reasons} -> %>
                      <span class="fmcsa-blocked">
                        <.pill variant="bad">BLOCKED: {Enum.map_join(reasons, ", ", &Reads.reason_label/1)}</.pill>
                      </span>
                  <% end %>
                </td>
                <td class="d-reveal">
                  <%= if row_revealed?(@revealed, @reveal_windows, d) do %>
                    <span class="revealed rev" style="color:var(--brand);border-color:#CFD5F6;background:var(--brand-wash)">
                      <svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z" /><circle cx="12" cy="12" r="3" /></svg>
                      revealed · record open
                      <span :if={window_for(@reveal_windows, d.id)} class="row-countdown">
                        (expires {clock(window_for(@reveal_windows, d.id).expires_at)} · {countdown(window_for(@reveal_windows, d.id).expires_at, @now)})
                      </span>
                    </span>
                  <% else %>
                    <button class="reveal-btn rev" phx-click="reveal" phx-value-driver={d.id} title="Reveals the FULL subject record (name + CDL) — a reveal grant is subject-wide">
                      <svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z" /><circle cx="12" cy="12" r="3" /></svg>
                      Reveal driver record
                    </button>
                    <%!-- T149 B5: no active grant → REQUEST one. Opens a RevealRequest + pending
                          pii_reveal approval; a DISTINCT second party approves, then the grant is
                          time-boxed. This is the REQUEST entry point the console lacked. --%>
                    <button class="request-reveal-btn rev" phx-click="request_reveal" phx-value-driver={d.id}
                      title={"Request a second-party reveal grant — a DISTINCT operator must approve; the grant is time-boxed to #{Samen.Reveal.Grants.default_window_minutes()} minutes"}>
                      Request reveal
                    </button>
                  <% end %>
                </td>
              </tr>
            </.data_table>

            <div class="gtitle">
              <h3>Load board</h3><span class="n">{length(@loads)}</span>
              <span class="lane">· non-PII operational data</span>
            </div>

            <.data_table>
              <:head>
                <th style="width:40%">Load</th>
                <th style="width:24%">Lane</th>
                <th style="width:18%">Value</th>
                <th style="width:18%">Status</th>
              </:head>

              <tr :for={l <- @loads} class="load-row">
                <td class="l-name"><span class="nm" style="color:#3a3b45;letter-spacing:normal">{l.name}</span></td>
                <td class="l-lane"><span class="mono">{l.__lane__}</span></td>
                <td class="l-value mono num">{dollars(l.value)}</td>
                <td class="l-status"><.pill variant={status_variant(l.status)}>{l.status}</.pill></td>
              </tr>
            </.data_table>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The mask-bar chip: session TTL + reason if the accountability entry is present.
  defp session_chip(nil), do: "no active grant"
  defp session_chip(info), do: "session active · reason: #{info.reason}"

  # The reveal action: attempt to unmask ONE driver's CDL number via the second-party
  # grant path (Samen.Reveal.reveal/5). Denies (no state change, •••• stays) unless a
  # distinct party has approved a grant for (operator, driver).
  # T150 F2 — open a real impersonation session (reason required) from the denied-state form,
  # then reload so the roster renders masked. The operator role comes from the
  # `Samen.Web.Operator.Authz` on_mount (`:samen_operator_role`); `may_impersonate?` gates it.
  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    operator_id = socket.assigns[:operator_id]
    role = socket.assigns[:samen_operator_role]

    case Samen.Web.Operator.Impersonation.open(operator_id, role, socket.assigns[:org_id], reason) do
      {:ok, _session} ->
        {:noreply, load(socket, operator_id, socket.assigns[:org_id])}

      {:error, reason} ->
        {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  # T149 B5 — REQUEST a second-party reveal grant (the REQUEST side of the existing lifecycle).
  # Grants nothing; a DISTINCT second party must approve, after which the grant is time-boxed.
  # The reason names the impersonation session context (or a bounded default), never the person —
  # `Samen.Reveal.Grants.request/1` fail-closed REJECTS a PII-shaped reason.
  def handle_event("request_reveal", %{"driver" => driver_id}, socket) do
    operator_id = socket.assigns[:operator_id]
    reason = request_reason(socket.assigns[:session_info])

    case Driftwood.OperatorReveal.request_reveal(operator_id, driver_id, reason) do
      {:ok, _request} ->
        window = Samen.Reveal.Grants.default_window_minutes()

        notice =
          "Reveal requested for driver #{driver_id}. A DISTINCT second operator must approve " <>
            "the request (self-approval is refused); once approved the grant is time-boxed to " <>
            "#{window} minutes and written to this tenant's audit log."

        {:noreply, assign(socket, request_notice: notice)}

      {:error, {:pii_shaped_reason, _}} ->
        {:noreply, assign(socket, request_notice: "The reveal reason must name the ticket, not the person.")}

      {:error, _reason} ->
        {:noreply, assign(socket, request_notice: "Could not open a reveal request.")}
    end
  end

  def handle_event("reveal", %{"driver" => driver_id}, socket) do
    case Driftwood.OperatorReveal.reveal_cdl(socket.assigns.operator_id, driver_id) do
      {:ok, plaintext} ->
        revealed = Map.put(socket.assigns.revealed, cast_id(socket, driver_id), plaintext)
        {:noreply, assign(socket, revealed: revealed)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "reveal denied — no active second-party grant")}
    end
  end

  # The reveal-request reason: reuse the active impersonation session's (ticket-shaped) reason
  # when present, else a bounded default. Never PII-shaped (the kernel would reject it anyway).
  defp request_reason(%{reason: reason}) when is_binary(reason) and reason != "",
    do: "reveal for #{reason}"

  defp request_reason(_), do: "operator console reveal request"

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  defp cast_id(socket, driver_id) do
    case Enum.find(socket.assigns.drivers, &(to_string(&1.id) == driver_id)) do
      nil -> driver_id
      d -> d.id
    end
  end

  # Per-second tick (connected sessions only): advance the countdown clock and recompute
  # the open windows. The moment a window CLOSES (its grant expired), reload the roster so
  # the value re-masks live — closing the P6-F5 residual where a revealed value lingered in
  # the socket assign until the next full mount.
  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    %{operator_id: operator_id, org_id: org_id} = socket.assigns
    now = DateTime.utc_now()
    windows = reveal_windows(operator_id, now)

    socket =
      if length(windows) < length(socket.assigns.reveal_windows) do
        # A window just expired — full reload re-masks the roster + drops stale reveals.
        load(socket, operator_id, org_id)
      else
        assign(socket, now: now, reveal_windows: windows)
      end

    {:noreply, socket}
  end

  # --- Reveal-window legibility helpers (R-P6) ------------------------------

  # Is this subject inside an OPEN reveal window right now? Returns the window map or nil.
  defp window_for(reveal_windows, subject_id) do
    sid = to_string(subject_id)
    Enum.find(reveal_windows, fn w -> to_string(w.subject_id) == sid end)
  end

  # Actual resolution state of a row, independent of HOW it resolved (click vs passive
  # grant-gated read): a value that is NOT a %Samen.Masked{} is already plaintext.
  defp resolved?(%Samen.Masked{}), do: false
  defp resolved?(_), do: true

  # A row is "revealed" if it was clicked (@revealed), OR the value already resolved to
  # plaintext on the passive path, OR the subject sits in an open window (P6-F3: the
  # indicator reflects state, not just the click handler).
  defp row_revealed?(revealed, reveal_windows, d) do
    Map.get(revealed, d.id) != nil or resolved?(d.cdl_number) or
      window_for(reveal_windows, d.id) != nil
  end

  # Human-readable countdown to expiry, e.g. "4m 32s". Never negative.
  defp countdown(expires_at, now) do
    secs = max(DateTime.diff(expires_at, now, :second), 0)
    "#{div(secs, 60)}m #{rem(secs, 60)}s"
  end

  defp clock(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S UTC")
  defp clock(_), do: "—"

  # P6-F6: the resolved composite name renders as a map — format it "First Last" for
  # humans. A masked value (%Samen.Masked{}) is returned untouched so it still renders ••••.
  defp fmt_name(%Samen.Masked{} = m), do: m
  defp fmt_name(%{"first" => f, "last" => l}), do: "#{f} #{l}"
  defp fmt_name(%{first: f, last: l}), do: "#{f} #{l}"
  defp fmt_name(other), do: other
end
