defmodule Samen.UI.GalleryComponentTest do
  @moduledoc """
  Unit proofs for the GENERIC card-grid renderer (`Samen.UI.gallery/1`, T54/WS-G) — the reusable
  renderer the CRM Contacts gallery (and any resource) consumes. These test the FRAMEWORK
  component in isolation, against a hand-built `%Samen.Web.Page{}`:

    * GRID — each item renders one `.gcard` (keyed by id) through the `:card` slot; an optional
      `:media` slot renders a leading facet; every card is in the server-rendered DOM (no-JS).
    * NO-JS PAGINATION — prev/next are real `<a href>` links when hrefs are given (the `?after=`
      keyset floor), inert spans otherwise; the page-size is shown.
    * LOAD MORE — the `load_more_event` phx-click button appears only when set AND `has_more`
      (a JS enhancement layered on top of the no-JS links).
    * EMPTY — a zero-item page renders the default empty state (or the `:empty` slot).
    * MASKING — a dumb renderer: a `%Samen.Masked{}` card field renders `••••`, never plaintext.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Page

  defp card_slot do
    [%{inner_block: fn _c, item -> Phoenix.HTML.raw(~s(<b class="nm">#{item.name}</b>)) end}]
  end

  defp media_slot do
    [%{inner_block: fn _c, item -> Phoenix.HTML.raw(~s(<i class="mm">#{item.mono}</i>)) end}]
  end

  defp sample_page(opts \\ []) do
    %Page{
      items: [
        %{id: "a1", name: "Ada Lovelace", mono: "AL"},
        %{id: "b2", name: "Bell Labs", mono: "BL"}
      ],
      page_size: 12,
      has_more: Keyword.get(opts, :has_more, true)
    }
  end

  defp render(assigns) do
    render_component(
      &Samen.UI.gallery/1,
      Map.merge(%{id: "g", page: sample_page(), card: card_slot()}, assigns)
    )
  end

  test "GRID: each item is a .gcard keyed by id, rendered through the :card slot" do
    html = render(%{})

    assert html =~ ~s(class="gallery-grid")
    assert html =~ ~s(id="g-card-a1")
    assert html =~ ~s(id="g-card-b2")
    assert html =~ "Ada Lovelace"
    assert html =~ "Bell Labs"
  end

  test "MEDIA: the optional :media slot renders a leading facet per card" do
    html = render(%{media: media_slot()})
    assert html =~ ~s(class="gcard-media")
    assert html =~ ~s(<i class="mm">AL</i>)
  end

  test "NO-JS PAGINATION: prev/next are real links with hrefs, inert spans otherwise; page size shown" do
    linked = render(%{prev_href: "?", next_href: "?after=b2"})
    assert linked =~ ~s(<a href="?after=b2")
    assert linked =~ "Next ›"
    assert linked =~ "page size 12"

    inert = render(%{prev_href: nil, next_href: nil})
    assert inert =~ "gallery-page-off"
  end

  test "LOAD MORE: the phx-click button appears only when the event is set AND has_more" do
    with_more = render(%{load_more_event: "load_more"})
    assert with_more =~ ~s(phx-click="load_more")
    assert with_more =~ "Load more"

    # No button when the page has no more items, even with the event wired.
    no_more = render(%{load_more_event: "load_more", page: sample_page(has_more: false)})
    refute no_more =~ ~s(phx-click="load_more")

    # No button when the event is absent (no-JS read-only gallery).
    plain = render(%{})
    refute plain =~ "Load more"
  end

  test "EMPTY: a zero-item page renders the default empty state" do
    html = render(%{page: %Page{items: [], page_size: 12}, empty_text: "Nothing here"})
    assert html =~ "Nothing here"
    # No grid when empty.
    refute html =~ "gallery-grid"
  end

  test "MASKING: a %Samen.Masked{} card field renders ••••, never plaintext, via HTML.Safe" do
    page = %Page{items: [%{id: "m1", secret: %Samen.Masked{token: "vt_secret_777", label: :secret}}], page_size: 12}
    slot = [%{inner_block: fn _c, item -> item.secret end}]

    html = render_component(&Samen.UI.gallery/1, %{id: "g", page: page, card: slot})

    assert html =~ "••••"
    refute html =~ "vt_"
  end
end
