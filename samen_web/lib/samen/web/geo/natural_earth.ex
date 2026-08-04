defmodule Samen.Web.Geo.NaturalEarth do
  @moduledoc """
  The VENDORED, self-contained world base-map geometry for the G7 map view (T55) — a coarse
  continental land outline shipped IN-REPO as pure Elixir data, NEVER fetched from a CDN or a
  tile server at runtime (CLAUDE.md forbids external CDN; the base map must render offline).

  ## Source & license (see `PROVENANCE.md` next to this file)

  Derived from the public-domain **Natural Earth** 1:110m physical "land" layer
  (naturalearthdata.com — "no permission is needed to use Natural Earth; ... you may use the
  maps ... however you like"). This asset is a HAND-SIMPLIFIED, low-vertex SCHEMATIC of that
  layer (continent-level rings, tens of vertices each — NOT the verbatim Natural Earth vertex
  set), chosen to keep repo weight to a few KB while still giving a legible world basemap.
  A vertical that needs country/coastline fidelity swaps in a fuller vendored ring set behind
  the SAME `regions/0` API (the projection and renderer are unchanged). Repo weight is recorded
  in the T55 summary.

  ## Coordinate convention

  Every ring is a list of `{lng, lat}` degree pairs (GeoJSON axis order: x=lng, y=lat),
  authored in the SAME equirectangular frame `Samen.Web.Geo.Projection` projects pins into —
  so land and pins share one coordinate system. Rings are open (the renderer closes the path).
  """

  @typedoc "A land region: a stable id, a display name, and an outer ring of {lng, lat} points."
  @type region :: %{id: String.t(), name: String.t(), ring: [{number(), number()}]}

  # Coarse continental outlines (schematic; see moduledoc). Vertices are {lng, lat}. These are
  # deliberately low-fidelity — enough to read as "a world map" behind the pins, not a survey.
  @regions [
    %{
      id: "north-america",
      name: "North America",
      ring: [
        {-168, 66}, {-160, 71}, {-140, 70}, {-125, 70}, {-95, 74}, {-80, 73}, {-60, 68},
        {-56, 52}, {-66, 45}, {-70, 42}, {-81, 25}, {-97, 26}, {-105, 22}, {-110, 23},
        {-114, 30}, {-124, 40}, {-125, 48}, {-133, 55}, {-150, 59}, {-165, 60}, {-168, 66}
      ]
    },
    %{
      id: "south-america",
      name: "South America",
      ring: [
        {-81, 6}, {-70, 12}, {-60, 10}, {-50, 0}, {-35, -6}, {-38, -13}, {-48, -25},
        {-58, -34}, {-63, -41}, {-66, -50}, {-70, -55}, {-74, -45}, {-72, -30}, {-70, -18},
        {-78, -8}, {-81, 6}
      ]
    },
    %{
      id: "africa",
      name: "Africa",
      ring: [
        {-17, 21}, {-5, 35}, {10, 37}, {25, 32}, {33, 31}, {43, 12}, {51, 12}, {41, -1},
        {40, -15}, {35, -24}, {25, -34}, {18, -34}, {12, -17}, {9, -1}, {6, 4}, {-8, 5},
        {-17, 15}, {-17, 21}
      ]
    },
    %{
      id: "europe",
      name: "Europe",
      ring: [
        {-10, 43}, {-2, 48}, {2, 51}, {-2, 58}, {8, 62}, {18, 69}, {28, 70}, {40, 66},
        {55, 62}, {60, 56}, {48, 50}, {40, 46}, {28, 45}, {18, 42}, {10, 44}, {3, 43},
        {-10, 43}
      ]
    },
    %{
      id: "asia",
      name: "Asia",
      ring: [
        {40, 66}, {60, 72}, {90, 76}, {120, 74}, {160, 70}, {180, 68}, {170, 60}, {155, 52},
        {142, 48}, {130, 42}, {122, 30}, {110, 20}, {100, 8}, {103, 1}, {95, 6}, {88, 22},
        {78, 8}, {72, 20}, {60, 25}, {50, 30}, {45, 40}, {48, 50}, {55, 62}, {40, 66}
      ]
    },
    %{
      id: "australia",
      name: "Australia",
      ring: [
        {113, -22}, {122, -18}, {130, -12}, {137, -12}, {143, -11}, {146, -18}, {150, -24},
        {153, -30}, {150, -37}, {143, -39}, {135, -35}, {129, -32}, {123, -34}, {115, -34},
        {113, -28}, {113, -22}
      ]
    },
    %{
      id: "antarctica",
      name: "Antarctica",
      ring: [
        {-180, -72}, {-120, -74}, {-60, -71}, {0, -70}, {60, -68}, {120, -67}, {180, -72},
        {180, -85}, {-180, -85}, {-180, -72}
      ]
    },
    %{
      id: "greenland",
      name: "Greenland",
      ring: [
        {-45, 60}, {-30, 68}, {-22, 70}, {-20, 76}, {-30, 82}, {-45, 83}, {-60, 80},
        {-55, 70}, {-50, 64}, {-45, 60}
      ]
    }
  ]

  @doc """
  The vendored land regions — a list of `%{id, name, ring: [{lng, lat}]}` (coarse continental
  outlines). The renderer projects each ring through `Samen.Web.Geo.Projection` into an SVG
  `<path>`. Stable order (a deterministic DOM).
  """
  @spec regions() :: [region()]
  def regions, do: @regions

  @doc "The number of vendored land regions (a probe/size sanity check)."
  def region_count, do: length(@regions)

  @doc "The total number of vendored ring vertices across all regions (a size sanity check)."
  def vertex_count, do: @regions |> Enum.map(&length(&1.ring)) |> Enum.sum()
end
