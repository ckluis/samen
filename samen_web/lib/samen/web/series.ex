defmodule Samen.Web.Series do
  @moduledoc """
  One AGGREGATE result — the value `Samen.Web.Reads.aggregate_by!/3` and
  `Samen.Web.Reads.time_series!/3` return to a chart/dashboard tile (G8, T56). The aggregate
  analogue of `%Samen.Web.Board{}`: where a `%Board{}` carries per-group ROWS (bounded lists),
  a `%Series{}` carries per-group MEASURES (counts / sums / averages) — ONE number per slice,
  never a row set. It is the data a `Samen.UI.bar_chart/1` / `line_chart/1` / `pie_chart/1`
  renders as server-computed SVG geometry.

  ## Never carries rows (the DB-aggregate keystone)

  A `%Series{}` has NO `rows` field by construction: every `%Point{}` holds a `value` computed
  as a SQL aggregate (`Ash.count!`/`Ash.sum!`/`Ash.avg!`) — the underlying rows are NEVER
  transferred out of Postgres. A 10k-row table produces a `%Series{}` of at most `max_points`
  Points, each a single number. This is the structural proof that a chart can never OOM the
  LiveView and never load-then-aggregate in Elixir (see `reads_aggregate_test.exs`).

  ## Masking / aggregate-leak posture (INV-1)

  The DIMENSION (`%Point{}.key`/`label`) is ALWAYS a non-vaulted facet: `aggregate_by!/3`
  REFUSES a vault-routed (🔒) group field (`Samen.Web.Reads.MaskedGroupKeyError`) and a
  vault-routed MEASURE field (`Samen.Web.Reads.MaskedMeasureError`), so no plaintext or vault
  token can ever become a chart label, axis, tooltip, or a summed secret. (`aggregate_by!/3`'s
  `:collapse_below` merely tidies tiny slices into `Other` for legibility — it is NOT a
  disclosure control, since the `Other` value is the arithmetic remainder; the vault refusal is
  the sole PII guarantee.)

  ## Fields

    * `points`    — the ordered slices (`[%Point{}]`), each a `{key, label, value, raw}`.
    * `measure`   — `:count | {:sum, field} | {:avg, field}` (what each `value` measures).
    * `dimension` — the grouping facet: a field atom (a breakdown) or `:bucket` (a time series).
    * `total`     — the grand-total measure across ALL slices (a SQL aggregate over the whole
      org-scoped set), for count/sum — used for pie percentages and a "total" stat. `nil` for
      `:avg` (an average has no meaningful grand sum).
    * `capped`    — `true` when the dimension had MORE distinct keys than `max_points` (the
      tail was bucketed into an `Other` slice) OR a `:collapse_below` small-label fold occurred.
    * `max_points` — the cap on the number of slices (the bounding bound).
  """

  alias Samen.Web.Series.Point

  defstruct points: [], measure: :count, dimension: nil, total: nil, capped: false, max_points: nil

  @type measure :: :count | {:sum, atom()} | {:avg, atom()}

  @type t :: %__MODULE__{
          points: [Point.t()],
          measure: measure(),
          dimension: atom() | :bucket | nil,
          total: number() | nil,
          capped: boolean(),
          max_points: pos_integer() | nil
        }

  defmodule Point do
    @moduledoc """
    One slice of a `%Samen.Web.Series{}` — a non-vaulted dimension key, its display label, and
    the slice's aggregate measure.

      * `key`   — the stored dimension value the slice aggregates (`nil` = the uncategorized
        bucket; `:__other__` = the bounded tail). NEVER a vaulted/plaintext value.
      * `label` — the caller's display label for the slice (defaults to the key).
      * `value` — the NUMERIC measure for geometry (count integer; a Money sum in minor units;
        an average as a float). Always a plain number so the chart can compute bar heights /
        line points / pie arcs without inspecting a domain type.
      * `raw`   — the ORIGINAL aggregate value (an `Integer`, `%Money{}`, or `Decimal`), so the
        caller can format a tooltip/legend (e.g. `$1,234.00`) from the domain value.
    """
    defstruct key: nil, label: nil, value: 0, raw: nil

    @type t :: %__MODULE__{
            key: term() | nil,
            label: term() | nil,
            value: number(),
            raw: term()
          }
  end

  @doc "The grand total as a number (0 when `nil`) — for pie percentages / a total stat."
  @spec total_value(t()) :: number()
  def total_value(%__MODULE__{total: t}) when is_number(t), do: t
  def total_value(%__MODULE__{points: points}), do: Enum.reduce(points, 0, &(&1.value + &2))

  @doc "The largest slice `value` (0 when empty) — the bar/line axis scale."
  @spec max_value(t()) :: number()
  def max_value(%__MODULE__{points: []}), do: 0
  def max_value(%__MODULE__{points: points}), do: points |> Enum.map(& &1.value) |> Enum.max()
end
