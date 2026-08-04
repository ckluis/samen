defmodule Samen.UI.Board do
  @moduledoc """
  The GENERIC grouped-columns board — the framework renderer for a `%Samen.Web.Board{}`
  (the value `Samen.Web.Reads.group_by!/3` returns). One `<section class="bcol">` per group
  (the board's COLUMNS), each column a header (`label` + exact `count`) over its per-group-
  BOUNDED cards, plus a "load more" affordance when the column was capped (`has_more`).

  This is the reusable analogue of `Samen.UI.list_view/1` for a FLAT `%Page{}`: `list_view`
  renders one keyset window of a list, `board` renders an ordered set of per-column-bounded
  buckets. It is framework-level and holds NO vertical logic — it is parameterized by the
  CARD RENDERER (the required `:card` slot, `:let={row}`), so the CRM Pipeline (T51, first
  client), a calendar (columns = days), a gallery (sections), or a tree (nodes) all reuse it
  at ≈0 authored LOC. The CRM-specific part — which resource, which columns, which card
  fields — is thin wiring in the calling LiveView (`Samen.Web.CRM.PipelineLive`).

  ## Masking posture (dumb renderer, same as the rest of the kit)

  The board never inspects, coerces, or stringifies a card's field value: each card is
  whatever the `:card` slot renders from a row the CALLER already plane-resolved through
  `Samen.Api.PiiResolution` (exactly like `list_view/1`). If a row field is a
  `%Samen.Masked{}`, HEEx renders it `••••` through the shared `Phoenix.HTML.Safe` impl —
  the board has no "show plaintext" branch. The column `label` and `count` are ALWAYS a
  non-vaulted facet: `group_by!/3` REFUSES a vault-routed group field
  (`Samen.Web.Reads.MaskedGroupKeyError`), so no plaintext or vault token can leak through a
  header or count (INV-1).

  ## No-JS floor (progressive enhancement, ADR-042/T113)

  Columns, cards, and counts are always in the server-rendered DOM — the board is NOT
  JS-only. The `has_more` state renders a legible `+N more` text (server-computed from the
  exact `count`) REGARDLESS of JS; the `load_more_event` phx-click button is an enhancement
  layered on top of that text, not a replacement for it. A no-JS client still sees every
  column, its loaded cards, its exact total, and how many remain.

  ## Load-more (per-column keyset pagination)

  When `:load_more_event` is set, a capped column renders a `phx-click` button carrying the
  column key in `phx-value-key` (a bare string; `""` = the uncategorized/`nil`-key column).
  The owning LiveView handles the event by reading the NEXT keyset page for that ONE column
  (via its reads layer, `group.next_cursor` on the `%Board.Group{}`) and appending — the
  board struct itself is never mutated here; the component is pure render.
  """
  use Phoenix.Component

  @doc """
  Render a `%Samen.Web.Board{}` as grouped columns.

    * `:board` (required) — a `%Samen.Web.Board{}` (`Samen.Web.Reads.group_by!/3` output).
    * `:id` — the DOM id of the board container (default `"board"`); each column id is
      derived from it + a slug of the group key.
    * `:load_more_event` — when set, a capped (`has_more`) column renders a `phx-click`
      "Load more" button carrying `phx-value-key` (the column key as a string). When `nil`
      (default), only the legible `+N more` text is shown (a read-only board).
    * `:empty_col_text` — placeholder for a column with zero loaded cards (default `"—"`).
    * `:card` (required slot, `:let={row}`) — renders ONE card from a group row.
    * `:col_header` (slot, `:let={group}`) — OPTIONAL custom column header. When omitted,
      the default header renders the group `label` + a count pill.
  """
  attr :id, :string, default: "board"
  attr :board, :any, required: true, doc: "a %Samen.Web.Board{}"
  attr :load_more_event, :string, default: nil
  attr :empty_col_text, :string, default: "—"
  slot :card, required: true, doc: "renders one card from a row (:let={row})"
  slot :col_header, doc: "optional custom column header (:let={group})"

  def board(assigns) do
    ~H"""
    <div id={@id} class="board" role="list">
      <%= for group <- @board.groups do %>
        <section class="bcol" id={"#{@id}-col-#{col_slug(group.key)}"} role="listitem">
          <header class="bcol-h">
            <%= if @col_header != [] do %>
              {render_slot(@col_header, group)}
            <% else %>
              <h3 class="bcol-t">{group.label}</h3>
              <span :if={group.count} class="bcol-n">{group.count}</span>
            <% end %>
          </header>

          <div class="bcol-body">
            <article :for={row <- group.rows} class="bcard">
              {render_slot(@card, row)}
            </article>
            <p :if={group.rows == []} class="bcol-empty">{@empty_col_text}</p>
          </div>

          <footer :if={group.has_more} class="bcol-more">
            <span class="bcol-more-n">+{remaining(group)} more</span>
            <button
              :if={@load_more_event}
              type="button"
              class="btn bcol-more-btn"
              phx-click={@load_more_event}
              phx-value-key={col_key(group.key)}
            >
              Load more
            </button>
          </footer>
        </section>
      <% end %>
    </div>
    """
  end

  # The exact count of rows still un-loaded in a capped column (server-computed from the
  # aggregate `count`, so it survives with JS off). Falls back to "some" if count is nil.
  defp remaining(%{count: count, rows: rows}) when is_integer(count),
    do: max(count - length(rows), 0)

  defp remaining(_), do: "some"

  # A DOM-safe slug for the column element id (nil key = the uncategorized column).
  defp col_slug(nil), do: "none"
  defp col_slug(key), do: key |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

  # The raw column key for phx-value-key (a bare string; "" = the nil-key column). The
  # LiveView maps "" back to nil when reading the next page for that column.
  defp col_key(nil), do: ""
  defp col_key(key), do: to_string(key)
end
