defmodule Driftwood.UiSidebarTest do
  @moduledoc """
  ADR-009 — the "freight 20% + inherited 80%" sidebar, AFTER the rewire.

  The UI kit itself (`Samen.UI`) + its `/ui-kit` living catalog + the deep masking-invariant
  unit tests now live in `samen_web` (`ui/components_test.exs`, `ui/ui_masking_test.exs`) —
  the coverage moved WITH the code to the framework. What stays a DRIFTWOOD concern is how
  Driftwood ASSEMBLES its sidebar: the freight "Operations" 20% is passed as the framework
  `Samen.UI.module_nav`'s `:extra` slot, while the inherited CRM/Billing/Support 80% comes
  from the framework component. This test renders the real `DriftwoodWeb.BrokerLive` and
  asserts both halves are legible + every inherited link resolves — the sidebar integration
  the driftwood-local `DriftwoodWeb.UIKit.module_nav` used to own.
  """
  use ExUnit.Case, async: true

  @org "b1112d00-0000-4000-8000-000000000001"

  defp broker_html do
    assigns = %{
      no_org: false,
      org_id: @org,
      panel: "dashboard",
      summary: nil,
      loads: [],
      drivers: [],
      settlements: [],
      # T148 — the "New load" create-flow assigns the render now reads.
      show_new: false,
      new_load_form: nil,
      load_error: nil,
      __changed__: %{}
    }

    DriftwoodWeb.BrokerLive.render(assigns)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "the broker sidebar renders ALL FOUR groups (freight Operations 20% + inherited 80%)" do
    html = broker_html()

    # The framework app shell + sidebar chrome is present (served by Samen.UI now).
    assert html =~ ~s(class="app")
    assert html =~ ~s(class="side")
    assert html =~ ~s(class="grp")

    # The freight 20% (Driftwood's OWN nav, passed via the module_nav :extra slot).
    assert html =~ "Operations"
    # The inherited 80% (framework Samen.UI.module_nav groups).
    assert html =~ "CRM"
    assert html =~ "Billing"
    assert html =~ "Support"
  end

  test "every inherited module is reachable via a resolvable href (no dead links)" do
    html = broker_html()

    # Operations (freight vertical, from the :extra slot) — `&` HTML-escaped to `&amp;`.
    assert html =~ ~s(href="/broker?panel=dashboard&amp;org=#{@org}")
    assert html =~ ~s(href="/broker?panel=loads&amp;org=#{@org}")
    assert html =~ ~s(href="/broker?panel=roster&amp;org=#{@org}")
    assert html =~ ~s(href="/broker?panel=settlements&amp;org=#{@org}")

    # CRM (framework)
    assert html =~ ~s(href="/crm/companies?org=#{@org}")
    assert html =~ ~s(href="/crm/contacts?org=#{@org}")
    assert html =~ ~s(href="/crm/pipeline?org=#{@org}")

    # Billing (framework)
    assert html =~ ~s(href="/billing?org=#{@org}")
    assert html =~ ~s(href="/billing/invoices?org=#{@org}")
    assert html =~ ~s(href="/billing/plans?org=#{@org}")

    # Support (framework)
    assert html =~ ~s(href="/support?org=#{@org}")
  end

  test "on the broker console NO inherited nav item is highlighted (active: nil)" do
    html = broker_html()
    # The broker page is not a CRM/Billing/Support page, so module_nav gets active: nil.
    # Only the freight :extra group carries an active state (the dashboard panel).
    refute html =~ ~s(<a href="/crm/companies?org=#{@org}" class="on">)
    refute html =~ ~s(<a href="/billing?org=#{@org}" class="on">)
  end
end
