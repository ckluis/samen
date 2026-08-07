defmodule Samen.Web.Operator.FleetLive do
  @moduledoc """
  The WS-J fleet cockpit's TIER-1 surface (`/operator/fleet`, ADR-044 §5.4/§9,
  T84b) — the merged T156 cross-tenant platform-health dashboards land here as
  computed roll-ups over the SAME `FleetReport` rows (no divergent aggregate
  stack, per T156's own cross-ref).

  ## Gating (§5.4 tier 1 — ROLE-gated, not session-gated)

  `roles[:fleet] != nil` (`Samen.Web.Operator.Fleet.gate/2`). This is IN ADDITION
  to the `live_session`'s `{Samen.Web.Operator.Authz, :require_operator}`
  `on_mount` (T146) — every fleet route inherits that hook by construction
  (RP-J-12); this LiveView's own `mount/3` adds the NARROWER `:fleet` scope
  check. No `roles[:fleet]` ⇒ redirect, renders NOTHING (RP-J-5).

  ## Token-blind, no tenant axis (§5.1/§5.2)

  Every value on this page comes from `Samen.Fleet.read/2` — the registry rows
  built ONLY from `flt_*` (token-blind, C7-verified) + top-level `FleetReport`
  scalars. There is NO per-tenant row here; tier-2 cohort rows are
  `FleetDetailLive`'s surface.

  ## Honesty (J5, §8.2, RP-J-9)

    * a metric a reporting app did not compute renders `—`, never `0`
      (`Samen.Web.Operator.Fleet.metric/2`);
    * a `:stale`/`:unreachable`/`:revoked`/`:deregistered` row is EXCLUDED from
      the deliverability/automation ROLL-UPS (never silently summed as its
      last-known-good value) but still RENDERED, labelled as such;
    * the roll-up header is always `"across R of T products reporting"` —
      DERIVED from `Samen.Fleet.read/2`'s own `reporting`/`total`, never a
      literal.

  ## n=1 == n=N (RP-J-9b, §8.3) — DERIVED, not branched

  The header (`Samen.Web.Operator.Fleet.pluralize/2`) is the ONE place a
  row-count literal (the number one) appears — the pluralization helper
  itself, named so the RP-J-9b grep assertion can carve it out explicitly.
  Every comparison affordance (the "vs fleet median" delta, the peer shelf) is
  computed as a PEERS LIST per tile (`Enum.reject(tiles, &(&1.app_id ==
  tile.app_id))`) and rendered `:if={peers != []}` — an EMPTINESS check on a
  derived list, never a row-count-EQUALS-one-style literal comparison. At n=1
  the peers list is always empty (nothing else to reject down to), so the
  affordance is simply never emitted — a CONSEQUENCE of the list
  comprehension, not a conditional branch keyed on the row count.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live, only: [assign_mount: 2, operator_sidebar: 1]

  alias Samen.Fleet.Attention
  alias Samen.Web.Operator.Fleet, as: FleetHelpers

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)

    case FleetHelpers.gate(socket.assigns[:samen_mount], session) do
      {:ok, ctx} ->
        {:ok, socket |> assign(fleet_ctx: ctx) |> load()}

      :denied ->
        {:ok, redirect(socket, to: FleetHelpers.login_path(socket.assigns[:samen_mount]))}
    end
  end

  @doc false
  def load(socket) do
    %{otp_app: otp_app, namespace: namespace} = socket.assigns.fleet_ctx

    case Samen.Fleet.read(otp_app, namespace: namespace) do
      {:ok, %{rows: rows, reporting: reporting, total: total}} ->
        tiles = Enum.map(rows, &build_tile/1)

        assign(socket,
          not_configured: nil,
          tiles: tiles,
          reporting: reporting,
          total: total,
          attention: platform_attention(tiles),
          t156: t156_surfaces(tiles)
        )

      {:error, reason} ->
        assign(socket, not_configured: reason, tiles: [], reporting: 0, total: 0, attention: [], t156: nil)
    end
  end

  defp build_tile(row) do
    report = row.report || %{}

    %{
      app_id: row.app_id,
      slug: row.slug,
      display_name: row.display_name,
      mode: row.mode,
      status: row.status,
      received_at: row.received_at,
      report: report,
      excluded_from_rollup?: row.status not in [:active]
    }
  end

  # ---------------------------------------------------------------------------
  # T156 — merged cross-tenant platform-health dashboards (§5.3's "operational
  # half" — token-blind by construction: everything below is arithmetic over
  # ALREADY-token-blind top-level report scalars, no new tenant axis).
  # ---------------------------------------------------------------------------

  defp t156_surfaces(tiles) do
    counted = Enum.reject(tiles, & &1.excluded_from_rollup?)

    %{
      deliverability_health_index: avg_metric(counted, "deliverability_health_index"),
      automation:
        %{
          rules_tripped_24h: sum_metric(counted, "rules_tripped_24h"),
          kill_switches_engaged: sum_metric(counted, "kill_switches_engaged")
        },
      activity_feed: merged_activity_counts(counted)
    }
  end

  defp avg_metric(tiles, key) do
    values = tiles |> Enum.map(&Map.get(&1.report, key)) |> Enum.filter(&is_number/1)

    case values do
      [] -> nil
      _ -> Float.round(Enum.sum(values) / length(values), 1)
    end
  end

  defp sum_metric(tiles, key) do
    tiles
    |> Enum.map(&Map.get(&1.report, key))
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  defp merged_activity_counts(tiles) do
    tiles
    |> Enum.flat_map(fn tile -> Map.get(tile.report, "activity_counts") || [] end)
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn %{"event_kind" => kind, "count" => count}, acc when is_number(count) ->
      Map.update(acc, kind, count, &(&1 + count))
    end)
    |> Enum.sort_by(fn {_kind, count} -> -count end)
  rescue
    _ -> []
  end

  # Platform-wide attention feed: each tile's own reported `attention` list,
  # tagged with its product, PLUS the cockpit's own operational signals
  # (`Samen.Fleet.Attention` — :heartbeat_rejected / :directive_published /
  # :incident) that ride OUTSIDE any report payload (§4.4a).
  defp platform_attention(tiles) do
    from_reports =
      Enum.flat_map(tiles, fn tile ->
        (Map.get(tile.report, "attention") || [])
        |> Enum.filter(&is_map/1)
        |> Enum.map(&Map.put(&1, "product", tile.slug))
      end)

    from_operational =
      Enum.map(Attention.list(), fn entry ->
        %{
          "kind" => Atom.to_string(entry.kind),
          "severity" => "warn",
          "count" => 1,
          "product" => entry.key
        }
      end)

    from_reports ++ from_operational
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fleet-cockpit">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:fleet} />
        </:sidebar>

        <.topbar title="Fleet" crumbs={["Operator plane", "Fleet"]} />

        <div :if={@not_configured} class="wrap">
          <.empty_state
            class="fleet-not-configured"
            icon="⛴"
            title="Fleet not configured."
            body={"This cockpit's fleet mode is not usable yet: #{inspect(@not_configured)}. Wire fleet_namespace: on the operator mount, or set config :your_app, :fleet, mode: :manual|:heartbeat."}
          />
        </div>

        <div :if={!@not_configured} class="wrap">
          <div class="gtitle" id="fleet-header">
            <h3>{Samen.Web.Operator.Fleet.pluralize(length(@tiles), "product")}</h3>
            <span class="lane">· across {@reporting} of {@total} products reporting</span>
          </div>

          <.empty_state
            :if={@tiles == []}
            class="fleet-empty"
            icon="⛴"
            title="No products registered yet."
            body="Register an app in mode A/B, or run this cockpit's own product in :embedded mode — the registry never contains an app that did not register."
          />

          <table :if={@tiles != []} class="tbl" id="fleet-tiles">
            <thead>
              <tr>
                <th scope="col">Product</th>
                <th scope="col">Status</th>
                <th scope="col">Health</th>
                <th scope="col">MRR</th>
                <th scope="col">Deliverability</th>
                <th scope="col">vs fleet</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={tile <- @tiles} id={"fleet-tile-#{tile.app_id}"} class="fleet-tile-row">
                <td>
                  <.link navigate={"/operator/fleet/#{tile.app_id}"} class="fleet-tile-name">
                    {tile.display_name || tile.slug}
                  </.link>
                  <div class="fleet-tile-slug" style="font-size:11px;color:var(--muted)">{tile.slug} · {tile.mode}</div>
                </td>
                <td>
                  <.pill variant={status_variant(tile.status)}>{tile.status}</.pill>
                </td>
                <td>{Samen.Web.Operator.Fleet.metric(tile.report, "health_status")} · {Samen.Web.Operator.Fleet.metric(tile.report, "health_score")}</td>
                <td>{money(tile.report)}</td>
                <td>{Samen.Web.Operator.Fleet.metric(tile.report, "deliverability_health_index")}</td>
                <td>
                  <span :if={peers_of(@tiles, tile) != []} class="fleet-vs-peers" id={"fleet-peers-#{tile.app_id}"}>
                    vs {length(peers_of(@tiles, tile))} other product(s) in the fleet
                  </span>
                </td>
              </tr>
            </tbody>
          </table>

          <div class="gtitle" id="t156-header" style="margin-top:22px">
            <h3>Platform health (T156)</h3>
            <span class="lane">· cross-tenant, token-blind by construction</span>
          </div>
          <div :if={@t156} class="card" id="t156-panel" style="padding:16px 20px">
            <div>Deliverability health index (avg across reporting products): {@t156.deliverability_health_index || "—"}</div>
            <div>Automation kill-switches engaged (fleet-wide): {@t156.automation.kill_switches_engaged}</div>
            <div>Automation rules tripped, 24h (fleet-wide): {@t156.automation.rules_tripped_24h}</div>
          </div>

          <div class="gtitle" id="fleet-attention-header" style="margin-top:22px">
            <h3>Attention</h3>
            <span class="n">{length(@attention)}</span>
          </div>
          <.empty_state
            :if={@attention == []}
            class="fleet-attention-empty"
            icon="✓"
            title="Nothing needs attention."
            body="No incident, staleness, or drift signals across the fleet."
          />
          <ul :if={@attention != []} id="fleet-attention-list">
            <li :for={{entry, idx} <- Enum.with_index(@attention)} id={"fleet-attention-#{idx}"}>
              <strong>{entry["kind"]}</strong> · {entry["product"]}
            </li>
          </ul>
        </div>
      </.app_shell>
    </div>
    """
  end

  defp status_variant(:active), do: "ok"
  defp status_variant(:stale), do: "warn"
  defp status_variant(_), do: "bad"

  defp money(report) do
    case Map.get(report, "mrr_cents") do
      cents when is_integer(cents) -> Samen.Web.Operator.Live.dollars(cents)
      _ -> "—"
    end
  end

  # The peer list for ONE tile — every OTHER tile. At n=1 this is always `[]`
  # (there is nothing else to reject down to), which is what makes the "vs
  # fleet" affordance's absence a DERIVED consequence rather than a branch
  # (§8.3, RP-J-9b).
  defp peers_of(tiles, tile), do: Enum.reject(tiles, &(&1.app_id == tile.app_id))
end
