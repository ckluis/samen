defmodule DriftwoodWeb.BrokerLive do
  @moduledoc """
  The TENANT plane (T5.3 clause (a)) — the Driftwood broker's own console for ONE
  brokerage org. Four panels selected by `?panel=`:

    * `dashboard` (default) — the rollup-backed load/settlement SUMMARY. Reads the small
      per-org `dbs_broker_summary` rollup via `Driftwood.BrokerRollup.summary/2` — NEVER
      a raw scan of `fop_opportunity` / `stl_settlement`.
    * `loads` — the LOAD BOARD (`Driftwood.Reads.load_board/1`): name / value / status /
      lane. Non-PII.
    * `roster` — the DRIVER ROSTER (`Driftwood.Reads.driver_roster/1`) with the FMCSA
      status badge computed per driver (medical/CDL expiry + driver status). Driver name
      + CDL number are vault-routed; on the tenant plane the broker's own scope has no
      reveal grant here either, so they render `••••` — the roster shows FMCSA STATUS,
      not driver PII.
    * `settlements` — the reshaped two-sided money (`Driftwood.Reads.settlements/1`):
      gross − advances − factoring_fee − claims = net_payable, with carryover.

  The org is chosen by `?org=<uuid>` (a LOCAL DOGFOOD convenience — a real deploy derives
  the tenant org from the authenticated session; see docs/driftwood-dogfood.md). The
  broker actor is a tenant member of that org. Every read goes through Ash with this
  scope, so OrgScope confines the view to the broker's own org.
  """
  use Phoenix.LiveView

  alias Driftwood.{BrokerRollup, Reads}

  @impl true
  def mount(params, _session, socket) do
    org_id = param(params, "org")
    panel = panel(params)

    {:ok, load_panel(assign(socket, org_id: org_id, panel: panel), panel, org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    panel = panel(params)
    org_id = param(params, "org") || socket.assigns.org_id
    {:noreply, load_panel(assign(socket, panel: panel, org_id: org_id), panel, org_id)}
  end

  # Public load path so the dogfood test can drive the exact same code.
  @doc false
  def load_panel(socket, _panel, nil) do
    assign(socket,
      no_org: true,
      summary: nil,
      loads: [],
      drivers: [],
      settlements: []
    )
  end

  def load_panel(socket, panel, org_id) do
    scope = broker_scope(org_id)

    assign(socket,
      no_org: false,
      summary: (if panel == "dashboard", do: BrokerRollup.summary(org_id), else: nil),
      loads: (if panel == "loads", do: Reads.load_board(scope), else: []),
      drivers: (if panel == "roster", do: Reads.driver_roster(scope), else: []),
      settlements: (if panel == "settlements", do: Reads.settlements(scope), else: [])
    )
  end

  # A tenant-member scope for the broker over their own org (no reveal grant).
  @doc false
  def broker_scope(org_id) do
    %Samen.Scope{actor: %{org_id: org_id, role: :member, kind: :tenant}}
  end

  defp panel(params), do: param(params, "panel") || "dashboard"
  defp param(params, key), do: Map.get(params, key)

  defp dollars(cents) when is_integer(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp dollars(_), do: "$0.00"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="broker-console">
      <h1>Driftwood — Broker Console</h1>

      <%= if @no_org do %>
        <p id="no-org">No brokerage org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.</p>
      <% else %>
        <p id="org-banner">Brokerage org: {@org_id}</p>
        <nav id="broker-nav">
          <a href={"/broker?panel=dashboard&org=#{@org_id}"}>Dashboard</a>
          <a href={"/broker?panel=loads&org=#{@org_id}"}>Load board</a>
          <a href={"/broker?panel=roster&org=#{@org_id}"}>Driver roster</a>
          <a href={"/broker?panel=settlements&org=#{@org_id}"}>Settlements</a>
        </nav>

        <%= if @panel == "dashboard" do %>
          <section id="dashboard">
            <h2>Dashboard (rollup-backed — reads dbs_broker_summary, never raw scans)</h2>
            <h3>Loads by status</h3>
            <table id="load-summary">
              <thead><tr><th>Status</th><th>Loads</th><th>Gross</th></tr></thead>
              <tbody>
                <%= for row <- (@summary && @summary.by_status) || [] do %>
                  <tr class="summary-row">
                    <td class="s-status">{row.status}</td>
                    <td class="s-loads">{row.load_count}</td>
                    <td class="s-gross">{dollars(row.gross_cents)}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
            <h3>Settlements</h3>
            <%= if @summary && @summary.settlements do %>
              <p id="settlement-summary">
                {@summary.settlements.settlement_count} settlements —
                net payable {dollars(@summary.settlements.net_payable_cents)}
                (gross {dollars(@summary.settlements.gross_cents)})
              </p>
            <% else %>
              <p id="settlement-summary">No settlements rolled up yet.</p>
            <% end %>
          </section>
        <% end %>

        <%= if @panel == "loads" do %>
          <section id="loads">
            <h2>Load board</h2>
            <table id="load-board">
              <thead><tr><th>Load</th><th>Lane</th><th>Value</th><th>Status</th></tr></thead>
              <tbody>
                <%= for l <- @loads do %>
                  <tr class="load-row">
                    <td class="l-name">{l.name}</td>
                    <td class="l-lane">{l.__lane__}</td>
                    <td class="l-value">{dollars(l.value_cents)}</td>
                    <td class="l-status">{l.status}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </section>
        <% end %>

        <%= if @panel == "roster" do %>
          <section id="roster">
            <h2>Driver roster (FMCSA status)</h2>
            <table id="driver-roster">
              <thead>
                <tr>
                  <th>Driver</th><th>CDL #</th><th>CDL state</th><th>CDL expiry</th>
                  <th>Medical expiry</th><th>Status</th><th>FMCSA</th><th>Dispatch</th>
                </tr>
              </thead>
              <tbody>
                <%= for d <- @drivers do %>
                  <tr class="driver-row" id={"driver-#{d.id}"}>
                    <td class="d-name">{d.full_name}</td>
                    <td class="d-cdl">{d.cdl_number}</td>
                    <td class="d-cdl-state">{d.cdl_state}</td>
                    <td class="d-cdl-expiry">{d.cdl_expiry}</td>
                    <td class="d-med-expiry">{d.medical_card_expiry}</td>
                    <td class="d-status">{d.status}</td>
                    <td class="d-fmcsa">
                      <%= case d.__fmcsa__ do %>
                        <% :ok -> %>
                          <span class="fmcsa-ok">OK</span>
                        <% {:blocked, reasons} -> %>
                          <span class="fmcsa-blocked">BLOCKED: {Enum.map_join(reasons, ", ", &Reads.reason_label/1)}</span>
                      <% end %>
                    </td>
                    <td class="d-dispatch">
                      <%= if Reads.dispatchable?(d) do %>
                        <button class="dispatch-btn" phx-click="dispatch" phx-value-driver={d.id}>Dispatch</button>
                      <% else %>
                        <button class="dispatch-btn" disabled>Dispatch (blocked)</button>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </section>
        <% end %>

        <%= if @panel == "settlements" do %>
          <section id="settlements">
            <h2>Settlements (reshaped money: linehaul − advances − factoring − claims)</h2>
            <table id="settlement-table">
              <thead>
                <tr>
                  <th>Linehaul</th><th>Advances</th><th>Factoring fee</th>
                  <th>Claims</th><th>Net payable</th><th>Carryover</th><th>Status</th>
                </tr>
              </thead>
              <tbody>
                <%= for s <- @settlements do %>
                  <tr class="settlement-row" id={"settlement-#{s.id}"}>
                    <td class="st-linehaul">{dollars(s.linehaul_cents)}</td>
                    <td class="st-advances">{dollars(s.advances_cents)}</td>
                    <td class="st-factoring">{dollars(s.factoring_fee_cents)}</td>
                    <td class="st-claims">{dollars(s.claim_deduction_cents)}</td>
                    <td class="st-net">{dollars(s.net_payable_cents)}</td>
                    <td class="st-carryover">{dollars(s.carryover_cents)}</td>
                    <td class="st-status">{s.status}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </section>
        <% end %>
      <% end %>
    </div>
    """
  end

  # The dispatch action guard on the tenant plane: even the phx-click path routes through
  # the FMCSA gate. The button for a blocked driver is disabled in the render, and this
  # handler re-checks server-side (defence in depth) — an FMCSA-blocked driver never
  # dispatches from the UI action.
  @impl true
  def handle_event("dispatch", %{"driver" => driver_id}, socket) do
    case dispatch_decision(socket.assigns.org_id, driver_id) do
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "driver not found")}
      {:error, :fmcsa_blocked} -> {:noreply, put_flash(socket, :error, "dispatch refused — driver is FMCSA-blocked")}
      {:ok, _} -> {:noreply, put_flash(socket, :info, "driver #{driver_id} is dispatchable")}
    end
  end

  @doc """
  The UI-action dispatch DECISION (pure — no flash/socket): refuse an FMCSA-blocked or
  unknown driver, allow a compliant one. Extracted so it is testable without a live
  socket AND shared by the handler. Mirrors the server-side `FmcsaDispatchGate`
  (defence in depth over the disabled button).
  """
  @spec dispatch_decision(binary(), binary()) ::
          {:ok, map()} | {:error, :not_found | :fmcsa_blocked}
  def dispatch_decision(org_id, driver_id) do
    scope = broker_scope(org_id)
    driver = Enum.find(Reads.driver_roster(scope), &(to_string(&1.id) == driver_id))

    cond do
      is_nil(driver) -> {:error, :not_found}
      not Reads.dispatchable?(driver) -> {:error, :fmcsa_blocked}
      true -> {:ok, driver}
    end
  end
end
