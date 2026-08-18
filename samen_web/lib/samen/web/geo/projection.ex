defmodule Samen.Web.Geo.Projection do
  @moduledoc """
  The DOCUMENTED map projection for the G7 map view (T55) — pure Elixir math, zero
  dependencies (ADR-037 §5.10: `ash_geo`/PostGIS REJECTED; the map view rides server-side
  SVG + deterministic pin projection, not spatial queries).

  ## Equirectangular (plate carrée)

  The default (and only shipped) projection is the equirectangular / plate-carrée map:
  longitude maps LINEARLY to x, latitude LINEARLY (inverted) to y. It is the projection the
  vendored Natural Earth outline (`Samen.Web.Geo.NaturalEarth`) is authored in, so land shapes
  and pins share ONE coordinate system.

  The canvas is a fixed **360 × 180** viewBox — one SVG user unit per degree — so:

      x = lng + 180          (lng ∈ [-180, 180] → x ∈ [0, 360])
      y = 90 - lat           (lat ∈ [ -90,  90] → y ∈ [0, 180])

  A pin at the equator/prime-meridian `(lat: 0, lng: 0)` projects to the canvas CENTRE
  `(180, 90)`; `(lat: 90, lng: -180)` → the top-left `(0, 0)`; `(lat: -90, lng: 180)` → the
  bottom-right `(360, 180)`. The mapping is total, deterministic, and trivially assertable
  (see `reads_geo_test.exs` / `map_component_test.exs`).

  Out-of-range coordinates are CLAMPED to the canvas edge (a corrupt `lat: 999` pins to the
  pole, never off-canvas or into a NaN) — the projection never raises on a bad number, and a
  `nil` coordinate yields `nil` (an unplottable marker, dropped upstream).
  """

  @width 360
  @height 180

  @doc "The SVG viewBox width (degrees of longitude across the canvas)."
  def width, do: @width

  @doc "The SVG viewBox height (degrees of latitude down the canvas)."
  def height, do: @height

  @doc ~s(The SVG `viewBox` string for the base-map canvas: `"0 0 360 180"`.)
  def view_box, do: "0 0 #{@width} #{@height}"

  @doc """
  Project a `{lat, lng}` degree pair to `{x, y}` SVG canvas coordinates (equirectangular,
  rounded to 2 decimals). Returns `nil` when either coordinate is `nil` (an unplottable pin).

  Out-of-range degrees are clamped to the valid range first (`lat` to ±90, `lng` to ±180),
  so the result is ALWAYS on the `0..360 × 0..180` canvas.
  """
  def project(lat, lng) when is_number(lat) and is_number(lng) do
    x = clamp(lng, -180, 180) + 180
    y = 90 - clamp(lat, -90, 90)
    {round2(x), round2(y)}
  end

  def project(_lat, _lng), do: nil

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp round2(v) when is_float(v), do: Float.round(v, 2)
  defp round2(v), do: v * 1.0
end
