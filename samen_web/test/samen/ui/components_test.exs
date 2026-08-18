defmodule Samen.UI.ComponentsTest do
  @moduledoc """
  Structural tests for the `Samen.UI` component kit: each component renders its expected
  markup/classes, and `module_nav/1` renders the INHERITED CRM/Billing/Support groups
  (framework) with the host `:extra` slot rendering the vertical's own 20% nav.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Mount

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

  test "module_nav/1 renders nav items for the CRM dashboard and mailbox surfaces (H3)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :crm_dashboard,
        extra: []
      })

    # Both shipped surfaces are reachable via nav, not just hand-typed URLs.
    assert html =~ "Dashboard"
    assert html =~ "Mailbox"
    assert html =~ "/crm/dashboard?org=ORG-123"
    assert html =~ "/crm/mailbox?org=ORG-123"
    # The active dashboard item is highlighted.
    assert html =~ ~s(href="/crm/dashboard?org=ORG-123" class="on")
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

  # PP-8 (Batch 3 NAV-REACHABILITY) — Settings (Profile / API keys / Security / Invitations)
  # was a total nav island: no item anywhere in `module_nav/1`, reachable only by
  # hand-typing `/settings?org=...`.
  test "module_nav/1 renders a Settings nav item pointing at the settings route (PP-8)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :settings,
        extra: []
      })

    assert html =~ "Settings"
    assert html =~ ~s(href="/settings?org=ORG-123" class="on")
  end

  # PP-9 (Batch 3 NAV-REACHABILITY) — same class of defect as PP-8: the shipped T118
  # workflow builder had no discoverable entry point anywhere in `module_nav/1`.
  test "module_nav/1 renders an Automation nav item pointing at the automation route (PP-9)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :automation,
        extra: []
      })

    assert html =~ "Automation"
    assert html =~ ~s(href="/automation?org=ORG-123" class="on")
  end

  # X1 (luminary pre-merge HIGH — ADR-045 §4.1) — a `mix samen.gen.app --modules …` app mounts
  # only a SUBSET of the inherited groups (its router mounts billing + notifications, plus the
  # selected `--modules`, and never CRM/Support/Marketing/Automation). `module_nav/1` must
  # render ONLY the mounted groups (`surfaces: [...]`) so it never emits a nav link to a route
  # the host never mounted — clicking one otherwise raises `Phoenix.Router.NoRouteError`. This
  # is the sabotage-flippable half of the X1 guard (the flagship probe proves it end-to-end
  # over real HTTP; this proves the filter at the component level in the `mix test` harness).
  test "module_nav/1 renders ONLY the mounted surfaces and omits dead-link groups (X1)" do
    # A generated `--modules settings` app: mounts billing + notifications (+ settings),
    # never CRM/Support/Marketing/Automation.
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: nil,
        surfaces: [:inbox, :billing, :settings],
        extra: []
      })

    # Mounted groups present...
    assert html =~ ">Inbox<"
    assert html =~ ">Billing<"
    assert html =~ ">Workspace<"
    assert html =~ ~s(href="/notifications?org=ORG-123")
    assert html =~ ~s(href="/settings?org=ORG-123")

    # ...unmounted groups OMITTED — no dead links to routes the router never mounts.
    refute html =~ ">CRM<"
    refute html =~ ">Support<"
    refute html =~ ">Marketing<"
    refute html =~ "/crm/companies"
    refute html =~ "/support?org="
    refute html =~ "/marketing/campaigns"
    refute html =~ "/automation?org="

    # Positive control (anti-tautology): with the default `:all`, every inherited group still
    # renders — a full vertical that mounts them all. Proves the refutes above are the FILTER
    # doing work, not a group that never renders.
    full = render_component(&Samen.UI.module_nav/1, %{org_id: "ORG-123", active: nil, extra: []})
    assert full =~ ">CRM<"
    assert full =~ ">Support<"
    assert full =~ ">Marketing<"
    assert full =~ "/crm/companies?org=ORG-123"
    assert full =~ "/automation?org=ORG-123"
  end

  # PP-10 (Batch 3 NAV-REACHABILITY) — `host_nav_extra/1` is the shared, DATA-driven way
  # a host's own vertical nav (e.g. driftwood's freight "Operations") renders identically
  # from every framework sidebar, instead of only the host's own bespoke page.
  describe "host_nav_extra/1 (PP-10)" do
    def nav_extra_data(org_id),
      do: %{label: "Operations", items: [%{label: "Dispatch board", href: "/broker?panel=dashboard&org=#{org_id}"}]}

    def malformed_nav_extra_data(_org_id), do: :not_a_group_map

    test "renders the host's :host_nav_extra mount-label DATA as a nav group" do
      mount =
        Mount.new(:crm, Samen.UI.ComponentsTest, Samen.WebTest.Repo,
          labels: %{host_nav_extra: {__MODULE__, :nav_extra_data, []}}
        )

      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})

      assert html =~ ">Operations<"
      assert html =~ "Dispatch board"
      assert html =~ ~s(href="/broker?panel=dashboard&amp;org=O1")
    end

    test "renders nothing when the mount carries no :host_nav_extra label" do
      mount = Mount.new(:crm, Samen.UI.ComponentsTest, Samen.WebTest.Repo)
      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})

      refute html =~ "Operations"
      refute html =~ ~s(class="grp")
    end

    test "fails SAFE (renders nothing, never raises) when the MFA returns a malformed shape" do
      mount =
        Mount.new(:crm, Samen.UI.ComponentsTest, Samen.WebTest.Repo,
          labels: %{host_nav_extra: {__MODULE__, :malformed_nav_extra_data, []}}
        )

      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})
      refute html =~ ~s(class="grp")
    end
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
