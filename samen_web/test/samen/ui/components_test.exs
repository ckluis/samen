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

  # ==========================================================================
  # ADR-011 §6.2 — the activity timeline component (pure, host-agnostic)
  # ==========================================================================

  test "timeline/1 renders typed entries with subject, body, status, and the who/when line" do
    entries = [
      %{
        id: "a1",
        type: :call,
        subject: "Check call — ETA confirmed",
        body: "Driver on schedule, delivering 14:00.",
        status: :completed,
        at: ~U[2026-07-08 13:00:00Z],
        who: "dispatch"
      },
      %{id: "a2", type: :note, subject: "Left voicemail", body: nil, status: :pending, at: nil, who: nil}
    ]

    html = render_component(&Samen.UI.timeline/1, %{entries: entries, composer: []})

    assert html =~ ~s(class="tl-rail")
    assert html =~ "Check call — ETA confirmed"
    assert html =~ "Driver on schedule"
    assert html =~ "Left voicemail"
    # Type label + status pill.
    assert html =~ "Call"
    assert html =~ ~s(class="pill ok")
    # who/when line.
    assert html =~ "dispatch"
    assert html =~ "2026-07-08 13:00 UTC"
    # Per-entry id from the entry.
    assert html =~ "tl-entry-a1"
  end

  test "timeline/1 renders the empty state when there are no entries" do
    html = render_component(&Samen.UI.timeline/1, %{entries: [], empty: "Nothing here.", composer: []})

    assert html =~ ~s(class="tl-empty")
    assert html =~ "Nothing here."
    refute html =~ ~s(class="tl-rail")
  end

  test "timeline/1 slots a composer above the rail without knowing about writes" do
    html =
      render_component(&Samen.UI.timeline/1, %{
        entries: [],
        composer: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<form id="the-composer"></form>)) end}]
      })

    assert html =~ ~s(class="tl-composer")
    assert html =~ ~s(id="the-composer")
  end

  test "timeline/1 renders a %Masked{} entry field verbatim (•••• — no unmasking)" do
    masked = %Samen.Masked{token: "vt_ignored", label: :pii_name}
    entries = [%{id: "m1", type: :note, subject: masked, body: nil, status: :completed, at: nil, who: nil}]
    html = render_component(&Samen.UI.timeline/1, %{entries: entries, composer: []})

    assert html =~ "••••"
  end

  test "lifecycle_pill/1 renders a known stage and nothing for an unknown/nil stage" do
    assert render_component(&Samen.UI.lifecycle_pill/1, %{stage: "lead"}) =~ "Lead"
    assert render_component(&Samen.UI.lifecycle_pill/1, %{stage: "customer"}) =~ ~s(class="pill ok")
    # Unknown/nil renders no pill.
    refute render_component(&Samen.UI.lifecycle_pill/1, %{stage: "bogus"}) =~ ~s(class="pill)
    refute render_component(&Samen.UI.lifecycle_pill/1, %{stage: nil}) =~ ~s(class="pill)
  end

  test "social_links/1 renders icon-links for known flat bag keys and nothing when absent" do
    custom = %{"social_linkedin" => "https://linkedin.com/in/sofia", "social_github" => "https://github.com/sofia"}
    html = render_component(&Samen.UI.social_links/1, %{custom: custom})

    assert html =~ "https://linkedin.com/in/sofia"
    assert html =~ "https://github.com/sofia"
    assert html =~ ~s(class="social-linkedin")

    # No bag → no links element.
    refute render_component(&Samen.UI.social_links/1, %{custom: nil}) =~ ~s(class="social-links")
  end
end
