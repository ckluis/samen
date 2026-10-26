defmodule Samen.Web.Operator.DataMapLive do
  @moduledoc """
  Framework OPERATOR / Data map at `/operator/data-map` (issue #97) — the host app's ERD
  and architectural separation, generated from the catalog. Inherited at 0 vertical LOC
  via `samen_operator_routes/2`.

    * `/operator/data-map` — the overview: every scope domain grouped by layer (the app's
      own scopes · framework substrate · the token-blind aggregate plane), with table
      counts, PII field counts and the cross-domain links between them.
    * `/operator/data-map/:domain` — one domain's ERD (`Samen.UI.DataMap.erd/1`) plus a
      complete field reference.

  ## Documentation that cannot drift

  Everything rendered comes from `Samen.DataMap.build/1`, which reads the same
  `Samen.AI.Catalog.dict/1` the drift-checked `schema.dict.json` is dumped from. The map
  changes when the code changes; nobody maintains it.

  ## Metadata only — nothing to mask

  This page reads compile-time resource metadata and NO row, for any org. A PII field is
  shown by NAME with a lock, never a value, so there is no `%Masked{}` branch and no reveal
  path here. Like every operator route it rides the `:require_operator` on_mount.

  ADR-042 Class B: the whole page, ERD included, renders from `mount`/`handle_params` with
  JS off — the domain links are plain `<a href>`.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  @base "/operator/data-map"

  @layers [
    app: {"Your app", "The scope domains this app declares — where tenant data lives."},
    framework: {"Framework substrate", "Tables samen ships into every app (agent runs, replay)."},
    aggregate:
      {"Token-blind aggregate plane",
       "Cross-tenant rollups. Default-deny, readable only by the aggregate actor; no PII column exists."}
  ]

  @impl true
  def mount(_params, session, socket) do
    {:ok, socket |> assign_mount(session) |> assign(map: Samen.DataMap.build(), base: @base)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    map = socket.assigns.map

    case Map.get(params, "domain") do
      nil ->
        {:noreply, assign(socket, domain: nil, title: "Data map")}

      slug ->
        case Samen.DataMap.domain(map, slug) do
          nil -> {:noreply, assign(socket, domain: :unknown, slug: slug, title: "Data map")}
          d -> {:noreply, assign(socket, domain: d, title: d.name)}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, layers: @layers, totals: totals(assigns.map))

    ~H"""
    <div id="operator-data-map">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:data_map} />
        </:sidebar>

        <.topbar title={@title} crumbs={crumbs(@domain)} />

        <%= cond do %>
          <% @domain == :unknown -> %>
            <div class="wrap">
              <div class="card" id="unknown-domain" style="padding:22px 20px;color:var(--muted)">
                No domain named <span class="mono">{@slug}</span>. <a href={@base}>Back to the data map</a>
              </div>
            </div>
          <% is_nil(@domain) -> %>
            <div class="metrics">
              <.metric label="Domains" value={@totals.domains} sub="scope domains + substrate" />
              <.metric label="Tables" value={@totals.tables} sub="every Ash resource with a table" />
              <.metric label="Relationships" value={@totals.edges} sub="declared, never inferred" />
              <.metric label="PII fields" value={@totals.pii} sub="vault-routed, masked off-plane" />
            </div>
            <div class="wrap">
              <p class="dmap-intro" style="font-size:13px;color:var(--muted);margin:0 0 20px;max-width:760px">
                Generated from the catalog — the same introspection <span class="mono">schema.dict.json</span>
                and the verifiers read. It changes when the code changes; nobody draws it.
              </p>
              <section :for={{layer, {name, blurb}} <- @layers} :if={in_layer(@map, layer) != []} class="dmap-layer" id={"layer-#{layer}"}>
                <div class="dmap-layer-h">
                  <h2>{name}</h2>
                  <p>{blurb}</p>
                </div>
                <div class="dmap-grid">
                  <a :for={d <- in_layer(@map, layer)} href={"#{@base}/#{d.slug}"} class={"dmap-card dmap-l-#{d.layer}"} id={"domain-#{d.slug}"}>
                    <h3>{d.name} <span>{d.table_count} {if d.table_count == 1, do: "table", else: "tables"}</span></h3>
                    <div class="mod">{d.module}</div>
                    <div class="dmap-tables">
                      <span :for={r <- d.tables} class={if @map.tables[r].pii_count > 0, do: "pii"}>
                        {if @map.tables[r].pii_count > 0, do: "🔒 "}{@map.tables[r].name}
                      </span>
                    </div>
                    <div class="dmap-meta">
                      <span><b>{d.pii_count}</b> PII {if d.pii_count == 1, do: "field", else: "fields"}</span>
                      <span><b>{internal_edges(@map, d.slug)}</b> internal links</span>
                    </div>
                    <div :if={d.links_out != []} class="dmap-links">
                      references {links(@map, d.links_out)}
                    </div>
                    <div :if={d.links_in != []} class="dmap-links">
                      referenced by {links(@map, d.links_in)}
                    </div>
                  </a>
                </div>
              </section>
            </div>
          <% true -> %>
            <div class="wrap">
              <div class="dmap-legend">
                <span><a href={@base}>← All domains</a></span>
                <span><i style="background:var(--brand-wash);border:1px solid var(--line2)"></i>{@domain.module}</span>
                <span><i style="background:var(--violet-wash)"></i>🔒 PII — vault-routed, masked off-plane</span>
                <span><i style="background:transparent;border:1px dashed var(--faint)"></i>table in another domain</span>
                <span>crow's foot = many · bars = one</span>
              </div>
              <.erd map={@map} domain={@domain.slug} base_path={@base} />
              <div class="dmap-ref" id="field-reference">
                <details :for={r <- @domain.tables} id={"ref-#{@map.tables[r].table_name}"}>
                  <summary>{@map.tables[r].name}<span>{@map.tables[r].table_name}</span></summary>
                  <table>
                    <tbody>
                      <tr :for={f <- @map.tables[r].fields} class={if f.pii, do: "pii"}>
                        <td>{if f.pii, do: "🔒 "}{f.name}</td>
                        <td class="t">{f.column}</td>
                        <td class="t">{f.type}</td>
                      </tr>
                    </tbody>
                  </table>
                </details>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(%{name: name}), do: ["Operator plane", "Data map", name]
  defp crumbs(_), do: ["Operator plane", "Data map"]

  defp in_layer(map, layer), do: Enum.filter(map.domains, &(&1.layer == layer))

  defp internal_edges(map, slug),
    do: Enum.count(map.edges, &(&1.from_domain == slug and &1.to_domain == slug))

  defp links(map, pairs) do
    Enum.map_join(pairs, ", ", fn {slug, n} ->
      name = (Samen.DataMap.domain(map, slug) || %{name: slug}).name
      "#{name} (#{n})"
    end)
  end

  defp totals(map) do
    %{
      domains: length(map.domains),
      tables: map_size(map.tables),
      edges: length(map.edges),
      pii: map.tables |> Map.values() |> Enum.map(& &1.pii_count) |> Enum.sum()
    }
  end
end
