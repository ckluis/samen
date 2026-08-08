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

  require Ash.Query

  # ADR-009 — the component kit is now framework-level (`Samen.UI`), not driftwood-local.
  import Samen.UI

  # T158 — `full_name_field/1` is the SAME masking-safe composite-name form field the
  # framework CRM contact create/edit modals use (renders a `%Samen.Masked{}` value as
  # the read-only •••• placeholder with no `name` attribute; a plaintext value as nested
  # first/last inputs). Reused here (not reimplemented) for the driver create/edit form's
  # vaulted `full_name` — framework-first, no parallel form pattern.
  import Samen.Web.CRM.Live, only: [full_name_field: 1]

  alias Driftwood.{BrokerRollup, Reads}

  @impl true
  def mount(params, _session, socket) do
    org_id = param(params, "org")
    panel = panel(params)

    socket =
      assign(socket,
        org_id: org_id,
        panel: panel,
        # T148 — the "New load" create-flow state (mirrors the framework CRM create modal).
        show_new: false,
        new_load_form: nil,
        load_error: nil,
        # T158 — the real filtered load board (name/lane substring + status).
        load_filter: %{status: nil, q: ""},
        # T158 — load edit/delete state.
        show_edit_load: false,
        edit_load_id: nil,
        edit_load_form: nil,
        edit_load_error: nil,
        delete_load_error: nil,
        # T158 — driver create/edit state (mirrors the CRM contact create/edit modal —
        # a genuine `AshPhoenix.Form`, not a hand-rolled attrs map, since Driver carries
        # no Money composite the way Load does).
        show_new_driver: false,
        new_driver_form: nil,
        show_edit_driver: false,
        edit_driver_id: nil,
        edit_driver_form: nil,
        driver_error: nil,
        # T158 — settlement create/edit state (same AshPhoenix.Form pattern; Settlement's
        # stored inputs are plain integer-cents attributes, no composite type).
        show_new_settlement: false,
        new_settlement_form: nil,
        show_edit_settlement: false,
        edit_settlement_id: nil,
        edit_settlement_form: nil,
        settlement_error: nil
      )

    {:ok, load_panel(socket, panel, org_id)}
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
    filter = Map.get(socket.assigns, :load_filter) || %{}

    assign(socket,
      no_org: false,
      summary: (if panel == "dashboard", do: BrokerRollup.summary(org_id), else: nil),
      loads: (if panel == "loads", do: Reads.load_board(scope, filter), else: []),
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

  defp panel(params), do: param(params, "panel") || "dashboard"
  defp param(params, key), do: Map.get(params, key)

  # ADR-036 §4.5(4): l.value is now the Money composite (dollars(l.value)).
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
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
    # T148/T158 — default the create/edit-flow assigns so the render is self-sufficient for
    # the direct-`render/1` harness tests (the live mount always sets them, so this is a
    # no-op there).
    assigns =
      assigns
      |> Map.put_new(:show_new, false)
      |> Map.put_new(:new_load_form, nil)
      |> Map.put_new(:load_error, nil)
      |> Map.put_new(:load_filter, %{status: nil, q: ""})
      |> Map.put_new(:show_edit_load, false)
      |> Map.put_new(:edit_load_id, nil)
      |> Map.put_new(:edit_load_form, nil)
      |> Map.put_new(:edit_load_error, nil)
      |> Map.put_new(:delete_load_error, nil)
      |> Map.put_new(:show_new_driver, false)
      |> Map.put_new(:new_driver_form, nil)
      |> Map.put_new(:show_edit_driver, false)
      |> Map.put_new(:edit_driver_id, nil)
      |> Map.put_new(:edit_driver_form, nil)
      |> Map.put_new(:driver_error, nil)
      |> Map.put_new(:show_new_settlement, false)
      |> Map.put_new(:new_settlement_form, nil)
      |> Map.put_new(:show_edit_settlement, false)
      |> Map.put_new(:edit_settlement_id, nil)
      |> Map.put_new(:edit_settlement_form, nil)
      |> Map.put_new(:settlement_error, nil)

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
              <%!-- T148: the search affordance is no longer decorative — it links to the real
                    mounted framework ⌘K search LiveView (`samen_search_routes` → /search). --%>
              <a href={search_href(@org_id)} class="search" id="broker-search" aria-label="Search loads and carriers" style="text-decoration:none;color:inherit">
                <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
                </svg>
                Search loads, carriers…
                <span class="kbd">⌘K</span>
              </a>
            </:search>

            <%!-- ADR-009: the inherited CRM/Billing/Support groups come from the framework
                  `Samen.UI.module_nav`; Driftwood's OWN freight 20% ("Operations") is
                  passed as the `:extra` slot (a vertical's own nav is its business). --%>
            <.module_nav org_id={@org_id} active={nil}>
              <:extra>
                <.nav_group label="Operations">
                  <.nav_item label="Dispatch board" href={"/broker?panel=dashboard&org=#{@org_id}"} active={@panel == "dashboard"}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="8" height="8" rx="1.5" /><rect x="13" y="3" width="8" height="8" rx="1.5" /><rect x="3" y="13" width="8" height="8" rx="1.5" /><rect x="13" y="13" width="8" height="8" rx="1.5" /></svg>
                    </:icon>
                  </.nav_item>
                  <.nav_item label="Loads" href={"/broker?panel=loads&org=#{@org_id}"} active={@panel == "loads"}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 7h13l5 5v5H3z" /><circle cx="7.5" cy="17.5" r="1.5" /><circle cx="17.5" cy="17.5" r="1.5" /></svg>
                    </:icon>
                  </.nav_item>
                  <.nav_item label="Drivers" href={"/broker?panel=roster&org=#{@org_id}"} active={@panel == "roster"}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" /></svg>
                    </:icon>
                  </.nav_item>
                  <.nav_item label="Settlements" href={"/broker?panel=settlements&org=#{@org_id}"} active={@panel == "settlements"}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
                    </:icon>
                  </.nav_item>
                </.nav_group>
              </:extra>
            </.module_nav>

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
            <%!-- T148: "New load" is wired to the real create flow (`create_load/2`).
                  T158: the create action is now CONTEXTUAL to the active panel — "New load" on
                  Loads, "New driver" on Drivers, "New settlement" on Settlements — instead of
                  showing "New load" everywhere regardless of the open panel. The dead "Filter"
                  button T148 removed is replaced by a REAL filter bar inline on the Loads panel
                  (it needs the filtered `load_board/2` read; a header button toggling nothing
                  useful is worse than none). --%>
            <.button :if={not @no_org and @panel == "loads"} variant="primary" phx-click="new_load" id="new-load">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v18M3 12h18" /></svg>
              </:icon>
              New load
            </.button>
            <.button :if={not @no_org and @panel == "roster"} variant="primary" phx-click="new_driver" id="new-driver">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v18M3 12h18" /></svg>
              </:icon>
              New driver
            </.button>
            <.button :if={not @no_org and @panel == "settlements"} variant="primary" phx-click="new_settlement" id="new-settlement">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v18M3 12h18" /></svg>
              </:icon>
              New settlement
            </.button>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <%!-- T148: was a dev instruction ("Append ?org=<uuid>"). Now a user-facing empty
                state that routes a new tenant into the framework onboarding wizard. --%>
          <div class="wrap" id="no-org">
            <.empty_state
              title="No brokerage workspace selected"
              body="Choose a brokerage from your workspaces to open its dispatch board — or set one up to get started."
              icon="◈"
            >
              <:actions>
                <a href="/onboarding" class="btn primary" id="no-org-onboarding" style="text-decoration:none">Set up a workspace</a>
              </:actions>
            </.empty_state>
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
                <div :if={@delete_load_error} class="card form-error" id="delete-load-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:12px">
                  {@delete_load_error}
                </div>

                <%!-- T158: the REAL load-board filter (replaces T148's removed dead Filter
                      button). `phx-change` fires on every keystroke/select change — always
                      org-scoped underneath (`Reads.load_board/2` never widens past the
                      broker's own org; the filter only narrows within it). --%>
                <form phx-change="filter_loads" id="load-filter-form" style="display:flex;gap:8px;align-items:center;margin-bottom:14px;flex-wrap:wrap">
                  <input
                    type="text"
                    name="q"
                    id="load-filter-q"
                    value={Map.get(@load_filter, :q, "")}
                    placeholder="Search load reference or lane…"
                    style="flex:1;min-width:220px;padding:7px 10px;border:1px solid var(--border,#D0D5DD);border-radius:8px;font-size:13px"
                  />
                  <select name="status" id="load-filter-status" style="padding:7px 10px;border:1px solid var(--border,#D0D5DD);border-radius:8px;font-size:13px">
                    <option value="" selected={filter_value(@load_filter, :status) in [nil, ""]}>All statuses</option>
                    <option :for={{label, val} <- load_status_options()} value={val} selected={filter_value(@load_filter, :status) == val}>
                      {label}
                    </option>
                  </select>
                  <.button :if={load_filter_active?(@load_filter)} type="button" phx-click="clear_load_filter" id="clear-load-filter">
                    Clear filter
                  </.button>
                </form>

                <div class="gtitle">
                  <h3>Active loads</h3><span class="n" id="load-count">{length(@loads)}</span>
                  <span class="lane">· your org — driver names in the clear</span>
                </div>
                <%!-- T148: a real empty state for a new/empty org (mirrors the framework CRM /
                      notifications empty states) instead of a bare header over an empty table.
                      T158: a SEPARATE honest empty state for "filter matched nothing" — never
                      fabricated rows, and never conflated with the true zero-loads onboarding
                      state (the filter-empty state offers "clear filter", not "create a load"). --%>
                <%= cond do %>
                  <% @loads == [] and load_filter_active?(@load_filter) -> %>
                    <.empty_state
                      title="No loads match this filter"
                      body="No loads on your board match this search/status. Clear the filter to see your full load board."
                      icon="◧"
                    >
                      <:actions>
                        <.button phx-click="clear_load_filter" id="empty-clear-load-filter">Clear filter</.button>
                      </:actions>
                    </.empty_state>
                  <% @loads == [] -> %>
                    <.empty_state
                      title="No loads yet"
                      body="Your load board is empty. Post your first load to start dispatching carriers and tracking settlements."
                      icon="◧"
                    >
                      <:actions>
                        <.button variant="primary" phx-click="new_load" id="empty-new-load">Create your first load</.button>
                      </:actions>
                    </.empty_state>
                  <% true -> %>
                    <.data_table>
                      <:head>
                        <th style="width:28%">Load</th>
                        <th style="width:20%">Lane</th>
                        <th style="width:18%">Rate</th>
                        <th style="width:14%">Status</th>
                        <th style="width:20%"><span class="sr-only">Actions</span></th>
                      </:head>
                      <tr :for={l <- @loads} class="load-row" id={"load-#{l.id}"}>
                        <td class="l-name"><span class="mono" style="color:#454652;font-weight:500">{l.name}</span></td>
                        <td class="l-lane carrier">{l.__lane__}</td>
                        <td class="l-value mono num">{dollars(l.value)}</td>
                        <td class="l-status"><.pill variant={status_variant(l.status)}>{l.status}</.pill></td>
                        <td class="l-actions" style="display:flex;gap:6px">
                          <.button type="button" phx-click="edit_load" phx-value-id={l.id} id={"edit-load-#{l.id}"}>Edit</.button>
                          <.delete_confirm
                            id={"delete-load-#{l.id}"}
                            message="Delete this load? This cannot be undone."
                            phx-click="delete_load"
                            phx-value-id={l.id}
                          />
                        </td>
                      </tr>
                    </.data_table>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @panel == "roster" do %>
            <div class="wrap">
              <div id="roster">
                <div :if={@driver_error} class="card form-error" id="driver-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:12px">
                  {@driver_error}
                </div>
                <div class="gtitle">
                  <h3>Driver roster</h3><span class="n">{length(@drivers)}</span>
                  <span class="lane">· your org — driver names in the clear</span>
                </div>
                <.data_table>
                  <:head>
                    <th style="width:20%">Driver</th>
                    <th style="width:12%">CDL #</th>
                    <th style="width:8%">State</th>
                    <th style="width:11%">CDL expiry</th>
                    <th style="width:11%">Med card</th>
                    <th style="width:9%">Status</th>
                    <th style="width:9%">FMCSA</th>
                    <th style="width:10%">Dispatch</th>
                    <th style="width:10%"><span class="sr-only">Actions</span></th>
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
                    <td class="d-actions">
                      <.button type="button" phx-click="edit_driver" phx-value-driver={d.id} id={"edit-driver-#{d.id}"}>Edit</.button>
                    </td>
                  </tr>
                </.data_table>
              </div>
            </div>
          <% end %>

          <%= if @panel == "settlements" do %>
            <div class="wrap">
              <div id="settlements">
                <div :if={@settlement_error} class="card form-error" id="settlement-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:12px">
                  {@settlement_error}
                </div>
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
                          <th><span class="sr-only">Actions</span></th>
                        </:head>
                        <tr :for={s <- @settlements} class="settlement-row" id={"settlement-#{s.id}"}>
                          <td class="st-linehaul mono num">{dollars(s.linehaul_cents)}</td>
                          <td class="st-advances mono num">{dollars(s.advances_cents)}</td>
                          <td class="st-factoring mono num">{dollars(s.factoring_fee_cents)}</td>
                          <td class="st-claims mono num">{dollars(s.claim_deduction_cents)}</td>
                          <td class="st-net mono num" style="color:var(--green)">{dollars(s.net_payable_cents)}</td>
                          <td class="st-carryover" style="display:none">{dollars(s.carryover_cents)}</td>
                          <td class="st-status"><.pill variant={status_variant(s.status)}>{s.status}</.pill></td>
                          <td class="st-actions">
                            <.button type="button" phx-click="edit_settlement" phx-value-settlement={s.id} id={"edit-settlement-#{s.id}"}>Edit</.button>
                          </td>
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

          <%!-- T148: the "New load" create modal (mirrors the framework CRM create modal). --%>
          <.modal :if={@show_new and @new_load_form != nil} id="new-load-modal" title="New load" on_cancel="cancel_new_load">
            <div :if={@load_error} class="card form-error" id="new-load-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:12px">
              {@load_error}
            </div>
            <.simple_form :let={f} for={@new_load_form} id="new-load-form" phx-change="validate_load" phx-submit="save_load">
              <.form_field field={f[:name]} label="Load reference" placeholder="BRL-4805 reefer" />
              <.form_field field={f[:lane]} label="Lane (origin-&gt;dest state codes)" placeholder="TX->CA" />
              <.form_field field={f[:rate]} label="Rate (USD)" type="number" min="0" step="0.01" placeholder="4800.00" />
              <.form_field field={f[:status]} label="Status" type="select" options={load_status_options()} />
              <:actions>
                <.button variant="primary" type="submit" id="save-load">Create load</.button>
                <.button type="button" phx-click="cancel_new_load">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>

          <%!-- T158: the "Edit load" modal. Same manual-attrs pattern as create_load/2 (NOT an
                AshPhoenix.Form) — the Load `value` field is the ADR-036 Money composite and
                the form only carries a bare dollars string, exactly the constraint T148's
                create modal already documents. --%>
          <.modal :if={@show_edit_load and @edit_load_form != nil} id="edit-load-modal" title="Edit load" on_cancel="cancel_edit_load">
            <div :if={@edit_load_error} class="card form-error" id="edit-load-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:12px">
              {@edit_load_error}
            </div>
            <.simple_form :let={f} for={@edit_load_form} id="edit-load-form" phx-change="validate_edit_load" phx-submit="save_edit_load">
              <.form_field field={f[:name]} label="Load reference" placeholder="BRL-4805 reefer" />
              <.form_field field={f[:lane]} label="Lane (origin-&gt;dest state codes)" placeholder="TX->CA" />
              <.form_field field={f[:rate]} label="Rate (USD)" type="number" min="0" step="0.01" placeholder="4800.00" />
              <.form_field field={f[:status]} label="Status" type="select" options={load_status_options()} />
              <:actions>
                <.button variant="primary" type="submit" id="save-edit-load">Save load</.button>
                <.button type="button" phx-click="cancel_edit_load">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>

          <%!-- T158: driver create/edit — a genuine `AshPhoenix.Form` over the real Driver
                `:create`/`:update` actions (mirrors the framework CRM contact create/edit
                modal exactly). `full_name_field`/`form_field` are the SAME masking-safe
                components the CRM modal uses — a `%Samen.Masked{}` value (never reachable
                here: `broker_scope/1` is always plane: :tenant) renders the read-only ••••
                placeholder by construction, no bespoke branch. FMCSA-gated fields (CDL/med
                expiry, status) are plain edits — the compliance GATE itself lives on
                `DispatchEvent.:dispatch`, re-evaluated fresh at dispatch time against
                whatever this form persists; editing a driver can never skip that check. --%>
          <.modal :if={@show_new_driver and @new_driver_form != nil} id="new-driver-modal" title="New driver" on_cancel="cancel_new_driver">
            <.simple_form :let={f} for={@new_driver_form} id="new-driver-form" phx-change="validate_new_driver" phx-submit="save_new_driver">
              <.full_name_field field={f[:full_name]} label="Full name (🔒 PII)" />
              <.form_field field={f[:cdl_number]} label="CDL number (🔒 PII)" />
              <.form_field field={f[:cdl_state]} label="CDL state" placeholder="TX" />
              <.form_field field={f[:cdl_expiry]} label="CDL expiry" type="date" />
              <.form_field field={f[:medical_card_expiry]} label="Medical card expiry" type="date" />
              <.form_field field={f[:eld_provider]} label="ELD provider" type="select" options={eld_provider_options()} />
              <.form_field field={f[:status]} label="Status" type="select" options={driver_status_options()} />
              <:actions>
                <.button variant="primary" type="submit" id="save-new-driver">Add driver</.button>
                <.button type="button" phx-click="cancel_new_driver">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>

          <.modal :if={@show_edit_driver and @edit_driver_form != nil} id="edit-driver-modal" title="Edit driver" on_cancel="cancel_edit_driver">
            <.simple_form :let={f} for={@edit_driver_form} id="edit-driver-form" phx-change="validate_edit_driver" phx-submit="save_edit_driver">
              <.full_name_field field={f[:full_name]} label="Full name (🔒 PII)" />
              <.form_field field={f[:cdl_number]} label="CDL number (🔒 PII)" />
              <.form_field field={f[:cdl_state]} label="CDL state" placeholder="TX" />
              <.form_field field={f[:cdl_expiry]} label="CDL expiry" type="date" />
              <.form_field field={f[:medical_card_expiry]} label="Medical card expiry" type="date" />
              <.form_field field={f[:eld_provider]} label="ELD provider" type="select" options={eld_provider_options()} />
              <.form_field field={f[:status]} label="Status" type="select" options={driver_status_options()} />
              <:actions>
                <.button variant="primary" type="submit" id="save-edit-driver">Save driver</.button>
                <.button type="button" phx-click="cancel_edit_driver">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>

          <%!-- T158: settlement create/edit — same `AshPhoenix.Form` pattern; Settlement's
                stored inputs are plain integer-cents columns (no composite type), so unlike
                Load's `value` these cast directly through the form. --%>
          <.modal :if={@show_new_settlement and @new_settlement_form != nil} id="new-settlement-modal" title="New settlement" on_cancel="cancel_new_settlement">
            <.simple_form :let={f} for={@new_settlement_form} id="new-settlement-form" phx-change="validate_new_settlement" phx-submit="save_new_settlement">
              <.form_field field={f[:linehaul_cents]} label="Linehaul (cents)" type="number" min="0" />
              <.form_field field={f[:advances_cents]} label="Advances (cents)" type="number" min="0" />
              <.form_field field={f[:fuel_surcharge_cents]} label="Fuel surcharge (cents)" type="number" min="0" />
              <.form_field field={f[:accessorial_cents]} label="Accessorial (cents)" type="number" min="0" />
              <.form_field field={f[:claim_deduction_cents]} label="Claim deduction (cents)" type="number" min="0" />
              <.form_field field={f[:factoring_rate_bps]} label="Factoring rate (bps)" type="number" min="0" max="10000" />
              <.form_field field={f[:currency]} label="Currency" placeholder="USD" />
              <.form_field field={f[:status]} label="Status" type="select" options={settlement_status_options()} />
              <:actions>
                <.button variant="primary" type="submit" id="save-new-settlement">Create settlement</.button>
                <.button type="button" phx-click="cancel_new_settlement">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>

          <.modal :if={@show_edit_settlement and @edit_settlement_form != nil} id="edit-settlement-modal" title="Edit settlement" on_cancel="cancel_edit_settlement">
            <.simple_form :let={f} for={@edit_settlement_form} id="edit-settlement-form" phx-change="validate_edit_settlement" phx-submit="save_edit_settlement">
              <.form_field field={f[:linehaul_cents]} label="Linehaul (cents)" type="number" min="0" />
              <.form_field field={f[:advances_cents]} label="Advances (cents)" type="number" min="0" />
              <.form_field field={f[:fuel_surcharge_cents]} label="Fuel surcharge (cents)" type="number" min="0" />
              <.form_field field={f[:accessorial_cents]} label="Accessorial (cents)" type="number" min="0" />
              <.form_field field={f[:claim_deduction_cents]} label="Claim deduction (cents)" type="number" min="0" />
              <.form_field field={f[:factoring_rate_bps]} label="Factoring rate (bps)" type="number" min="0" max="10000" />
              <.form_field field={f[:currency]} label="Currency" placeholder="USD" />
              <.form_field field={f[:status]} label="Status" type="select" options={settlement_status_options()} />
              <:actions>
                <.button variant="primary" type="submit" id="save-edit-settlement">Save settlement</.button>
                <.button type="button" phx-click="cancel_edit_settlement">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
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

  # T148 — the "New load" create-flow events (grouped with the other `handle_event/3` clauses;
  # the create logic lives in `create_load/2` below, extracted like `dispatch_decision/2`).
  def handle_event("new_load", _params, socket) do
    {:noreply,
     assign(socket,
       show_new: true,
       load_error: nil,
       new_load_form: to_form(%{"status" => "open"}, as: :load)
     )}
  end

  def handle_event("cancel_new_load", _params, socket) do
    {:noreply, assign(socket, show_new: false, load_error: nil)}
  end

  def handle_event("validate_load", %{"load" => params}, socket) do
    {:noreply, assign(socket, new_load_form: to_form(params, as: :load))}
  end

  def handle_event("save_load", %{"load" => params}, socket) do
    case create_load(socket.assigns.org_id, params) do
      {:ok, _load} ->
        socket =
          socket
          |> assign(show_new: false, new_load_form: nil, load_error: nil, panel: "loads")
          |> put_flash(:info, "Load created.")

        {:noreply, load_panel(socket, "loads", socket.assigns.org_id)}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           load_error: "Could not create the load — a load reference is required.",
           new_load_form: to_form(params, as: :load)
         )}
    end
  end

  # ==========================================================================
  # T158 — the REAL load-board filter events. `filter_loads` fires on every
  # `phx-change` of the filter form; `clear_load_filter` resets it. Both re-run
  # `load_panel/3`, so `Reads.load_board/2` is the ONLY place the filter logic
  # lives — the handler just carries the params through.
  # ==========================================================================
  def handle_event("filter_loads", params, socket) do
    filter = %{status: Map.get(params, "status", ""), q: Map.get(params, "q", "")}
    socket = assign(socket, load_filter: filter)
    {:noreply, load_panel(socket, "loads", socket.assigns.org_id)}
  end

  def handle_event("clear_load_filter", _params, socket) do
    socket = assign(socket, load_filter: %{status: nil, q: ""})
    {:noreply, load_panel(socket, "loads", socket.assigns.org_id)}
  end

  # ==========================================================================
  # T158 — load EDIT + DELETE events. Edit mirrors the create modal's manual-attrs
  # shape (see `update_load/3`); delete carries the `delete_confirm/1` client-side
  # interlock and rides the resource's default SOFT destroy (Opportunity is
  # `archivable: true`, ADR-040 §5.9) — `Ash.destroy/2`, never a raw DELETE.
  # ==========================================================================
  def handle_event("edit_load", %{"id" => id}, socket) do
    scope = broker_scope(socket.assigns.org_id)

    case fetch_load(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "load not found")}

      load ->
        {:noreply,
         assign(socket,
           show_edit_load: true,
           edit_load_id: load.id,
           edit_load_error: nil,
           edit_load_form: to_form(edit_load_params(load), as: :load)
         )}
    end
  end

  def handle_event("cancel_edit_load", _params, socket) do
    {:noreply, assign(socket, show_edit_load: false, edit_load_error: nil)}
  end

  def handle_event("validate_edit_load", %{"load" => params}, socket) do
    {:noreply, assign(socket, edit_load_form: to_form(params, as: :load))}
  end

  def handle_event("save_edit_load", %{"load" => params}, socket) do
    case update_load(socket.assigns.org_id, socket.assigns.edit_load_id, params) do
      {:ok, _load} ->
        socket =
          socket
          |> assign(show_edit_load: false, edit_load_id: nil, edit_load_form: nil, edit_load_error: nil)
          |> put_flash(:info, "Load updated.")

        {:noreply, load_panel(socket, "loads", socket.assigns.org_id)}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           edit_load_error: "Could not update the load — a load reference is required.",
           edit_load_form: to_form(params, as: :load)
         )}
    end
  end

  def handle_event("delete_load", %{"id" => id}, socket) do
    case delete_load(socket.assigns.org_id, id) do
      {:ok, _load} ->
        socket = socket |> assign(delete_load_error: nil) |> put_flash(:info, "Load deleted.")
        {:noreply, load_panel(socket, "loads", socket.assigns.org_id)}

      {:error, _reason} ->
        {:noreply, assign(socket, delete_load_error: "Could not delete this load.")}
    end
  end

  # ==========================================================================
  # T158 — driver create/edit events. A genuine `AshPhoenix.Form` over the
  # Driver resource's real `:create`/`:update` actions (mirrors the framework
  # CRM contact modal — `Samen.Web.CRM.ContactsLive`/`ContactLive`). `org_id`
  # is a SERVER-SIDE fact merged in before submit (`with_org/2`), never trusted
  # from client params — the same posture `ContactsLive.save_new/2` uses.
  # ==========================================================================
  def handle_event("new_driver", _params, socket) do
    scope = broker_scope(socket.assigns.org_id)
    {:noreply, assign(socket, show_new_driver: true, driver_error: nil, new_driver_form: new_driver_form(scope))}
  end

  def handle_event("cancel_new_driver", _params, socket) do
    {:noreply, assign(socket, show_new_driver: false, driver_error: nil)}
  end

  def handle_event("validate_new_driver", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_driver_form, with_org(params, socket))
    {:noreply, assign(socket, new_driver_form: form)}
  end

  def handle_event("save_new_driver", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_driver_form, params: with_org(params, socket)) do
      {:ok, _driver} ->
        socket =
          socket
          |> assign(show_new_driver: false, driver_error: nil)
          |> put_flash(:info, "Driver added.")

        {:noreply, load_panel(socket, "roster", socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_driver_form: form)}
    end
  end

  # The edit form is built over the PII-RESOLVED record (`Reads.get_driver/2` runs the
  # SAME `Samen.Api.PiiResolution` seam `driver_roster/1` uses) — on this console's
  # `broker_scope/1` (always plane: :tenant) that resolves `full_name`/`cdl_number` to
  # CLEAR. This LiveView never unwraps a `%Samen.Masked{}` or calls the vault directly.
  def handle_event("edit_driver", %{"driver" => driver_id}, socket) do
    scope = broker_scope(socket.assigns.org_id)

    case Reads.get_driver(scope, driver_id) do
      {:ok, driver} ->
        {:noreply,
         assign(socket,
           show_edit_driver: true,
           driver_error: nil,
           edit_driver_id: driver_id,
           edit_driver_form: edit_driver_form(driver, scope)
         )}

      :error ->
        {:noreply, put_flash(socket, :error, "driver not found")}
    end
  end

  def handle_event("cancel_edit_driver", _params, socket) do
    {:noreply, assign(socket, show_edit_driver: false, driver_error: nil)}
  end

  def handle_event("validate_edit_driver", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.edit_driver_form, params)
    {:noreply, assign(socket, edit_driver_form: form)}
  end

  # T158 — the FMCSA-guard-not-bypassable proof: this update touches ONLY the Driver
  # resource's own attributes (accept list from the resource's default `:update`
  # action). It has no path to DispatchEvent, no accepted attribute overrides the
  # gate's decision, and no accepted attribute can force a dispatch — the gate
  # (`Driftwood.Policy.FmcsaDispatchGate`) lives on a DIFFERENT resource's `:dispatch`
  # action and re-reads the driver row fresh (a bare repo query, not a cached read) at
  # dispatch time. Editing a driver can change what the gate will SEE next time it
  # runs — it can never skip the gate running. See
  # `test/driver_edit_no_fmcsa_bypass_test.exs` for the adversarial proof.
  def handle_event("save_edit_driver", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_driver_form, params: params) do
      {:ok, _driver} ->
        socket =
          socket
          |> assign(show_edit_driver: false, edit_driver_id: nil, driver_error: nil)
          |> put_flash(:info, "Driver updated.")

        {:noreply, load_panel(socket, "roster", socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_driver_form: form)}
    end
  end

  # ==========================================================================
  # T158 — settlement create/edit events. Same `AshPhoenix.Form` pattern as the
  # driver modal; Settlement's stored inputs are plain integer-cents attributes
  # (no composite type), so the form casts them directly.
  # ==========================================================================
  def handle_event("new_settlement", _params, socket) do
    scope = broker_scope(socket.assigns.org_id)
    {:noreply, assign(socket, show_new_settlement: true, settlement_error: nil, new_settlement_form: new_settlement_form(scope))}
  end

  def handle_event("cancel_new_settlement", _params, socket) do
    {:noreply, assign(socket, show_new_settlement: false, settlement_error: nil)}
  end

  def handle_event("validate_new_settlement", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_settlement_form, with_org(params, socket))
    {:noreply, assign(socket, new_settlement_form: form)}
  end

  def handle_event("save_new_settlement", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_settlement_form, params: with_org(params, socket)) do
      {:ok, _settlement} ->
        socket =
          socket
          |> assign(show_new_settlement: false, settlement_error: nil)
          |> put_flash(:info, "Settlement added.")

        {:noreply, load_panel(socket, "settlements", socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_settlement_form: form)}
    end
  end

  def handle_event("edit_settlement", %{"settlement" => settlement_id}, socket) do
    scope = broker_scope(socket.assigns.org_id)

    case Reads.get_settlement(scope, settlement_id) do
      {:ok, settlement} ->
        {:noreply,
         assign(socket,
           show_edit_settlement: true,
           settlement_error: nil,
           edit_settlement_id: settlement_id,
           edit_settlement_form: edit_settlement_form(settlement, scope)
         )}

      :error ->
        {:noreply, put_flash(socket, :error, "settlement not found")}
    end
  end

  def handle_event("cancel_edit_settlement", _params, socket) do
    {:noreply, assign(socket, show_edit_settlement: false, settlement_error: nil)}
  end

  def handle_event("validate_edit_settlement", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.edit_settlement_form, params)
    {:noreply, assign(socket, edit_settlement_form: form)}
  end

  def handle_event("save_edit_settlement", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_settlement_form, params: params) do
      {:ok, _settlement} ->
        socket =
          socket
          |> assign(show_edit_settlement: false, edit_settlement_id: nil, settlement_error: nil)
          |> put_flash(:info, "Settlement updated.")

        {:noreply, load_panel(socket, "settlements", socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_settlement_form: form)}
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

  # ==========================================================================
  # T148 — the minimal-but-real "New load" create flow.
  #
  # A load IS a `Driftwood.Crm.Opportunity` (the freight `Load` alias — see
  # `Driftwood.Reads.load_board/1`), so "post a load" is a governed create through the
  # resource's REAL `:create` action, over the same tenant `broker_scope/1` every read uses
  # (OrgScope-confined; `RoleAtLeast :member` satisfied). This mirrors the framework CRM
  # `/crm/contacts` create pattern (modal → form → real Ash action → reload → surfaced error);
  # the create call is the SAME one `Driftwood.Seeds` uses, so the money value is built via the
  # ADR-036 `Samen.Type.Money.from_cents/2` helper rather than casting a bare form string.
  # Fuller CRUD (edit/delete loads, and create/edit for drivers + settlements) is deliberately a
  # follow-up — this lands ONE real create so the new-tenant journey has a first write.
  # ==========================================================================

  @doc """
  Create ONE load (a `Driftwood.Crm.Opportunity`) for `org_id` from the raw form params via the
  resource's real `:create` action on the tenant broker scope. Extracted (like
  `dispatch_decision/2`) so the create path is exercised WITHOUT a live socket. Returns
  `{:ok, opportunity}` or `{:error, changeset}` (e.g. a missing required `name`).
  """
  @spec create_load(binary(), map()) :: {:ok, struct()} | {:error, term()}
  def create_load(org_id, raw_params) do
    scope = broker_scope(org_id)
    attrs = load_attrs(raw_params, org_id)
    # Tier-1 custom-bag governance (T3.8): a `custom` bag key is REJECTED at write unless a
    # `tnt_field` definition exists for it. `Driftwood.Seeds.define_custom_fields/1` registers
    # "lane" for seeded orgs; ensure it (idempotently) here so a FRESH org's first load persists
    # its lane too — the exact `Samen.CustomFields.define_field/2` call the seeds use.
    :ok = maybe_define_lane_field(org_id, attrs)

    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  # ==========================================================================
  # T158 — the load EDIT + DELETE writes, mirroring `create_load/2`'s manual-attrs
  # shape (Money composite, same constraint) and CRM `Reads.delete_record/4`'s
  # fetch-then-destroy shape (org-scoped fetch — a not-found id, including a
  # cross-org id invisible under OrgScope, is a genuine `{:error, :not_found}`,
  # never a silent no-op success).
  # ==========================================================================

  @doc """
  Update ONE load's editable fields (name/lane/rate/status) via the resource's real
  `:update` action on the tenant broker scope. `{:ok, opportunity}` or
  `{:error, changeset | :not_found}`.
  """
  @spec update_load(binary(), binary(), map()) :: {:ok, struct()} | {:error, term()}
  def update_load(org_id, load_id, raw_params) do
    scope = broker_scope(org_id)
    attrs = load_attrs(raw_params, org_id)
    :ok = maybe_define_lane_field(org_id, attrs)

    case fetch_load(scope, load_id) do
      nil ->
        {:error, :not_found}

      load ->
        load
        |> Ash.Changeset.for_update(:update, attrs, scope: scope)
        |> Ash.update(scope: scope)
    end
  end

  @doc """
  Delete (SOFT — `Driftwood.Crm.Opportunity` is `archivable: true`, ADR-040 §5.9) ONE
  load for `org_id`. `{:ok, opportunity}` or `{:error, :not_found | term()}`. The
  fetch is org-scoped, so an id from another org is genuinely `:not_found` (OrgScope
  makes it not-exist for this actor) — never a cross-org destroy.
  """
  @spec delete_load(binary(), binary()) :: {:ok, struct()} | {:error, term()}
  def delete_load(org_id, load_id) do
    scope = broker_scope(org_id)

    case fetch_load(scope, load_id) do
      nil -> {:error, :not_found}
      load -> Ash.destroy(load, scope: scope, return_destroyed?: true)
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_load(scope, load_id) do
    Driftwood.Crm.Opportunity
    |> Ash.Query.filter(id == ^load_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
  rescue
    _ -> nil
  end

  # The edit form's initial values — the inverse of `load_attrs/2` (dollars string,
  # lane pulled from the Tier-1 custom bag, status as a plain string the `<select>`
  # option values match).
  defp edit_load_params(load) do
    %{
      "name" => load.name,
      "lane" => (if load.__lane__ in [nil, "unknown"], do: "", else: load.__lane__),
      "rate" => cents_to_dollars_string(Samen.Type.Money.cents(load.value)),
      "status" => to_string(load.status)
    }
  end

  defp cents_to_dollars_string(cents) when is_integer(cents),
    do: :erlang.float_to_binary(cents / 100, decimals: 2)

  defp cents_to_dollars_string(_), do: "0.00"

  # ==========================================================================
  # T158 — driver + settlement `AshPhoenix.Form` builders (mirrors
  # `Samen.Web.CRM.ContactsLive.new_contact_form/2` / `ContactLive.edit_form/2`).
  # ==========================================================================

  defp new_driver_form(scope) do
    Driftwood.Freight.Driver
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp edit_driver_form(driver, scope) do
    driver
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  defp new_settlement_form(scope) do
    Driftwood.Freight.Settlement
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp edit_settlement_form(settlement, scope) do
    settlement
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  # `org_id` is a SERVER-SIDE fact (the socket's own scope), never accepted from raw
  # client params — mirrors `Samen.Web.CRM.ContactsLive.with_org/2` exactly.
  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  # -- filter helpers (T158 load-board filter) --------------------------------

  defp filter_value(filter, key), do: Map.get(filter, key) || Map.get(filter, to_string(key))

  defp load_filter_active?(filter) do
    filter_value(filter, :status) not in [nil, ""] or
      (filter_value(filter, :q) || "") |> to_string() |> String.trim() != ""
  end

  # -- option lists -------------------------------------------------------------

  defp eld_provider_options do
    [{"Samsara", "samsara"}, {"Motive", "motive"}, {"Geotab", "geotab"}, {"Other", "other"}]
  end

  defp driver_status_options do
    [
      {"Available", "available"},
      {"On load", "on_load"},
      {"Out of service", "out_of_service"},
      {"Terminated", "terminated"}
    ]
  end

  defp settlement_status_options do
    [{"Draft", "draft"}, {"Approved", "approved"}, {"Paid", "paid"}]
  end

  defp maybe_define_lane_field(org_id, %{custom: %{"lane" => _}}) do
    {:ok, _} =
      Samen.CustomFields.define_field(
        %{org_id: org_id, table_name: "fop_opportunity", field_name: "lane", type: :string},
        Driftwood.Repo
      )

    :ok
  end

  defp maybe_define_lane_field(_org_id, _attrs), do: :ok

  # Shape the raw form params into the `:create` action's attributes: the load reference `name`,
  # the `value` Money (from a dollars string), the `status` enum, and the freight `lane` on the
  # Tier-1 custom bag (where `load_board/1` reads it).
  defp load_attrs(raw, org_id) do
    lane = raw |> Map.get("lane", "") |> to_string() |> String.trim()
    cents = raw |> Map.get("rate", "") |> dollars_to_cents()

    %{
      org_id: org_id,
      name: raw |> Map.get("name", "") |> to_string() |> String.trim(),
      value: Samen.Type.Money.from_cents(cents, :USD),
      status: normalize_status(Map.get(raw, "status"))
    }
    |> maybe_put_lane(lane)
  end

  defp maybe_put_lane(attrs, ""), do: attrs
  defp maybe_put_lane(attrs, lane), do: Map.put(attrs, :custom, %{"lane" => lane})

  defp normalize_status(s) when s in ["open", "won", "lost", "on_hold"],
    do: String.to_existing_atom(s)

  defp normalize_status(_), do: :open

  defp dollars_to_cents(value) do
    case value |> to_string() |> String.trim() |> Float.parse() do
      {dollars, _rest} -> round(dollars * 100)
      :error -> 0
    end
  end

  defp load_status_options do
    [{"Open", "open"}, {"Won", "won"}, {"Lost", "lost"}, {"On hold", "on_hold"}]
  end

  defp search_href(nil), do: "/search"
  defp search_href(org_id), do: "/search?org=#{org_id}"
end
