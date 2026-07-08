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
      + CDL number are vault-routed. F2 (Gate-5 carry): the broker scope carries
      `plane: :tenant`, so the roster reads its OWN drivers' name + CDL number in CLEAR —
      the doc's two-key-classes tenant-as-owner rule (§external-surface :707): a tenant
      reads its own org's PII per its own RBAC with NO operator reveal grant. The vault
      token itself never renders (plaintext comes through the single decrypt chokepoint).
      The OPERATOR impersonation plane (`plane: :operator`) still renders `••••` — the
      same shared `Samen.Api.PiiResolution` resolver, opposite plane.
    * `settlements` — the reshaped two-sided money (`Driftwood.Reads.settlements/1`):
      gross − advances − factoring_fee − claims = net_payable, with carryover.

  The org is chosen by `?org=<uuid>` (a LOCAL DOGFOOD convenience — a real deploy derives
  the tenant org from the authenticated session; see docs/driftwood-dogfood.md). The
  broker actor is a tenant member of that org. Every read goes through Ash with this
  scope, so OrgScope confines the view to the broker's own org.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

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

  # A tenant-member scope for the broker over their own org.
  #
  # F2 (Gate-5 carry): the actor carries `plane: :tenant`. This is the doc's
  # (§external-surface :707) "two key classes" tenant-as-owner posture: a tenant reads
  # its OWN org's PII in CLEAR per its own RBAC, with NO operator reveal grant (the
  # reveal seam is operator-scoped; it does not sit between a tenant and its own
  # records). `Driftwood.Reads.driver_roster/1` threads this scope through the SHARED
  # tenant-plane resolver `Samen.Api.PiiResolution.resolve/4`, which — on the `:tenant`
  # plane — unmasks the driver's vaulted `full_name`/`cdl_number` to plaintext through
  # the single vault chokepoint. The OPERATOR impersonation scope carries
  # `plane: :operator` + an `:impersonation` marker, so the SAME resolver keeps its PII
  # `%Masked{}` (••••) — fixing today's fail-safe over-masking without opening the
  # operator plane. OrgScope keys only on `org_id`, so `plane` does not affect isolation.
  @doc false
  def broker_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "broker:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  # Map the current freight panel to the shared `module_nav/1` active key.
  defp broker_active("dashboard"), do: :dashboard
  defp broker_active("loads"), do: :loads
  defp broker_active("roster"), do: :roster
  defp broker_active("settlements"), do: :settlements
  defp broker_active(_), do: :dashboard

  defp panel(params), do: param(params, "panel") || "dashboard"
  defp param(params, key), do: Map.get(params, key)

  defp dollars(cents) when is_integer(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp dollars(_), do: "$0.00"

  # Format a CLEARTEXT driver name for display (tenant plane owns its own PII). The
  # vaulted `full_name` resolves to a JSON string (`{"first":"Dana","last":"Compliant"}`)
  # on the `:tenant` plane; this parses it to `"Dana Compliant"`.
  #
  # MASKING INVARIANT (load-bearing): a `%Samen.Masked{}` is returned UNTOUCHED so it
  # still renders `••••` via Phoenix.HTML.Safe. This helper never unwraps/inspects a
  # Masked value — it only reshapes an already-resolved cleartext string. On the operator
  # plane `full_name` is a `%Masked{}`, so this would pass it straight through, but the
  # operator view does not call this — the broker (tenant) plane does.
  defp driver_name(%Samen.Masked{} = masked), do: masked

  defp driver_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp driver_name(other), do: other

  # Initials for a cleartext driver name (tenant plane owns its own PII).
  defp initials(%Samen.Masked{}), do: "··"

  defp initials(name) when is_binary(name) do
    case driver_name(name) do
      %Samen.Masked{} ->
        "··"

      formatted when is_binary(formatted) ->
        formatted
        |> String.split(~r/\s+/, trim: true)
        |> Enum.take(2)
        |> Enum.map_join("", &String.slice(&1, 0, 1))
        |> String.upcase()
    end
  end

  defp initials(_), do: "··"

  # Load status → pill variant.
  defp status_variant(s) when s in [:on_load, "on_load", :en_route, "en_route"], do: "info"
  defp status_variant(s) when s in [:delivered, "delivered", :paid, "paid"], do: "ok"
  defp status_variant(s) when s in [:open, "open", :needs_carrier, "needs_carrier"], do: "warn"
  defp status_variant(s) when s in [:out_of_service, "out_of_service", :terminated, "terminated"], do: "bad"
  defp status_variant(_), do: "mut"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="broker-console">
      <.app_shell>
        <:sidebar>
          <.sidebar
            title="Blue Ridge Logistics"
            subtitle="Freight brokerage"
            logo="B"
            logo_style="background:linear-gradient(150deg,#0E7C5A,#17A06E)"
          >
            <:search>
              <div class="search">
                <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
                </svg>
                Search loads, carriers…
                <span class="kbd">⌘K</span>
              </div>
            </:search>

            <.module_nav org_id={@org_id} active={broker_active(@panel)} />

            <:footer>
              <div class="foot">
                <div class="av" style="background:#D6E9DF;color:#1E7A45">RM</div>
                <div class="m"><b>Rosa Medina</b><span>dispatcher</span></div>
              </div>
            </:footer>
          </.sidebar>
        </:sidebar>

        <.topbar title={panel_title(@panel)} crumbs={["Blue Ridge Logistics", "Operations", panel_title(@panel)]}>
          <:actions>
            <.button>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M7 12h10M10 18h4" /></svg>
              </:icon>
              Filter
            </.button>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v18M3 12h18" /></svg>
              </:icon>
              New load
            </.button>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No brokerage org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
        <% else %>
          <span id="org-banner" style="display:none">Brokerage org: {@org_id}</span>

          <%= if @panel == "dashboard" do %>
            {dashboard_metrics(assigns)}
            <div class="wrap">
              <div id="dashboard">
                <div class="gtitle">
                  <h3>Loads by status</h3>
                  <span class="lane">· rollup-backed — reads dbs_broker_summary, never raw scans</span>
                </div>
                <.data_table>
                  <:head>
                    <th style="width:40%">Status</th>
                    <th style="width:30%">Loads</th>
                    <th style="width:30%">Gross</th>
                  </:head>
                  <tr :for={row <- (@summary && @summary.by_status) || []} class="summary-row">
                    <td class="s-status"><.pill variant={status_variant(row.status)}>{row.status}</.pill></td>
                    <td class="s-loads num">{row.load_count}</td>
                    <td class="s-gross mono num">{dollars(row.gross_cents)}</td>
                  </tr>
                </.data_table>

                <div class="gtitle"><h3>Settlements</h3></div>
                <div class="settle">
                  <div class="sh">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--brand)" stroke-width="1.9"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
                    <b>Settlement rollup</b><span class="tag">rollup-backed</span>
                  </div>
                  <%= if @summary && @summary.settlements do %>
                    <div class="row"><span class="lab">Settlements</span><span class="val">{@summary.settlements.settlement_count}</span></div>
                    <div class="row"><span class="lab">Gross</span><span class="val">{dollars(@summary.settlements.gross_cents)}</span></div>
                    <div class="row net">
                      <span class="lab">net payable</span>
                      <span class="val" id="settlement-summary">{dollars(@summary.settlements.net_payable_cents)}</span>
                    </div>
                  <% else %>
                    <div class="row"><span class="lab" id="settlement-summary">No settlements rolled up yet.</span></div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @panel == "loads" do %>
            <div class="wrap">
              <div id="loads">
                <div class="gtitle">
                  <h3>Active loads</h3><span class="n">{length(@loads)}</span>
                  <span class="lane">· your org — driver names in the clear</span>
                </div>
                <.data_table>
                  <:head>
                    <th style="width:34%">Load</th>
                    <th style="width:26%">Lane</th>
                    <th style="width:22%">Rate</th>
                    <th style="width:18%">Status</th>
                  </:head>
                  <tr :for={l <- @loads} class="load-row">
                    <td class="l-name"><span class="mono" style="color:#454652;font-weight:500">{l.name}</span></td>
                    <td class="l-lane carrier">{l.__lane__}</td>
                    <td class="l-value mono num">{dollars(l.value_cents)}</td>
                    <td class="l-status"><.pill variant={status_variant(l.status)}>{l.status}</.pill></td>
                  </tr>
                </.data_table>
              </div>
            </div>
          <% end %>

          <%= if @panel == "roster" do %>
            <div class="wrap">
              <div id="roster">
                <div class="gtitle">
                  <h3>Driver roster</h3><span class="n">{length(@drivers)}</span>
                  <span class="lane">· your org — driver names in the clear</span>
                </div>
                <.data_table>
                  <:head>
                    <th style="width:22%">Driver</th>
                    <th style="width:14%">CDL #</th>
                    <th style="width:10%">State</th>
                    <th style="width:12%">CDL expiry</th>
                    <th style="width:12%">Med card</th>
                    <th style="width:10%">Status</th>
                    <th style="width:10%">FMCSA</th>
                    <th style="width:10%">Dispatch</th>
                  </:head>
                  <tr :for={d <- @drivers} class="driver-row" id={"driver-#{d.id}"}>
                    <td>
                      <div class="drv">
                        <div class="av" style="background:#DDE7F5;color:#3B4CCA;font-size:10px;font-weight:600">{initials(d.full_name)}</div>
                        <span class="nm d-name" style="color:#3a3b45;letter-spacing:normal">{driver_name(d.full_name)}</span>
                      </div>
                    </td>
                    <td class="d-cdl"><span class="mono">{d.cdl_number}</span></td>
                    <td class="d-cdl-state carrier">{d.cdl_state}</td>
                    <td class="d-cdl-expiry carrier">{d.cdl_expiry}</td>
                    <td class="d-med-expiry carrier">{d.medical_card_expiry}</td>
                    <td class="d-status"><.pill variant={status_variant(d.status)}>{d.status}</.pill></td>
                    <td class="d-fmcsa">
                      <%= case d.__fmcsa__ do %>
                        <% :ok -> %>
                          <span class="fmcsa-ok"><.pill variant="ok">OK</.pill></span>
                        <% {:blocked, reasons} -> %>
                          <span class="fmcsa-blocked"><.pill variant="bad">BLOCKED: {Enum.map_join(reasons, ", ", &Reads.reason_label/1)}</.pill></span>
                      <% end %>
                    </td>
                    <td class="d-dispatch">
                      <%= if Reads.dispatchable?(d) do %>
                        <button class="dispatch-btn btn" phx-click="dispatch" phx-value-driver={d.id}>Dispatch</button>
                      <% else %>
                        <button class="dispatch-btn btn" disabled>Dispatch (blocked)</button>
                      <% end %>
                    </td>
                  </tr>
                </.data_table>
              </div>
            </div>
          <% end %>

          <%= if @panel == "settlements" do %>
            <div class="wrap">
              <div id="settlements">
                <div class="split">
                  <div>
                    <div class="gtitle">
                      <h3>Settlements</h3><span class="n">{length(@settlements)}</span>
                      <span class="lane">· reshaped: linehaul − advances − factoring − claims</span>
                    </div>
                    <div id="settlement-table">
                      <.data_table>
                        <:head>
                          <th>Linehaul</th>
                          <th>Advances</th>
                          <th>Factoring</th>
                          <th>Claims</th>
                          <th>Net payable</th>
                          <th>Status</th>
                        </:head>
                        <tr :for={s <- @settlements} class="settlement-row" id={"settlement-#{s.id}"}>
                          <td class="st-linehaul mono num">{dollars(s.linehaul_cents)}</td>
                          <td class="st-advances mono num">{dollars(s.advances_cents)}</td>
                          <td class="st-factoring mono num">{dollars(s.factoring_fee_cents)}</td>
                          <td class="st-claims mono num">{dollars(s.claim_deduction_cents)}</td>
                          <td class="st-net mono num" style="color:var(--green)">{dollars(s.net_payable_cents)}</td>
                          <td class="st-carryover" style="display:none">{dollars(s.carryover_cents)}</td>
                          <td class="st-status"><.pill variant={status_variant(s.status)}>{s.status}</.pill></td>
                        </tr>
                      </.data_table>
                    </div>
                  </div>

                  <div :if={List.first(@settlements)}>
                    <% s = List.first(@settlements) %>
                    <div class="gtitle"><h3>Carrier settlement</h3></div>
                    <div class="settle">
                      <div class="sh">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--brand)" stroke-width="1.9"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
                        <b>Carrier settlement</b><span class="tag">reshaped</span>
                      </div>
                      <div class="row"><span class="lab">Linehaul</span><span class="val">{dollars(s.linehaul_cents)}</span></div>
                      <div class="row neg"><span class="lab">Advances</span><span class="val">−{dollars(s.advances_cents)}</span></div>
                      <div class="row neg"><span class="lab">Factoring</span><span class="val">−{dollars(s.factoring_fee_cents)}</span></div>
                      <div class="row neg"><span class="lab">Claims</span><span class="val">−{dollars(s.claim_deduction_cents)}</span></div>
                      <div class="row net"><span class="lab">Net payable</span><span class="val">{dollars(s.net_payable_cents)}</span></div>
                      <div class="foot2">
                        Kernel <span class="mono" style="color:var(--brand)">Invoice</span> reshaped to two-sided settlement via a bounded-context calculation — the vertical's money model, the substrate's audit &amp; vault underneath.
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The dispatch-board metric cards (screen 3): derived from the rollup summary. Non-PII
  # counts + cents only.
  defp dashboard_metrics(assigns) do
    ~H"""
    <div class="metrics">
      <.metric label="Loads (rolled up)" value={dashboard_load_count(@summary)}>
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 7h13l5 5v5H3z" /></svg>
        </:icon>
      </.metric>
      <.metric label="Load statuses" value={length((@summary && @summary.by_status) || [])} sub="distinct status buckets">
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3a9 9 0 1 0 9 9" /><path d="M12 7v5l3 2" /></svg>
        </:icon>
      </.metric>
      <.metric label="Gross (rolled up)" value={dollars(dashboard_gross(@summary))} sub="load value">
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
        </:icon>
      </.metric>
      <.metric label="Net settlements" value={dashboard_net(@summary)} sub="after deductions">
        <:icon>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 6L9 17l-5-5" /></svg>
        </:icon>
      </.metric>
    </div>
    """
  end

  defp dashboard_load_count(nil), do: 0
  defp dashboard_load_count(summary), do: Enum.reduce(summary.by_status || [], 0, &(&1.load_count + &2))

  defp dashboard_gross(nil), do: 0
  defp dashboard_gross(summary), do: Enum.reduce(summary.by_status || [], 0, &(&1.gross_cents + &2))

  defp dashboard_net(nil), do: "$0.00"
  defp dashboard_net(%{settlements: nil}), do: "$0.00"
  defp dashboard_net(%{settlements: s}), do: dollars(s.net_payable_cents)

  defp panel_title("dashboard"), do: "Dispatch board"
  defp panel_title("loads"), do: "Loads"
  defp panel_title("roster"), do: "Drivers"
  defp panel_title("settlements"), do: "Settlements"
  defp panel_title(_), do: "Dispatch board"

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
