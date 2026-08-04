defmodule Samen.Web.CRMCalendarTest do
  @moduledoc """
  End-to-end proofs for the G2 CALENDAR view (T52) — the CRM opportunity calendar as the
  FIRST client of the generic `Samen.Web.Reads.calendar_by_day!/3` rendered through
  `Samen.UI.calendar/1`. Each proof is anti-tautology (a positive control anchors every guard):

    * GRID/EVENTS/COUNTS — a seeded month renders the month grid (weekday header + day cells),
      an opportunity event in its close-date cell, and a per-day count — all through the real
      LiveView, all in the server-rendered DOM (the no-JS floor).
    * ORG-SCOPE (sabotage-refutable) — a 2-org seed: org B's opportunities NEVER appear on
      org A's calendar (and DO appear on org B's own — the refutation control).
    * NO-JS NAVIGATION — prev/next months are real `<a href="?month=YYYY-MM">` links, and
      driving `handle_params/3` with a month param actually re-windows the read (an event in
      another month appears only when navigated to — proving the param, not JS, drives it).
    * MASKING POSTURE — opportunities are NON-PII and the date facet `:close_date` is
      non-vaulted, so NO event field masks and no per-plane proof is required (documented; a
      real vaulted sibling field anchors the non-vacuity of the "non-vaulted" claim).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.UI.Calendar
  alias Samen.Web.CRM.CalendarLive
  alias Samen.Web.Mount

  @opportunity Samen.WebTest.Crm.Opportunity
  @person Samen.WebTest.Crm.Person

  defp seed_opp(org_id, name, close_date) do
    @opportunity
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        name: name,
        value: Samen.Type.Money.from_cents(250_000, :USD),
        status: :open,
        close_date: close_date
      },
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp month_param(%Date{year: y, month: m}),
    do: "#{y}-#{String.pad_leading(to_string(m), 2, "0")}"

  # Drive the LiveView's real handle_params (the no-JS month-nav path) and render to HTML.
  defp render_params(mount, org_id, seed_month, params) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(samen_mount: mount, samen_acting_as: false, org_id: org_id, month: seed_month)

    {:noreply, socket} =
      CalendarLive.handle_params(params, "http://localhost/crm/calendar", socket)

    render_html(CalendarLive, socket.assigns)
  end

  # -- GRID / EVENTS / COUNTS --------------------------------------------------

  test "renders the month grid with an event in its close-date cell and a per-day count" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    # Seed in the CURRENT month (the default render window) so render_live shows the events.
    bom = Date.beginning_of_month(Date.utc_today())
    for i <- 1..3, do: seed_opp(org_id, "CAL-OPP-#{i}", bom)

    html = render_live(CalendarLive, mount, [org_id])

    # The month grid, its weekday header row, and the current month label are all present …
    assert html =~ ~s(class="cal")
    assert html =~ ~s(class="cal-wd")
    assert html =~ Calendar.month_label(bom)
    # … the events render in the correct day cell (the cell id is the ISO close date) …
    assert html =~ "crm-cal-cell-#{Date.to_iso8601(bom)}"
    assert html =~ "CAL-OPP-1"
    assert html =~ "CAL-OPP-3"
    # … and the per-day count is in the server-rendered DOM (the no-JS floor).
    assert html =~ ~s(class="cal-cell-n">3<)
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B's opportunities NEVER appear on org A's calendar" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    bom = Date.beginning_of_month(Date.utc_today())

    for i <- 1..2, do: seed_opp(org_a, "A-OPP-#{i}", bom)
    for i <- 1..4, do: seed_opp(org_b, "B-OPP-#{i}", bom)

    a_html = render_live(CalendarLive, mount, [org_a])
    b_html = render_live(CalendarLive, mount, [org_b])

    # Org A's calendar shows ONLY org A events; org B's are absent …
    assert a_html =~ "A-OPP-1"
    refute a_html =~ "B-OPP-1"
    refute a_html =~ "B-OPP-4"

    # … and the refutation control: org B's events DO appear on org B's OWN calendar (so the
    # absence above is real org-scoping, not a seed that never rendered anywhere).
    assert b_html =~ "B-OPP-1"
    refute b_html =~ "A-OPP-1"

    # Reads-level cross-check: every event on org A's calendar is org A's.
    scope_a = Mount.scope(mount, org_a)
    %{board: board} = Samen.Web.CRM.Reads.opportunity_calendar(mount, scope_a, bom)
    a_ids = board.groups |> Enum.flat_map(& &1.rows) |> MapSet.new(& &1.id)

    b_ids =
      @opportunity
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: Mount.scope(mount, org_b))
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 4
    assert MapSet.disjoint?(a_ids, b_ids)
  end

  # -- NO-JS NAVIGATION --------------------------------------------------------

  test "NO-JS NAV: prev/next are real month links and a ?month= param re-windows the read" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    today_first = Date.beginning_of_month(Date.utc_today())

    # An event in the PREVIOUS month — outside the default (current-month) window.
    prev = Calendar.prev_month(today_first)
    seed_opp(org_id, "PREV-MONTH-OPP", prev)

    # Default render (current month): the previous-month event is ABSENT …
    default_html = render_live(CalendarLive, mount, [org_id])
    refute default_html =~ "PREV-MONTH-OPP"
    # … but the prev/next navigation are REAL links carrying a ?month= param (no JS needed).
    # (HEEx escapes `&` → `&amp;` inside the href attribute, so match the param, not the raw &.)
    assert default_html =~ ~s(<a href="?org=#{org_id})
    assert default_html =~ "month=#{month_param(prev)}"
    assert default_html =~ "month=#{month_param(Calendar.next_month(today_first))}"
    assert default_html =~ ~s(class="cal-nav")

    # Navigating to that month via the PARAM (handle_params, not JS) surfaces the event —
    # proving the ?month= param actually drives the window, so a JS-off client can navigate.
    nav_html = render_params(mount, org_id, today_first, %{"org" => org_id, "month" => month_param(prev)})
    assert nav_html =~ "PREV-MONTH-OPP"
    assert nav_html =~ Calendar.month_label(prev)
  end

  test "NO-JS NAV: a hostile/garbage ?month= is parsed fail-safe, never a crash" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    today_first = Date.beginning_of_month(Date.utc_today())

    # A garbage month param must NOT crash the mount — it falls back to the current month.
    html = render_params(mount, org_id, today_first, %{"org" => org_id, "month" => "not-a-month"})
    assert html =~ Calendar.month_label(today_first)
  end

  # -- MASKING POSTURE ---------------------------------------------------------

  test "MASKING POSTURE: no event field is vault-routed, so no per-plane proof is required" do
    # The date facet and every rendered event field are NON-vaulted …
    refute Samen.Pii.Info.vault_routed?(@opportunity, :close_date)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :name)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :value)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :status)
    # … anchored against a REAL vaulted field on a sibling CRM resource, so "non-vaulted" is a
    # live discriminator, not a predicate that returns false for everything.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
  end
end
