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
          drivers: Reads.driver_roster(scope),
          loads: Reads.load_board(scope),
          revealed: %{},
          now: now,
          reveal_windows: reveal_windows(operator_id, now),
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
      drivers: [],
      loads: [],
      revealed: %{},
      now: DateTime.utc_now(),
      reveal_windows: [],
      session_info: nil
    )
  end

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
          crumbs={["Operator plane", "Impersonation", @org_id, "Drivers"]}
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
            <div class="card" id="session-state" style="padding:22px 20px;color:var(--red)">
              access denied — no active impersonation session (expired or never opened).
            </div>
          </div>
        <% else %>
          <.mask_bar chip={session_chip(@session_info)}>
            <b>Masked impersonation.</b>
            <span id="banner">
              Impersonating brokerage org {@org_id} as operator {@operator_id}. PII is masked (••••).
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
  @impl true
  def handle_event("reveal", %{"driver" => driver_id}, socket) do
    case Driftwood.OperatorReveal.reveal_cdl(socket.assigns.operator_id, driver_id) do
      {:ok, plaintext} ->
        revealed = Map.put(socket.assigns.revealed, cast_id(socket, driver_id), plaintext)
        {:noreply, assign(socket, revealed: revealed)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "reveal denied — no active second-party grant")}
    end
  end

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
