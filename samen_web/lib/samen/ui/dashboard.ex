defmodule Samen.UI.Dashboard do
  @moduledoc """
  The GENERIC dashboard layout (G8, T56) — a thin, responsive grid that COMPOSES several tiles
  (stat cards via `Samen.UI.metric/1`, and charts via `Samen.UI.bar_chart/1` / `line_chart/1` /
  `pie_chart/1`). It holds NO data logic and NO vertical logic: it is a CSS-grid wrapper with a
  `:tile` slot, so a CRM dashboard (first client), an operator cockpit, or any aggregate surface
  reuses it at ≈0 authored LOC. Each tile is a titled card the caller fills with a chart or a
  metric.

  ## No-JS floor

  The grid and every tile are plain server-rendered DOM (a `<div>` grid + `<section>` tiles) —
  the dashboard is fully legible with JS OFF. The charts inside are self-contained inline SVG
  (`Samen.UI.Chart`) with an accessible table fallback; there is no external CDN or JS charting
  library (`CLAUDE.md`).
  """
  use Phoenix.Component

  import Samen.UI.Feedback, only: [empty_state: 1, skeleton: 1]
  import Samen.UI.State, only: [error_state: 1]

  alias Samen.UI.State

  @doc """
  A responsive dashboard grid. Each `:tile` slot entry renders one card; a tile may set
  `:span` (`1` | `2`, default `1`) to occupy two grid columns (a wide chart), and an optional
  `:title` for the tile header.

    * `:id` — the grid container DOM id (default `"dashboard"`).
    * `:tile` (slot) — one card; attrs `:title` (header), `:span` (`1|2`), and the per-tile
      unhappy-path attrs `:loading` (a skeleton in place of the slot) and `:error` (an inline
      error in place of the slot) — one failing tile no longer blanks the dashboard (F27).
    * `:loading` / `:error` — dashboard-level: replace the whole grid.
    * `:empty_text` — shown when there are no tiles.
  """
  attr :id, :string, default: "dashboard"
  attr :loading, :boolean, default: false
  attr :error, :any, default: nil
  attr :retry_event, :string, default: nil
  attr :empty_text, :string, default: "Nothing to show yet."

  slot :tile do
    attr :title, :string
    attr :span, :integer
    attr :loading, :boolean
    attr :error, :any
  end

  def dashboard(assigns) do
    if State.gated?(assigns) do
      State.state_view(assigns, "card")
    else
      ~H"""
      <div :if={@tile == []} id={@id} class="dash-grid dash-empty">
        <.empty_state class="dash-empty-state" title={@empty_text} />
      </div>
      <div :if={@tile != []} id={@id} class="dash-grid">
        <section :for={tile <- @tile} class={["dash-tile", "span-#{tile[:span] || 1}"]}>
          <h3 :if={tile[:title]} class="dash-tile-title">{tile[:title]}</h3>
          <%= cond do %>
            <% State.error?(tile[:error]) -> %>
              <.error_state body={State.error_body(tile[:error])} />
            <% tile[:loading] == true -> %>
              <.skeleton rows={1} shape="chart" />
            <% true -> %>
              {render_slot(tile)}
          <% end %>
        </section>
      </div>
      """
    end
  end
end
