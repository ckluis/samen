defmodule Samen.Web.GeoSet do
  @moduledoc """
  One BOUNDED set of map markers — the value `Samen.Web.Reads.geo_markers!/3` returns to the
  `Samen.UI.map/1` renderer (G7, T55). The geographic analogue of `%Samen.Web.Series{}`:
  where a `%Series{}` carries per-slice aggregate measures, a `%GeoSet{}` carries a bounded
  list of projected points.

  ## Always bounded (the marker-storm keystone)

  A `%GeoSet{}` holds at most `max_markers` `%Marker{}`s by construction — `geo_markers!/3`
  reads `Ash.Query.limit(max_markers + 1)` org-scoped rows and, when MORE than the cap exist,
  drops the overflow, sets `capped: true`, and records how many were withheld (`shown` /
  `capped_count`) so the view can render an honest "N more — narrow your filter" affordance.
  A resource with 100k geo rows can never OOM the LiveView or the DOM: at most `max_markers`
  points ever cross into Elixir/HTML.

  ## Masking posture (INV-1)

  Two independent guards, both enforced in `geo_markers!/3`, never here (this is a dumb carrier):

    * **Coordinate leak** — a marker's `lat`/`lng` may NOT come from a vault-routed (🔒) field:
      `geo_markers!/3` REFUSES (`Samen.Web.Reads.MaskedCoordinateError`) rather than plot a
      precise location the actor's plane may not see. Coordinates in a `%Marker{}` are always
      from a non-secret facet.
    * **Label leak** — a marker's `label` (popover/tooltip text) is resolved through
      `Samen.Api.PiiResolution` on the actor's plane BEFORE it lands in the struct, so a vaulted
      label is a `%Samen.Masked{}` (→ `••••`) for an operator-without-grant, plaintext for the
      tenant. The renderer draws `label` verbatim (no reveal branch).

  ## Fields

    * `markers`      — the bounded, projected points (`[%Marker{}]`), in stable id order.
    * `projection`   — the projection module used (default `Samen.Web.Geo.Projection`).
    * `max_markers`  — the cap applied (the bounding bound).
    * `shown`        — `length(markers)` (the plotted count).
    * `capped`       — `true` when the org-scoped set had MORE than `max_markers` points.
    * `capped_count` — how many points were withheld (`total - shown` when known, else `nil`).
  """

  alias Samen.Web.GeoSet.Marker

  defstruct markers: [],
            projection: Samen.Web.Geo.Projection,
            max_markers: nil,
            shown: 0,
            capped: false,
            capped_count: nil

  @type t :: %__MODULE__{
          markers: [Marker.t()],
          projection: module(),
          max_markers: pos_integer() | nil,
          shown: non_neg_integer(),
          capped: boolean(),
          capped_count: non_neg_integer() | nil
        }

  defmodule Marker do
    @moduledoc """
    One plotted point of a `%Samen.Web.GeoSet{}`.

      * `id`    — the source record's id (the stable DOM key; a non-PII uuid).
      * `lat` / `lng` — the geographic coordinates (a NON-vaulted facet — the coordinate-leak
        guard in `geo_markers!/3` guarantees this).
      * `x` / `y` — the projected SVG canvas coordinates (via the projection), or `nil` when the
        coordinates were unplottable (dropped upstream).
      * `label` — the popover/tooltip text: a plane-resolved value (plaintext, or `%Samen.Masked{}`
        → `••••`), NEVER a raw `vt_*` token. May be `nil`.
      * `raw`   — the original source record (for a caller's custom popover slot).
    """
    defstruct [:id, :lat, :lng, :x, :y, :label, :raw]

    @type t :: %__MODULE__{
            id: term(),
            lat: number() | nil,
            lng: number() | nil,
            x: number() | nil,
            y: number() | nil,
            label: term(),
            raw: term()
          }
  end
end
