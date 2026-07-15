defmodule Samen.Web.LayoutsTest do
  @moduledoc """
  Unit tests for the shared root layout (WS-D D1.4, ADR-022). The extraction's guarantee:
  a host module that does `use Samen.Web.Layouts` gets a `root/1` rendering the same
  minimal shell the verticals hand-authored — viewport + CSRF meta, the samen_ui.css
  link from the samen_web dep's priv (ADR-009), the host's title, and `@inner_content`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  defmodule HostWeb.Layouts do
    use Samen.Web.Layouts
  end

  defmodule TitledWeb.Layouts do
    use Samen.Web.Layouts, title: "Titled — a product on Samen"
  end

  defp render_root(module) do
    render_component(&module.root/1,
      inner_content: {:safe, "<main>INNER</main>"}
    )
  end

  test "renders the minimal shell: doctype, viewport, csrf meta, samen_ui.css, inner content" do
    html = render_root(TitledWeb.Layouts)

    assert html =~ "<!DOCTYPE html>"
    assert html =~ ~s(<meta name="viewport" content="width=device-width, initial-scale=1")
    assert html =~ ~s(<meta name="csrf-token")
    assert html =~ ~s(<link rel="stylesheet" href="/assets/samen_ui.css")
    assert html =~ "<main>INNER</main>"
  end

  test "explicit :title wins" do
    assert render_root(TitledWeb.Layouts) =~ "<title>Titled — a product on Samen</title>"
  end

  test "title defaults to the host's top namespace with trailing Web stripped" do
    # The vertical shape: DriftwoodWeb.Layouts → "Driftwood".
    assert Samen.Web.Layouts.default_title(DriftwoodWeb.Layouts) == "Driftwood"
    # HostWeb.Layouts is nested under this test module, so its TOP namespace is "Samen".
    assert render_root(HostWeb.Layouts) =~ "<title>Samen</title>"
  end
end
