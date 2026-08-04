defmodule Samen.UI.Map do
  @moduledoc """
  The GENERIC map view (G7, T55) — the framework renderer for a `%Samen.Web.GeoSet{}` (the
  value `Samen.Web.Reads.geo_markers!/3` returns). Plots org-scoped, bounded records as pins
  over a self-contained world basemap. Framework-level, holds NO vertical logic; parameterized
  only by the geo set, an optional value formatter, and an optional `:marker` popover slot — so
  a locations dashboard (first client), a freight-origins map, or any coordinate-bearing
  resource reuses it at ≈0 authored LOC.

  ## Self-contained basemap — no external CDN, no tile fetch (CLAUDE.md)

  The base map is inline `<svg>`: the vendored Natural Earth land outline
  (`Samen.Web.Geo.NaturalEarth`, public-domain, shipped in-repo) projected server-side through
  `Samen.Web.Geo.Projection` (equirectangular) into `<path>` land shapes, with pins projected
  the SAME way into `<circle>`s over the top. There is NO external tile server, NO CDN, and NO
  runtime download — the whole map renders offline from repo data.

  ## Bring-your-tiles seam (fail-honest, OFF by default)

  A HOST may plug in its OWN tile provider for a street-level basemap via
  `Samen.Web.Geo.TileSource` (a host opt-in that introduces the host's external dependency).
  Pass the resolved source as `:tile_source`:

    * `nil` (default) — SVG basemap only; no street-level layer is even attempted.
    * `{:error, :not_configured}` — street-level was requested but the host has not configured
      a tile URL: the map renders the SVG basemap PLUS an honest "tiles not configured" notice.
      It NEVER reaches for a default/hardcoded external tile host (no CDN leak, no surprise call).
    * `{:ok, %{url_template: ...}}` — the host opted in: a street-level tile layer is rendered
      from the HOST's own `{z}/{x}/{y}` template (the only external dependency, the host's choice).

  ## No-JS floor (ADR-042/T113)

  The basemap SVG, every pin, and an accessible data `<table>` (visually hidden by default, or
  shown with `show_table`) are all present in the SERVER-rendered DOM — the map is legible with
  JS OFF. Pan/zoom and tile loading are progressive enhancement only. No `<script>`, no CDN.

  ## Masking (INV-1) — a dumb renderer

  The renderer never inspects the vault. `geo_markers!/3` guarantees coordinates come from a
  NON-vaulted facet (`MaskedCoordinateError` refuses a vaulted coordinate) and resolves each
  marker `label` through `Samen.Api.PiiResolution` on the actor's plane BEFORE it reaches the
  struct — so a vaulted label is a `%Samen.Masked{}` (→ `••••`) for an operator-without-grant,
  plaintext for the tenant. This component draws `marker.label` verbatim (no reveal branch).
  """
  use Phoenix.Component

  alias Samen.Web.Geo.NaturalEarth
  alias Samen.Web.GeoSet

  @doc """
  Render a `%Samen.Web.GeoSet{}` as a self-contained SVG map (basemap + projected pins).

    * `:geo_set` (required) — a `%Samen.Web.GeoSet{}` (from `Samen.Web.Reads.geo_markers!/3`).
    * `:id` — DOM id (default `"map"`).
    * `:title` — an optional caption above the map.
    * `:tile_source` — the resolved bring-your-tiles source (see moduledoc). Default `nil` (SVG only).
    * `:show_table` — render the accessible data table visibly (default `false` = screen-reader only).
    * `:marker` (slot) — an optional custom popover; receives the `%GeoSet.Marker{}`. Defaults to
      the marker `label` in an SVG `<title>` tooltip.
  """
  attr :geo_set, :any, required: true, doc: "a %Samen.Web.GeoSet{}"
  attr :id, :string, default: "map"
  attr :title, :string, default: nil
  attr :tile_source, :any, default: nil
  attr :show_table, :boolean, default: false
  slot :marker

  def map(assigns) do
    assigns =
      assigns
      |> assign_new(:geo_set, fn -> %GeoSet{} end)
      |> then(fn a -> assign(a, :vb, projection(a).view_box()) end)
      |> then(fn a -> assign(a, :land, land_paths(projection(a))) end)
      |> then(fn a -> assign(a, :pins, plottable(a.geo_set)) end)
      |> then(fn a -> assign(a, :tiles, tile_mode(a.tile_source)) end)

    ~H"""
    <figure id={@id} class="geo-map">
      <figcaption :if={@title} class="geo-map-title">{@title}</figcaption>

      <p :if={@tiles == :not_configured} class="geo-map-notice" data-tiles="not-configured">
        Street-level tiles are not configured. Showing the built-in world map.
      </p>

      <div class="geo-map-canvas">
        <svg
          class="geo-map-svg"
          viewBox={@vb}
          role="img"
          aria-label={@title || "Map"}
          preserveAspectRatio="xMidYMid meet"
        >
          <rect class="geo-map-ocean" x="0" y="0" width={@geo_set.projection.width()} height={@geo_set.projection.height()} />

          <%!-- Host-configured street-level tiles (opt-in only; never a default/CDN url). --%>
          <image
            :if={match?({:tiles, _}, @tiles)}
            class="geo-map-tiles"
            x="0"
            y="0"
            width={@geo_set.projection.width()}
            height={@geo_set.projection.height()}
            href={tile_href(@tiles)}
            data-tile-template={tile_template(@tiles)}
          />

          <%!-- Self-contained Natural Earth land outline (always present; the offline basemap). --%>
          <path :for={region <- @land} class="geo-land" d={region.d} data-region={region.id}>
            <title>{region.name}</title>
          </path>

          <%!-- Projected, bounded, org-scoped pins. --%>
          <g class="geo-markers">
            <g :for={pin <- @pins} class="geo-marker" data-id={to_string(pin.id)} data-lat={pin.lat} data-lng={pin.lng}>
              <circle class="geo-marker-dot" cx={pin.x} cy={pin.y} r="2.4" />
              <%= if @marker != [] do %>
                {render_slot(@marker, pin)}
              <% else %>
                <title>{pin.label}</title>
              <% end %>
            </g>
          </g>
        </svg>
      </div>

      <p :if={@geo_set.capped} class="geo-map-capped" data-capped="true">
        Showing the first {@geo_set.shown} locations — narrow your filter to see more.
      </p>

      <.marker_table geo_set={@geo_set} id={@id} show={@show_table} />
    </figure>
    """
  end

  # -- the accessible data-table fallback (always in the DOM, the no-JS floor) -----------------

  attr :geo_set, :any, required: true
  attr :id, :string, required: true
  attr :show, :boolean, default: false

  defp marker_table(assigns) do
    ~H"""
    <table class={["geo-map-data", !@show && "sr-only"]} id={"#{@id}-table"}>
      <caption>Map locations</caption>
      <thead>
        <tr>
          <th scope="col">Location</th>
          <th scope="col">Latitude</th>
          <th scope="col">Longitude</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={m <- @geo_set.markers} data-id={to_string(m.id)}>
          <th scope="row">{m.label}</th>
          <td>{m.lat}</td>
          <td>{m.lng}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  # -- server-computed geometry (the no-JS floor) ----------------------------------------------

  # The projection module carried by the geo set (default the equirectangular projection).
  defp projection(%{geo_set: %GeoSet{projection: p}}) when not is_nil(p), do: p
  defp projection(_), do: Samen.Web.Geo.Projection

  @doc false
  # Project each vendored Natural Earth land ring to an SVG path `d` (server-side).
  def land_paths(projection) do
    Enum.map(NaturalEarth.regions(), fn region ->
      %{id: region.id, name: region.name, d: ring_to_path(region.ring, projection)}
    end)
  end

  defp ring_to_path(ring, projection) do
    ring
    |> Enum.map(fn {lng, lat} -> projection.project(lat, lng) end)
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {{x, y}, 0} -> "M#{x},#{y}"; {{x, y}, _} -> "L#{x},#{y}" end)
    |> Kernel.<>(" Z")
  end

  # Only markers that projected to a real {x, y} are plotted (a nil coordinate is unplottable).
  defp plottable(%GeoSet{markers: markers}) do
    Enum.filter(markers, fn m -> not is_nil(m.x) and not is_nil(m.y) end)
  end

  defp plottable(_), do: []

  # The tile-layer mode derived from a resolved `Samen.Web.Geo.TileSource`.
  #   nil                          -> :none           (SVG only; street-level not requested)
  #   {:error, :not_configured}    -> :not_configured (honest notice + SVG fallback; NO external call)
  #   {:ok, cfg}                   -> {:tiles, cfg}    (host opted in; render the host's tile url)
  defp tile_mode(nil), do: :none
  defp tile_mode({:error, :not_configured}), do: :not_configured
  defp tile_mode({:ok, %{} = cfg}), do: {:tiles, cfg}
  defp tile_mode(_), do: :not_configured

  defp tile_template({:tiles, %{url_template: t}}), do: t
  defp tile_template(_), do: nil

  # The initial tile `href` is the host template with the world-tile coordinates (z=0/x=0/y=0)
  # substituted — a concrete first tile from the HOST's own server (no CDN/default host).
  defp tile_href({:tiles, %{url_template: template}}) do
    template
    |> String.replace("{z}", "0")
    |> String.replace("{x}", "0")
    |> String.replace("{y}", "0")
  end

  defp tile_href(_), do: nil
end
