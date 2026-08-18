defmodule Samen.Web.Operator.FleetDetailLive do
  @moduledoc """
  The WS-J fleet cockpit's TIER-2 surface (`/operator/fleet/:app_id`, ADR-044
  §5.3/§5.4/§16, T84b) — the merged T156 per-tenant cohort rows
  (deliverability/automation/activity), each keyed by an opaque `fleet_handle`
  and, per Amendment 1, a MASKED-BY-DEFAULT tenant display name resolved
  per-viewer.

  ## Gating (§5.4 tier 2)

  `roles[:fleet] != nil` **and** `roles[app_id] != nil` for THIS row —
  `Samen.Web.Operator.Fleet.gate/2` + `app_role/2`. No role in FLEET at all ⇒
  redirect (RP-J-5, same as `FleetLive`). A role in fleet but NOT in this
  specific product ⇒ this page renders "not in your product scope" — the
  ROW-counts are still gated per-app even though the container page rendered.

  ## Name resolution — the amendment's core obligation (§16.2/§16.3, RP-J-14)

  A row's *counts* are gated by `roles[app_id]` (above); that SAME row's tenant
  NAME is additionally gated by `handle ∈ scope_of(principal, app_id)`
  (`Samen.Fleet.Resolution.resolve/3`, T84a's `scope_of/2` under the hood via
  the host's `:fleet_name_resolver` seam). **Mask by omission**: the resolver
  returns `%{handle => name}` containing ONLY resolvable handles; every OTHER
  handle in the cohort renders with **no name, no `org_id`, no deep link, and
  no handle in any DOM attribute** (§16.4a) — the `masked?` branch below never
  emits a `data-*`/`href` carrying the raw handle.

  This is what makes the `Samen.ScopeMaskCase` 3-proof (green/red/sabotage) +
  the mixed-render case (named + masked rows, ONE table, ONE viewer — "the
  salesperson case") assertable directly against this LiveView's rendered HTML.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live, only: [assign_mount: 2, operator_sidebar: 1]

  alias Samen.Fleet.{Handle, Resolution}
  alias Samen.Web.Operator.Fleet, as: FleetHelpers

  @cohort_families [
    {"deliverability", :deliverability, "/operator/deliverability/resolve"},
    {"automation", :automation, "/operator/automation/resolve"},
    {"activity", :activity, "/operator/activity/resolve"}
  ]

  @impl true
  def mount(%{"app_id" => app_id}, session, socket) do
    socket = assign_mount(socket, session)

    case FleetHelpers.gate(socket.assigns[:samen_mount], session) do
      {:ok, ctx} ->
        {:ok, socket |> assign(fleet_ctx: ctx, app_id: app_id) |> load()}

      :denied ->
        {:ok, redirect(socket, to: FleetHelpers.login_path(socket.assigns[:samen_mount]))}
    end
  end

  @doc false
  def load(socket) do
    %{otp_app: otp_app, namespace: namespace, roles: roles, principal_id: principal_id} = socket.assigns.fleet_ctx
    app_id = socket.assigns.app_id

    case Samen.Fleet.read(otp_app, namespace: namespace) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &(&1.app_id == app_id)) do
          nil ->
            assign(socket,
              app: nil,
              in_product_scope?: false,
              cohorts: %{},
              resolved: %{},
              name_seam_reachable?: false
            )

          row ->
            in_scope? = FleetHelpers.app_role(roles, row.slug) != nil
            report = row.report || %{}

            all_handles =
              @cohort_families
              |> Enum.flat_map(fn {key, _kind, _resolve} -> Map.get(report, key) || [] end)
              |> Enum.filter(&is_map/1)
              |> Enum.map(& &1["handle"])
              |> Enum.filter(&is_binary/1)
              |> Enum.uniq()

            resolved = if in_scope?, do: Resolution.resolve(otp_app, principal_id, all_handles), else: %{}

            cohorts =
              for {key, kind, resolve_path} <- @cohort_families, into: %{} do
                {kind, cohort_rows(report, key, kind, row.slug, resolve_path, resolved, in_scope?)}
              end

            assign(socket,
              app: row,
              in_product_scope?: in_scope?,
              cohorts: cohorts,
              resolved: resolved,
              # P16 (phase6-punchlist / ADR-044 §16.2) — is the NAME-resolution seam
              # even wired in THIS deployment? A separately-deployed / cross-origin
              # cockpit with no `:fleet_name_resolver` masks every name; that is a
              # whole-page "seam not reachable" condition, NOT per-row out-of-scope.
              name_seam_reachable?: Resolution.name_resolver_configured?(otp_app)
            )
        end

      {:error, reason} ->
        assign(socket,
          app: nil,
          not_configured: reason,
          in_product_scope?: false,
          cohorts: %{},
          resolved: %{},
          name_seam_reachable?: false
        )
    end
  end

  defp cohort_rows(report, key, _kind, _slug, resolve_path, resolved, in_scope?) do
    (Map.get(report, key) || [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      handle = item["handle"]
      name = in_scope? && is_binary(handle) && Map.get(resolved, handle)

      %{
        handle: handle,
        masked?: !name,
        name: name,
        resolve_href: name && Handle.well_formed?(handle) && "#{resolve_path}?fleet_handle=#{handle}",
        item: item
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fleet-detail">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:fleet} />
        </:sidebar>

        <.topbar title="Fleet" crumbs={["Operator plane", "Fleet", @app_id]} />

        <div :if={assigns[:not_configured]} class="wrap">
          <.empty_state class="fleet-not-configured" icon="⛴" title="Fleet not configured." body={inspect(@not_configured)} />
        </div>

        <div :if={!assigns[:not_configured] and @app == nil} class="wrap">
          <.empty_state class="fleet-unknown-app" icon="?" title="Unknown app." body="This product is not registered in the fleet, or was deregistered." />
        </div>

        <div :if={@app != nil and !@in_product_scope?} class="wrap">
          <.empty_state
            class="fleet-out-of-product-scope"
            icon="🔒"
            title="Not in your product scope."
            body="You hold a fleet role but no role in this specific product — this row's counts are hidden."
          />
        </div>

        <div :if={@app != nil and @in_product_scope?} class="wrap">
          <div class="gtitle" id="fleet-detail-header">
            <h3>{@app.display_name || @app.slug}</h3>
            <span class="lane">· {@app.slug} · {@app.mode} · {@app.status}</span>
          </div>

          <%!-- P16 (ADR-044 §16.2) — whole-page attribution when the NAME-resolution
                seam is not wired in this (separately-deployed) cockpit: names are
                withheld for a reason unrelated to per-viewer scope. Counts still show. --%>
          <.empty_state
            :if={not @name_seam_reachable?}
            class="fleet-name-seam-unreachable"
            icon="⚠"
            title="Names unavailable — resolution seam not reachable."
            body="This cockpit deployment has no fleet name-resolution seam wired for this product (a separately-deployed / cross-origin composition). Tenant names cannot be resolved here — cohort counts remain visible, names are withheld fail-closed."
          />

          <div :for={{kind, rows} <- @cohorts} id={"cohort-#{kind}"} style="margin-top:18px">
            <div class="gtitle">
              <h3>{Phoenix.Naming.humanize(kind)}</h3>
              <span class="n">{length(rows)}</span>
              <span class="lane">· k-anon floored at source · names resolved per-viewer scope</span>
            </div>

            <.empty_state
              :if={rows == []}
              class={"cohort-#{kind}-empty"}
              icon="⊘"
              title="No cohort data reported."
              body="This product has not opted into tier-2 cohort reporting for this section."
            />

            <table :if={rows != []} class="tbl" id={"cohort-#{kind}-table"}>
              <thead>
                <tr>
                  <th scope="col">Tenant</th>
                  <th scope="col">Metrics</th>
                </tr>
              </thead>
              <tbody>
                <%= for {row, idx} <- Enum.with_index(rows) do %>
                  <%= if row.masked? do %>
                    <tr id={"cohort-#{kind}-row-#{idx}-masked"} class="cohort-row cohort-row-masked">
                      <td class="cohort-name-masked">
                        <span class="masked-affordance">{if @name_seam_reachable?, do: "not in your scope", else: "name unavailable"}</span>
                      </td>
                      <td>{cohort_metrics_text(row.item)}</td>
                    </tr>
                  <% else %>
                    <tr id={"cohort-#{kind}-row-#{idx}-named"} class="cohort-row cohort-row-named">
                      <td class="cohort-name">
                        <.link :if={row.resolve_href} navigate={row.resolve_href} class="cohort-name-link">
                          {row.name}
                        </.link>
                        <span :if={!row.resolve_href}>{row.name}</span>
                      </td>
                      <td>{cohort_metrics_text(row.item)}</td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </.app_shell>
    </div>
    """
  end

  defp cohort_metrics_text(item) when is_map(item) do
    item
    |> Map.drop(["handle"])
    |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{suppressed_or(v)}" end)
  end

  defp suppressed_or(%{"suppressed" => true}), do: "⊘"
  defp suppressed_or(v), do: to_string(v)
end
