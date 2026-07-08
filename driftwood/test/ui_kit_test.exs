defmodule Driftwood.UIKitTest do
  @moduledoc """
  ADR-008 — the Samen UI kit + its `/ui-kit` preview page.

  Two guarantees:

    1. The preview page renders 200 with EVERY component present (app shell, sidebar,
       nav group/item, topbar, button, tabs, data table, pill × 5 variants, progress,
       metric, mask-bar, token-blind bar).
    2. The MASKING INVARIANT — the kit is a dumb renderer of already plane-resolved
       values. A cell/pill handed a `%Samen.Masked{}` renders `••••` through
       `Phoenix.HTML.Safe` and NEVER the vault token. There is no plaintext-bypass path.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import DriftwoodWeb.UIKit

  # Render a LiveView module (same harness the repo's web_red_paths_test uses).
  defp render_live(mod, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> mod.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # Render a bare HEEx snippet (for exercising a component in isolation).
  defp render_heex(%Phoenix.LiveView.Rendered{} = rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  describe "the /ui-kit preview page (DriftwoodWeb.UIKitLive)" do
    setup do
      html = render_live(DriftwoodWeb.UIKitLive, DriftwoodWeb.UIKitLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{}) |> elem(1) |> Map.fetch!(:assigns))
      {:ok, html: html}
    end

    test "renders the app shell, sidebar, topbar", %{html: html} do
      assert html =~ ~s(class="app")
      assert html =~ ~s(class="side")
      assert html =~ ~s(class="main")
      assert html =~ ~s(class="ws")
      assert html =~ ~s(class="grp")
      assert html =~ ~s(class="nav")
      assert html =~ ~s(class="top")
      assert html =~ ~s(class="crumb")
      assert html =~ "<h1>Component preview</h1>"
    end

    test "renders buttons (default + primary), tabs, and metric cards", %{html: html} do
      assert html =~ ~s(class="btn")
      assert html =~ ~s(class="btn primary")
      assert html =~ ~s(class="tabs")
      assert html =~ ~s(class="metrics")
      assert html =~ ~s(class="metric")
      assert html =~ ~s(class="spark")
      assert html =~ ~s(class="delta up") or html =~ "delta up"
      assert html =~ ~s(class="delta down") or html =~ "delta down"
    end

    test "renders the data table with all five pill variants and progress bars", %{html: html} do
      assert html =~ ~s(class="card")
      assert html =~ "<table>"
      assert html =~ ~s(class="pill ok)
      assert html =~ ~s(class="pill warn)
      assert html =~ ~s(class="pill bad)
      assert html =~ ~s(class="pill info)
      assert html =~ ~s(class="pill mut)
      assert html =~ ~s(class="prog")
    end

    test "renders BOTH banners (mask-bar + token-blind bar)", %{html: html} do
      assert html =~ ~s(class="mask-bar")
      assert html =~ ~s(class="tb-bar")
      assert html =~ "Masked impersonation."
      assert html =~ "Token-blind aggregate plane."
    end

    test "MASKING INVARIANT: the masked cell renders •••• and NEVER the vault token", %{html: html} do
      # The mask IS present (the %Masked{} rendered through Phoenix.HTML.Safe).
      assert html =~ "••••"
      # The masked row is present (non-vacuous — the page is not empty).
      assert html =~ ~s(id="row-masked")
      # The vault token NEVER leaks into the rendered page.
      refute html =~ "vault:preview-token"
      refute html =~ "preview-token"
    end
  end

  describe "the kit is a dumb renderer — a %Masked{} handed to a component shows ••••" do
    test "pill/1 renders •••• when its inner block is a %Masked{}, never the token" do
      masked = Samen.Masked.new("vault:tok-abc", :cdl_number)
      assigns = %{m: masked}
      html = render_heex(~H"""
      <.pill variant="mut">{@m}</.pill>
      """)

      assert html =~ "••••"
      refute html =~ "vault:tok-abc"
      refute html =~ "tok-abc"
    end

    test "a data_table cell handed a %Masked{} shows •••• (no bypass), token never leaks" do
      masked = Samen.Masked.new("vault:tok-xyz", :full_name)
      assigns = %{m: masked}
      html = render_heex(~H"""
      <.data_table>
        <:head><th>Driver</th></:head>
        <tr><td>{@m}</td></tr>
      </.data_table>
      """)

      assert html =~ "••••"
      refute html =~ "vault:tok-xyz"
      refute html =~ "tok-xyz"
    end

    test "progress/1 renders a %Masked{} label as ••••, never the token" do
      masked = Samen.Masked.new("vault:tok-lbl", :amount)
      assigns = %{m: masked}
      html = render_heex(~H"""
      <.progress value={50} label={@m} />
      """)

      assert html =~ "••••"
      refute html =~ "vault:tok-lbl"
    end
  end

  describe "component assign behavior (content is not hardcoded)" do
    test "button/1 passes through :rest attrs and renders its label + icon slot" do
      assigns = %{}
      html = render_heex(~H"""
      <.button variant="primary" phx-click="go">
        <:icon><svg id="ico"></svg></:icon>
        Save changes
      </.button>
      """)

      assert html =~ "Save changes"
      assert html =~ ~s(phx-click="go")
      assert html =~ ~s(id="ico")
      assert html =~ "btn primary"
    end

    test "nav_item/1 renders active state, count, and icon from assigns" do
      assigns = %{}
      html = render_heex(~H"""
      <.nav_item label="Tenants" active count="42">
        <:icon><svg id="ni"></svg></:icon>
      </.nav_item>
      """)

      assert html =~ "Tenants"
      assert html =~ ~s(class="on")
      assert html =~ ~s(class="cnt")
      assert html =~ "42"
      assert html =~ ~s(id="ni")
    end

    test "topbar/1 joins crumbs with a separator and renders the title from assigns" do
      assigns = %{}
      html = render_heex(~H"""
      <.topbar title="Driver roster" crumbs={["Operator", "Impersonation", "Drivers"]} />
      """)

      assert html =~ "<h1>Driver roster</h1>"
      assert html =~ "Operator"
      assert html =~ "Drivers"
      assert html =~ ~s(class="sep")
    end
  end
end
