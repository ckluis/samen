defmodule Samen.Web.Operator.RevenueLive do
  @moduledoc """
  Framework OPERATOR / Revenue page (WS-B / B3, design §1.4 + §1.6) — the G7 revenue
  surface every vertical inherits at 0 LOC via `samen_operator_routes/2`:

    * **MRR movement waterfall per period** + **NRR / churn tiles** + **cohort
      retention grid** — the operator org's OWN book (tenant-book drill-down, PII-free
      numbers, NO floor per the B2 gate analysis), read through the bounded
      `Samen.Web.Operator.RevenueReads`, which WRAPS the `Samen.Revenue.Metrics`
      kernel fold over the `mrr_revenue_rollup` raw table (never a live movement scan
      — AC-G7-6).

    * **Cross-tenant MRR by plan** (AC-G7-9) — the token-blind `operator_aggregate`
      path UNDER the k-anon floor. Host-agnostic like `AggregateLive`: the host wires
      `revenue_plan_loader: {Mod, :fun, []}` on the mount labels (e.g. the demo's
      `Demo.OperatorDashboard.revenue_plan_cohorts/0`, which reads through
      `Samen.Aggregate.read_all/2` — floors enforced at the chokepoint). A cohort
      below the floor ARRIVES as `%Samen.Aggregate.Suppressed{}` and renders `⊘`;
      the framework never un-suppresses, and never offers a bypass affordance.

  ## Masking / PII posture

  Every rendered value is a bounded date / enum / count / cent amount — the revenue
  surface is not a PII surface (AC-G7-3: the `mov`/`mrr` columns carry no name, email,
  or freeform string). No `Samen.Vault` call, no `%Masked{}` branch, no reveal path.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Web.Operator.RevenueReads

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]

    case mount && Operator.org_id(mount) do
      nil ->
        assign(socket,
          no_org: true,
          revenue: RevenueReads.empty(),
          plan_cohorts: [],
          plan_suppressed: 0
        )

      _org_id ->
        scope = Operator.scope(mount)
        plan_cohorts = plan_cohorts(mount)

        assign(socket,
          no_org: false,
          revenue: RevenueReads.revenue(mount, scope),
          plan_cohorts: plan_cohorts,
          plan_suppressed: Enum.count(plan_cohorts, &suppressed_cohort?/1)
        )
    end
  end

  # The host's cross-tenant MRR-by-plan loader (mount label `revenue_plan_loader`,
  # the `aggregate_loader:` pattern). The loader reads through the token-blind
  # `Samen.Aggregate.read_all/2` chokepoint, so the k-anon/l-div floors + query
  # budget have ALREADY run — a below-floor cohort arrives `%Suppressed{}` and is
  # passed through untouched. Absent a loader the section renders an empty state.
  defp plan_cohorts(%Mount{} = mount) do
    case Mount.label(mount, :revenue_plan_loader, nil) do
      {mod, fun, args} ->
        try do
          apply(mod, fun, args) || []
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end

  defp suppressed_cohort?(row) do
    Samen.Aggregate.Suppressed.suppressed?(Map.get(row, :mrr_cents)) or
      Samen.Aggregate.Suppressed.suppressed?(Map.get(row, :tenant_count))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-revenue">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:revenue} />
        </:sidebar>

        <.topbar title="Revenue" crumbs={["Operator plane", "Revenue"]} />

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved.
            </div>
          </div>
        <% else %>
          <div class="metrics">
            <.metric label="MRR" value={dollars(closing_cents(@revenue.latest))} sub="latest period closing">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="NRR" value={pct(@revenue.latest && @revenue.latest.nrr)} sub="net revenue retention">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M3 17l6-6 4 4 8-8" /><path d="M14 7h7v7" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Gross churn" value={pct(@revenue.latest && @revenue.latest.gross_churn)} sub="of opening MRR lost">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M3 7l6 6 4-4 8 8" /><path d="M14 17h7v-7" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Logo churn" value={pct(@revenue.latest && @revenue.latest.logo_churn)} sub="customers lost">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="9" cy="8" r="4" /><path d="M2 21v-2a6 6 0 0 1 9-5" /><path d="m16 16 5 5m0-5-5 5" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="mrr-waterfall">
              <div class="gtitle">
                <h3>MRR movement waterfall</h3>
                <span class="n">{length(@revenue.periods)}</span>
                <span class="lane">· opening + new + expansion − contraction − churn + reactivation = closing · reads the rollup, never a live scan</span>
              </div>
              <.empty_state
                :if={@revenue.periods == []}
                class="revenue-empty"
                icon="≋"
                title="No revenue movements yet."
                body="Subscription movements (new, expansion, contraction, churn, reactivation) roll up here per period once the ledger has rows."
              />
              <.data_table :if={@revenue.periods != []}>
                <:head>
                  <th>Period</th>
                  <th>Opening</th>
                  <th>New</th>
                  <th>Expansion</th>
                  <th>Contraction</th>
                  <th>Churn</th>
                  <th>Reactivation</th>
                  <th>Net</th>
                  <th>Closing</th>
                </:head>
                <tr :for={p <- @revenue.periods} class="waterfall-row" id={"waterfall-#{p.month}"}>
                  <td class="w-period" style="font-weight:500;color:#3a3b45">{period_label(p.month)}</td>
                  <td class="w-opening" style="color:var(--muted)">{dollars(p.display.opening_cents)}</td>
                  <td class="w-new">{dollars(p.display.new_cents)}</td>
                  <td class="w-expansion">{dollars(p.display.expansion_cents)}</td>
                  <td class="w-contraction" style="color:#B54708">−{dollars(p.display.contraction_magnitude_cents)}</td>
                  <td class="w-churn" style="color:#B42318">−{dollars(p.display.churn_magnitude_cents)}</td>
                  <td class="w-reactivation">{dollars(p.display.reactivation_cents)}</td>
                  <td class="w-net" style="font-weight:500">{signed_dollars(p.display.net_change_cents)}</td>
                  <td class="w-closing" style="font-weight:500;color:#3a3b45">{dollars(p.display.closing_cents)}</td>
                </tr>
              </.data_table>
            </div>

            <div id="cohort-retention" style="margin-top:18px">
              <div class="gtitle">
                <h3>Cohort retention</h3>
                <span class="n">{length(@revenue.cohorts.cohorts)}</span>
                <span class="lane">· customers by signup month · retained % from each customer's own movement timeline</span>
              </div>
              <.empty_state
                :if={@revenue.cohorts.cohorts == []}
                class="cohorts-empty"
                icon="▦"
                title="No cohorts yet."
                body="Each signup month becomes a cohort once customers have a :new movement on the ledger."
              />
              <.data_table :if={@revenue.cohorts.cohorts != []}>
                <:head>
                  <th>Cohort</th>
                  <th>Size</th>
                  <th :for={offset <- 0..@revenue.cohorts.max_offset}>M{offset}</th>
                </:head>
                <tr :for={c <- @revenue.cohorts.cohorts} class="cohort-row" id={"cohort-#{c.cohort_month}"}>
                  <td class="c-month" style="font-weight:500;color:#3a3b45">{period_label(c.cohort_month)}</td>
                  <td class="c-size" style="color:var(--muted)">{c.size}</td>
                  <td :for={offset <- 0..@revenue.cohorts.max_offset} class="c-cell">
                    {retention_cell(c, offset)}
                  </td>
                </tr>
              </.data_table>
            </div>

            <div id="plan-mrr" style="margin-top:18px">
              <div class="gtitle">
                <h3>MRR by plan · cross-tenant</h3>
                <span class="n">{length(@plan_cohorts)}</span>
                <span class="lane">· token-blind aggregate path · k-anon suppressed below the floor</span>
              </div>

              <.token_blind_bar chip="no reveal path · k-anon suppressed">
                <b>Token-blind aggregate section.</b>
                Cross-tenant plan cohorts read ONLY through the <span class="mono">operator_aggregate</span>
                actor — no pii_ column reachable by construction. A plan cohort below the
                k-anonymity floor is suppressed (<span class="mono">⊘</span>); the framework never
                un-suppresses.
              </.token_blind_bar>

              <.empty_state
                :if={@plan_cohorts == []}
                class="plan-mrr-empty"
                icon="⊘"
                title="No cross-tenant plan projection wired."
                body="A host supplies its floored MRR-by-plan cohorts via revenue_plan_loader: on the mount labels (read through Samen.Aggregate.read_all/2 — the k-anon floor runs at the chokepoint)."
              />
              <.data_table :if={@plan_cohorts != []}>
                <:head>
                  <th style="width:40%">Plan</th>
                  <th style="width:30%">Tenants</th>
                  <th style="width:30%">MRR</th>
                </:head>
                <tr :for={row <- @plan_cohorts} class="plan-row" id={"plan-#{row.plan}"}>
                  <td class="p-plan" style="font-weight:500;color:#3a3b45">{row.plan}</td>
                  <td class="p-tenants">{cell(row.tenant_count)}</td>
                  <td class="p-mrr">{money_cell(row.mrr_cents)}</td>
                </tr>
                <tr :if={@plan_suppressed > 0}>
                  <td colspan="3">
                    <div class="supp">
                      <svg class="lk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
                      {@plan_suppressed} plan cohorts below the k-anonymity floor — suppressed to prevent re-identification.
                    </div>
                  </td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp closing_cents(nil), do: 0
  defp closing_cents(%{waterfall: %{closing_cents: cents}}), do: cents

  defp period_label(%Date{} = d), do: Calendar.strftime(d, "%Y-%m")
  defp period_label(other), do: to_string(other)

  defp pct(nil), do: "—"
  defp pct(ratio) when is_float(ratio), do: "#{Float.round(ratio * 100, 1)}%"
  defp pct(_), do: "—"

  defp signed_dollars(cents) when is_integer(cents) and cents < 0, do: "−#{dollars(-cents)}"
  defp signed_dollars(cents), do: dollars(cents)

  defp retention_cell(cohort, offset) do
    case Enum.find(cohort.retention, &(&1.month_offset == offset)) do
      nil -> "—"
      %{rate: rate} -> pct(rate)
    end
  end

  # Token-blind cell rendering — a %Suppressed{} (or nil) renders ⊘, NEVER the value.
  defp cell(%Samen.Aggregate.Suppressed{}), do: "⊘"
  defp cell(nil), do: "⊘"
  defp cell(n) when is_integer(n), do: Integer.to_string(n)
  defp cell(other), do: to_string(other)

  defp money_cell(%Samen.Aggregate.Suppressed{}), do: "⊘"
  defp money_cell(nil), do: "⊘"
  defp money_cell(cents) when is_integer(cents), do: dollars(cents)
  defp money_cell(other), do: to_string(other)
end
