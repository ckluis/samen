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
  approved a reveal grant for `(operator, driver)`, the operator can unmask THAT ONE
  driver's CDL number end-to-end via `Samen.Reveal.reveal/5` (the single decrypt
  chokepoint). Without an approving grant it denies — `••••` stays. The dogfood /
  adversarial tests drive both the granted and ungranted paths.

  ## Mount contract

  `mount/3` reads `operator_id` + `org_id` from params/session (a real deploy sets these
  from the operator's authenticated session + the org they chose). It builds the
  impersonation scope PER MOUNT (deny-on-read): an expired/absent session yields
  `{:error, :session_inactive}` and the view renders the access-denied state, no data.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Samen.Impersonation
  alias Driftwood.Reads

  @impl true
  def mount(params, session, socket) do
    operator_id = fetch(params, session, "operator_id")
    org_id = fetch(params, session, "org_id")
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
        assign(socket,
          impersonating: true,
          session_inactive: false,
          operator_id: operator_id,
          org_id: org_id,
          drivers: Reads.driver_roster(scope),
          loads: Reads.load_board(scope),
          revealed: %{},
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
      session_info: nil
    )
  end

  # The tenant-visible accountability entry for THIS operator over THIS org.
  defp session_info(org_id, operator_id) do
    org_id
    |> Impersonation.list_for_org()
    |> Enum.find(fn e -> e.operator_id == operator_id and e.active? end)
  end

  defp fetch(params, session, key), do: Map.get(params, key) || Map.get(session, key)

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
            <span :if={@session_info} id="session-reason" style="display:none">Reason: {@session_info.reason}</span>
            <span :if={@session_info} id="session-expiry" style="display:none">Expires: {@session_info.expires_at}</span>
          </.mask_bar>

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
                    <span class="nm masked d-name">{d.full_name}</span>
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
                  <%= if Map.get(@revealed, d.id) do %>
                    <span class="revealed rev" style="color:var(--brand);border-color:#CFD5F6;background:var(--brand-wash)">
                      <svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z" /><circle cx="12" cy="12" r="3" /></svg>
                      revealed (grant active)
                    </span>
                  <% else %>
                    <button class="reveal-btn rev" phx-click="reveal" phx-value-driver={d.id}>
                      <svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z" /><circle cx="12" cy="12" r="3" /></svg>
                      Reveal CDL
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
                <td class="l-value mono num">{dollars(l.value_cents)}</td>
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
end
