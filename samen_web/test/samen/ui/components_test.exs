defmodule Samen.UI.ComponentsTest do
  @moduledoc """
  Structural tests for the `Samen.UI` component kit: each component renders its expected
  markup/classes, and `module_nav/1` renders the INHERITED CRM/Billing/Support groups
  (framework) with the host `:extra` slot rendering the vertical's own 20% nav.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "app_shell/1 renders the two-pane grid" do
    html =
      render_component(&Samen.UI.app_shell/1, %{
        sidebar: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<nav>side</nav>") end}],
        inner_block: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<p>main</p>") end}]
      })

    assert html =~ ~s(class="app")
    assert html =~ ~s(<main class="main">)
  end

  test "button/1 primary variant renders the filled class" do
    html =
      render_component(&Samen.UI.button/1, %{
        variant: "primary",
        rest: %{},
        inner_block: [%{inner_block: fn _, _ -> "Save" end}]
      })

    assert html =~ ~s(class="btn primary")
    assert html =~ "Save"
  end

  test "pill/1 renders the variant class" do
    html =
      render_component(&Samen.UI.pill/1, %{
        variant: "ok",
        inner_block: [%{inner_block: fn _, _ -> "active" end}]
      })

    assert html =~ ~s(class="pill ok")
    assert html =~ "active"
  end

  test "module_nav/1 renders the inherited CRM/Billing/Support groups with org-threaded hrefs" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :crm_contacts,
        extra: []
      })

    # Inherited groups present.
    assert html =~ ">CRM<"
    assert html =~ ">Billing<"
    assert html =~ ">Support<"
    # Org threaded into hrefs.
    assert html =~ "/crm/contacts?org=ORG-123"
    assert html =~ "/billing?org=ORG-123"
    assert html =~ "/support?org=ORG-123"
    # Active item highlighted.
    assert html =~ ~s(class="on")
  end

  test "module_nav/1 honors custom path prefixes (host mounted at a different path)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "O1",
        active: nil,
        crm_path: "/customers",
        billing_path: "/money",
        support_path: "/help",
        extra: []
      })

    assert html =~ "/customers/companies?org=O1"
    assert html =~ "/money/invoices?org=O1"
    assert html =~ "/help?org=O1"
  end

  test "module_nav/1 renders the host's :extra vertical nav BEFORE the inherited groups" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "O1",
        active: nil,
        extra: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<div class="grp">Operations</div>)) end}]
      })

    assert html =~ "Operations"
    # Extra appears before CRM in the source order.
    assert :binary.match(html, "Operations") < :binary.match(html, ">CRM<")
  end

  test "token_blind_bar/1 and mask_bar/1 render their banners with the chip" do
    tb =
      render_component(&Samen.UI.token_blind_bar/1, %{
        chip: "no reveal path",
        inner_block: [%{inner_block: fn _, _ -> "blind" end}]
      })

    assert tb =~ ~s(class="tb-bar")
    assert tb =~ "no reveal path"

    mb =
      render_component(&Samen.UI.mask_bar/1, %{
        chip: "TTL 10:00",
        inner_block: [%{inner_block: fn _, _ -> "masked" end}]
      })

    assert mb =~ ~s(class="mask-bar")
    assert mb =~ "TTL 10:00"
  end
end
