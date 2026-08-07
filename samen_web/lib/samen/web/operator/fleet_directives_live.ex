defmodule Samen.Web.Operator.FleetDirectivesLive do
  @moduledoc """
  J4 — the fleet flag/announcement PUBLISH surface (`/operator/fleet/directives`,
  ADR-044 §7, T84b). Publishing (`roles[:fleet] == :operator_admin`) writes a
  `flt_directive` row via `Samen.Fleet.Registry.record_directive/3` (§4.1
  storage — T82) under a `Samen.Fleet.AdminActor` (this LiveView is the
  ALREADY-AUTHORIZED caller `AdminActor`'s moduledoc names). Every push is
  audited per-app with the publishing identity (P10, T84a).

  ## Drift disclosure (§7.4) — never a fake "applied"

  Per product tile: `applied` (its reported `applied_fleet_revision` matches the
  current published `fleet_revision`), `pending (published N, applied M)`, or
  `unreachable` (§7.5 — a stale/unreachable row NEVER shows `applied`).

  ## Precedence (§7.3, RP-J-8b — `Samen.Fleet.Directive.Precedence`)

  This page PUBLISHES a directive; whether a given product's local flag ends up
  ON is decided at the PRODUCT, by `Samen.Fleet.Directive.Precedence.decide/3`
  (or the `merge_config/2` write helper a host's `:fleet_directive_applier`
  wires) — the one-way OFF authority: any local off-state beats fleet, always.
  This cockpit page cannot see (and does not claim) each product's local flag
  state — it renders ONLY what it can honestly know: publish + ack/drift.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live, only: [assign_mount: 2, operator_sidebar: 1]

  alias Samen.Fleet.{AdminActor, Registry}
  alias Samen.Web.Operator.Fleet, as: FleetHelpers

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)

    case FleetHelpers.gate(socket.assigns[:samen_mount], session) do
      {:ok, ctx} ->
        {:ok, socket |> assign(fleet_ctx: ctx, publish_error: nil) |> load()}

      :denied ->
        {:ok, redirect(socket, to: FleetHelpers.login_path(socket.assigns[:samen_mount]))}
    end
  end

  @doc false
  def load(socket) do
    %{otp_app: otp_app, namespace: namespace} = socket.assigns.fleet_ctx

    with {:ok, %{rows: rows}} <- Samen.Fleet.read(otp_app, namespace: namespace),
         {:ok, directives} <-
           (namespace && Registry.list_directives(namespace, Samen.Aggregate.Actor.new())) || {:ok, []} do
      current_rev = case directives do
        [%{fleet_revision: rev} | _] -> rev
        _ -> 0
      end

      assign(socket,
        directives: directives,
        current_revision: current_rev,
        drift: Enum.map(rows, &drift_for(&1, current_rev))
      )
    else
      _ -> assign(socket, directives: [], current_revision: 0, drift: [])
    end
  end

  defp drift_for(row, current_revision) do
    applied = get_in(row.report || %{}, ["applied_fleet_revision"]) || 0

    status =
      cond do
        row.status in [:stale, :unreachable] -> :unreachable
        applied >= current_revision -> :applied
        true -> :pending
      end

    %{slug: row.slug, display_name: row.display_name, status: status, applied: applied, published: current_revision}
  end

  @impl true
  def handle_event("publish_kill", %{"target" => "all"}, socket) do
    publish(socket, %{
      target: %{"kind" => "all"},
      payload: %{"flags" => [%{"name" => "fleet.kill_all", "kill" => true, "rollout_pct" => 0, "rules" => []}]}
    })
  end

  defp publish(socket, %{target: target, payload: payload}) do
    %{admin?: admin?, principal_id: principal_id, namespace: namespace} = socket.assigns.fleet_ctx

    cond do
      not admin? ->
        {:noreply, assign(socket, publish_error: "Only roles[:fleet] == :operator_admin may publish a directive.")}

      is_nil(namespace) ->
        {:noreply, assign(socket, publish_error: "No fleet_namespace configured on this mount.")}

      true ->
        case Registry.record_directive(namespace, %{target: target, payload: payload}, AdminActor.new(principal_id)) do
          {:ok, _directive} -> {:noreply, socket |> assign(publish_error: nil) |> load()}
          {:error, reason} -> {:noreply, assign(socket, publish_error: inspect(reason))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fleet-directives">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:fleet} />
        </:sidebar>

        <.topbar title="Fleet directives" crumbs={["Operator plane", "Fleet", "Directives"]} />

        <div class="wrap">
          <div :if={@publish_error} class="card form-error" id="publish-error" style="padding:10px 14px;color:var(--bad,#b91c1c)">
            {@publish_error}
          </div>

          <div class="gtitle" id="directives-header">
            <h3>Published directives</h3>
            <span class="n">{length(@directives)}</span>
          </div>

          <button :if={@fleet_ctx.admin?} phx-click="publish_kill" phx-value-target="all" id="publish-kill-all" class="btn">
            ⛔ Kill switch — all products
          </button>

          <table class="tbl" id="fleet-drift-table" style="margin-top:14px">
            <thead>
              <tr>
                <th scope="col">Product</th>
                <th scope="col">Directive status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={d <- @drift} id={"drift-#{d.slug}"}>
                <td>{d.display_name || d.slug}</td>
                <td>{drift_text(d)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.app_shell>
    </div>
    """
  end

  defp drift_text(%{status: :unreachable}), do: "directives: unreachable"
  defp drift_text(%{status: :applied}), do: "applied"
  defp drift_text(%{status: :pending, applied: applied, published: published}),
    do: "pending (published #{published}, applied #{applied})"
end
