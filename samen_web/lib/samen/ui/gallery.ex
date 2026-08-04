defmodule Samen.UI.Gallery do
  @moduledoc """
  The GENERIC card-grid / gallery view — the framework renderer for a `%Samen.Web.Page{}`
  (the value `Samen.Web.Reads.page!/3` returns) laid out as a RESPONSIVE GRID of cards rather
  than table rows. The visual sibling of `Samen.UI.list_view/1`: `list_view` renders one keyset
  window of a flat list as a table; `gallery` renders the SAME bounded `%Page{}` as a card grid,
  optionally with a per-card MEDIA/thumbnail facet. It is framework-level and holds NO vertical
  logic — it is parameterized by the CARD RENDERER (the required `:card` slot, `:let={item}`) and
  an optional `:media` slot, so the CRM Contacts gallery (G5, first client), a Files gallery, or
  any resource reuses it at ≈0 authored LOC. The vertical part (which resource, which card
  fields) is thin wiring in the calling LiveView.

  ## Keyset pagination (bounded — reuses `page!/3`)

  The grid renders exactly one `%Page{}` — a keyset-bounded window (`limit(page_size + 1)`), never
  the whole set. A 10k-row resource shows at most `page_size` cards. Pagination is BOTH:

    * a no-JS floor — real `<a href>` prev/next links (`prev_href`/`next_href`) carrying a
      serializable `?after=<id>` keyset cursor (a non-PII opaque uuid — the grid sorts by `:id`),
      so a JS-off client pages by ordinary GET; and
    * a progressive enhancement — an optional `phx-click` "Load more" button (`load_more_event`)
      the owning LiveView handles by APPENDING the next keyset page.

  ## Masking posture (dumb renderer, same as the rest of the kit)

  The gallery never inspects, coerces, or stringifies a card's field value: each card (and its
  media) is whatever the `:card`/`:media` slot renders from an item the CALLER already
  plane-resolved through `Samen.Api.PiiResolution` (exactly like `list_view/1`). A
  `%Samen.Masked{}` field renders `••••` through the shared `Phoenix.HTML.Safe` impl — the
  gallery has no "show plaintext" branch. Cards are keyed by `id` only (a non-PII opaque uuid).

  ## No-JS floor (progressive enhancement, ADR-042/T113)

  Every card (and its media, count, page-size) is present in the server-rendered DOM — the
  gallery is NOT JS-only. Prev/next are real links; the `load_more_event` button is layered on
  top, not a replacement. A no-JS client sees the full page of cards and pages by GET.
  """
  use Phoenix.Component

  import Samen.UI.Feedback, only: [empty_state: 1]

  @doc """
  Render a `%Samen.Web.Page{}` as a responsive card grid.

    * `:page` (required) — a `%Samen.Web.Page{}` (`Samen.Web.Reads.page!/3` output).
    * `:id` — the DOM id of the grid container (default `"gallery"`).
    * `:prev_href` / `:next_href` — real navigation URLs (the no-JS floor; the `?after=` keyset
      cursor). When `nil` the control renders disabled/inert.
    * `:load_more_event` — when set, renders a `phx-click` "Load more" button (a JS enhancement
      that APPENDS the next keyset page). When `nil` (default), only the prev/next links show.
    * `:empty_text` / `:empty_icon` / `:empty_body` — forwarded to the default `empty_state/1`
      when the page has zero items (the `:empty` slot overrides it).
    * `:card` (required slot, `:let={item}`) — renders ONE card's body from a page item.
    * `:media` (optional slot, `:let={item}`) — renders a card's leading media/thumbnail facet.
    * `:empty` (optional slot) — replaces the default empty state.
  """
  attr :id, :string, default: "gallery"
  attr :page, :any, required: true, doc: "a %Samen.Web.Page{}"
  attr :prev_href, :string, default: nil
  attr :next_href, :string, default: nil
  attr :load_more_event, :string, default: nil
  attr :empty_text, :string, default: "Nothing here yet."
  attr :empty_icon, :string, default: nil
  attr :empty_body, :string, default: nil
  slot :card, required: true, doc: "renders one card's body from a page item (:let={item})"
  slot :media, doc: "optional leading media/thumbnail facet for a card (:let={item})"
  slot :empty, doc: "optional replacement for the default empty state"

  def gallery(assigns) do
    ~H"""
    <div class="gallery" id={@id}>
      <%= if @page.items == [] do %>
        <%= if @empty != [] do %>
          {render_slot(@empty)}
        <% else %>
          <.empty_state class="gallery-empty" title={@empty_text} body={@empty_body} icon={@empty_icon} />
        <% end %>
      <% else %>
        <div class="gallery-grid" role="list">
          <article
            :for={item <- @page.items}
            class="gcard"
            role="listitem"
            id={"#{@id}-card-#{Map.get(item, :id)}"}
          >
            <div :if={@media != []} class="gcard-media">{render_slot(@media, item)}</div>
            <div class="gcard-body">{render_slot(@card, item)}</div>
          </article>
        </div>

        <div class="gallery-footer" role="navigation" aria-label="Gallery pages">
          <.page_link href={@prev_href} label="Previous page" text="‹ Prev" id={"#{@id}-prev"} />
          <.page_link href={@next_href} label="Next page" text="Next ›" id={"#{@id}-next"} />
          <button
            :if={@load_more_event && @page.has_more}
            type="button"
            class="btn gallery-more-btn"
            phx-click={@load_more_event}
          >
            Load more
          </button>
          <span class="gallery-page-size">page size {@page.page_size}</span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :href, :string, default: nil
  attr :label, :string, required: true
  attr :text, :string, required: true
  attr :id, :string, required: true

  defp page_link(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <a href={@href} class="btn gallery-page-link" id={@id} rel="nofollow" aria-label={@label}>{@text}</a>
    """
  end

  defp page_link(assigns) do
    ~H"""
    <span class="btn gallery-page-link gallery-page-off" id={@id} aria-disabled="true">{@text}</span>
    """
  end
end
