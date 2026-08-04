defmodule Samen.UI.MapComponentTest do
  @moduledoc """
  Unit proofs for the GENERIC map renderer (`Samen.UI.map/1`, T55/G7) — the reusable renderer
  a locations dashboard (or any coordinate-bearing resource) consumes. These test the FRAMEWORK
  component in isolation against a hand-built `%Samen.Web.GeoSet{}`:

    * BASEMAP — the vendored Natural Earth land outline renders server-side as inline SVG
      `<path>`s (one per region), on the documented equirectangular `viewBox` — present with JS OFF.
    * PROJECTION — a pin at a known lat/lng lands at the documented SVG position (deterministic).
    * NO EXTERNAL CDN — the DEFAULT (SVG-only) render carries ZERO external host and NO `<script>`.
    * TILES fail-honest — an unconfigured street-level request renders the honest empty-state copy
      + the SVG fallback (no external call); a HOST-configured source renders the host's OWN url.
    * BOUNDING — a capped geo set renders the "N more" affordance.
    * MASKING — a dumb renderer: a `%Samen.Masked{}` marker label renders `••••`, never plaintext.
    * NO-JS TABLE — an accessible data table mirrors every marker.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Geo.Projection
  alias Samen.Web.GeoSet
  alias Samen.Web.GeoSet.Marker

  defp marker(id, lat, lng, label) do
    {x, y} = Projection.project(lat, lng)
    %Marker{id: id, lat: lat, lng: lng, x: x, y: y, label: label}
  end

  defp geo_set(markers, opts \\ []) do
    %GeoSet{
      markers: markers,
      projection: Projection,
      max_markers: Keyword.get(opts, :max_markers, 200),
      shown: length(markers),
      capped: Keyword.get(opts, :capped, false),
      capped_count: Keyword.get(opts, :capped_count)
    }
  end

  defp render(assigns) do
    render_component(&Samen.UI.map/1, Map.merge(%{id: "m", geo_set: geo_set([])}, assigns))
  end

  test "BASEMAP: vendored Natural Earth land renders as inline SVG paths on the equirectangular viewBox" do
    html = render(%{})

    assert html =~ ~s(class="geo-map-svg")
    assert html =~ ~s(viewBox="0 0 360 180")
    assert html =~ ~s(class="geo-land")
    # One <path> per vendored region, each carrying its stable id.
    assert html =~ ~s(data-region="africa")
    assert html =~ ~s(data-region="antarctica")

    region_paths = html |> String.split(~s(class="geo-land")) |> length() |> Kernel.-(1)
    assert region_paths == Samen.Web.Geo.NaturalEarth.region_count()
  end

  test "PROJECTION: a pin at (0,0) lands at canvas centre (180,90); poles/meridians at the corners" do
    html = render(%{geo_set: geo_set([marker("origin", 0, 0, "Null Island")])})

    # (lat 0, lng 0) → (180, 90) per the documented equirectangular mapping.
    assert html =~ ~s(cx="180.0")
    assert html =~ ~s(cy="90.0")
    assert html =~ ~s(data-id="origin")

    # Corners, computed the same way (deterministic).
    assert Projection.project(90, -180) == {0.0, 0.0}
    assert Projection.project(-90, 180) == {360.0, 180.0}
  end

  test "NO EXTERNAL CDN / NO SCRIPT: the default SVG render reaches for zero external hosts" do
    html = render(%{geo_set: geo_set([marker("a", 40.0, -74.0, "NYC")])})

    refute html =~ "http://"
    refute html =~ "https://"
    refute html =~ "<script"
    refute html =~ "cdn"
    # The pin + basemap are BOTH in the server DOM (no-JS floor).
    assert html =~ ~s(class="geo-marker-dot")
    assert html =~ ~s(class="geo-land")
  end

  test "TILES fail-honest: an unconfigured street-level request shows the honest notice + SVG fallback, no external call" do
    html = render(%{geo_set: geo_set([]), tile_source: {:error, :not_configured}})

    assert html =~ "Street-level tiles are not configured"
    assert html =~ ~s(data-tiles="not-configured")
    # It falls back to the self-contained SVG and makes ZERO external call.
    assert html =~ ~s(class="geo-map-svg")
    refute html =~ "http://"
    refute html =~ "https://"
    refute html =~ ~s(class="geo-map-tiles")
  end

  test "TILES host opt-in: a configured self-hosted source renders the HOST's OWN tile url (its choice)" do
    src = {:ok, %{url_template: "https://tiles.acme-internal.example/{z}/{x}/{y}.png", attribution: "ACME"}}
    html = render(%{geo_set: geo_set([]), tile_source: src})

    assert html =~ ~s(class="geo-map-tiles")
    # The host's own template is used verbatim; {z}/{x}/{y} substituted for the world tile.
    assert html =~ "tiles.acme-internal.example/0/0/0.png"
    # No honest-notice when tiles ARE configured.
    refute html =~ "not configured"
  end

  test "BOUNDING: a capped geo set renders the 'N more' affordance" do
    html = render(%{geo_set: geo_set([marker("a", 1.0, 1.0, "x")], capped: true)})

    assert html =~ ~s(data-capped="true")
    assert html =~ "narrow your filter"
  end

  test "MASKING: a %Masked{} marker label renders ••••, never plaintext, never a vt_ token" do
    masked = Samen.Masked.new("vt_secret_token", :full_name)
    html = render(%{geo_set: geo_set([marker("p1", 51.5, -0.12, masked)])})

    assert html =~ "••••"
    refute html =~ "vt_secret_token"
    refute html =~ "vt_"
  end

  test "NO-JS TABLE: an accessible data table mirrors every marker (sr-only by default)" do
    html = render(%{geo_set: geo_set([marker("p1", 10.0, 20.0, "Somewhere")])})

    assert html =~ ~s(class="geo-map-data sr-only")
    assert html =~ "Somewhere"
    assert html =~ "<caption>Map locations</caption>"
  end

  test "EMPTY: a zero-marker geo set still renders the basemap (the map is legible with no pins)" do
    html = render(%{geo_set: geo_set([])})

    assert html =~ ~s(class="geo-land")
    refute html =~ ~s(class="geo-marker-dot")
  end
end
