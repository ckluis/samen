defmodule Samen.Web.Operator.AggregateLive do
  @moduledoc """
  Framework OPERATOR aggregate plane — the token-blind cross-tenant dashboard (ADR-009 §5.3
  clause 2; promoted from driftwood-local `OperatorDashboardLive`).

  This is the second operator data-context: the SaaS company reads MRR / volume OVER its
  tenant orgs with NO PII by construction — the aggregate domain has no `pii_` column to
  mask, and cohorts below the k-anonymity floor are suppressed (`⊘`). It is the
  mutually-exclusive path from masked impersonation (§5.3 clause 1): an operator either opens
  ONE tenant masked (PII ••••) OR reads this cross-tenant aggregate (no subject at all).

  ## Host-agnostic aggregate loader

  The aggregate PROJECTIONS are vertical-shaped (freight lanes vs vet species), so — unlike
  CRM/Billing/Support — the framework cannot derive a canonical projection resource by name.
  Instead the host supplies its aggregate data through a `loader` MFA threaded on the mount
  labels (`aggregate_loader: {Mod, :fun, []}` returning `%{metrics: [...], groups: [...]}`),
  or passes the aggregate assigns directly. The framework owns the token-blind CHROME (the
  banner, the suppression row, the `⊘` cell rendering) — the reusable part — while the host
  owns which projection it reads. This keeps the two-plane thesis (one operator surface,
  token-blind) framework-level without hardcoding a vertical's projection shape.

  A `%Samen.Aggregate.Suppressed{}` (or `nil`) cell renders `⊘`; the framework never
  un-suppresses.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]

  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    data = load_aggregate(socket.assigns[:samen_mount])

    assign(socket,
      title: title(socket.assigns[:samen_mount]),
      metrics: Map.get(data, :metrics, []),
      groups: Map.get(data, :groups, []),
      suppressed_count: Map.get(data, :suppressed_count, 0)
    )
  end

  # Resolve the host aggregate data. A host wires `aggregate_loader: {M, F, A}` on the mount
  # labels; the loader returns the token-blind projection. Absent a loader (e.g. the stub /
  # a bare mount) the surface renders empty but structurally correct — proving the plane.
  defp load_aggregate(%Mount{} = mount) do
    case Mount.label(mount, :aggregate_loader, nil) do
      {mod, fun, args} ->
        try do
          apply(mod, fun, args) || %{}
        rescue
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp load_aggregate(_), do: %{}

  defp title(%Mount{} = mount), do: Mount.label(mount, :operator_title, "Portfolio")
  defp title(_), do: "Portfolio"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-aggregate">
      <.app_shell>
        <:sidebar>
          <.sidebar title={sidebar_title(@samen_mount)} subtitle="Operator control plane">
            <:search>
              <div class="search">
                <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
                </svg>
                Search tenants…
                <span class="kbd">⌘K</span>
              </div>
            </:search>

            <.nav_group label="Operator plane">
              <.nav_item label="Aggregate · portfolio" href="#" active>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9m6 10V5m6 14v-7" /></svg>
                </:icon>
              </.nav_item>
            </.nav_group>

            <:footer>
              <div class="foot">
                <div class="av">OP</div>
                <div class="m"><b>Operator</b><span>admin role</span></div>
              </div>
            </:footer>
          </.sidebar>
        </:sidebar>

        <.topbar title={@title} crumbs={["Operator plane", "Aggregate", @title]} />

        <.token_blind_bar chip="no reveal path · k-anon suppressed">
          <b>Token-blind aggregate plane.</b>
          This actor has <b>no pii_ column</b> in its domain by construction — it reads a
          vault-excluded projection over tenant orgs. Cohorts below the k-anonymity floor
          are suppressed (<span class="mono">⊘</span>).
        </.token_blind_bar>

        <div :if={@metrics != []} class="metrics">
          <.metric :for={m <- @metrics} label={m.label} value={cell(m.value)} sub={Map.get(m, :sub)} />
        </div>

        <div class="wrap">
          <div :for={group <- @groups} id={"agg-#{group.id}"}>
            <div class="gtitle">
              <h3>{group.title}</h3><span class="n">{length(group.rows)}</span>
              <span class="lane">· org-level aggregates only — no personal data</span>
            </div>
            <.data_table>
              <:head>
                <th :for={col <- group.columns}>{col}</th>
              </:head>
              <tr :for={row <- group.rows} class="agg-row">
                <td :for={val <- row} class="agg-cell">{cell(val)}</td>
              </tr>
              <tr :if={@suppressed_count > 0}>
                <td colspan={length(group.columns)}>
                  <div class="supp">
                    <svg class="lk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
                    {@suppressed_count} cohorts below the k-anonymity floor — suppressed to prevent re-identification.
                  </div>
                </td>
              </tr>
            </.data_table>
          </div>

          <div :if={@groups == []} class="card" style="padding:22px 20px;color:var(--muted)">
            No aggregate projection wired. A host supplies its token-blind projection via
            <code>aggregate_loader:</code> on the mount labels; the framework owns the
            token-blind chrome (banner + <span class="mono">⊘</span> suppression).
          </div>
        </div>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp sidebar_title(%Mount{} = mount), do: Mount.label(mount, :operator_workspace, "Operator")
  defp sidebar_title(_), do: "Operator"

  # Token-blind cell rendering: a suppressed cohort or nil renders ⊘; the framework never
  # un-suppresses. Money is rendered as dollars when tagged `{:money, cents}`.
  defp cell(%Samen.Aggregate.Suppressed{}), do: "⊘"
  defp cell(nil), do: "⊘"
  defp cell({:money, cents}) when is_integer(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp cell(n) when is_integer(n), do: Integer.to_string(n)
  defp cell(other), do: to_string(other)
end
