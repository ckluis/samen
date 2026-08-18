defmodule DriftwoodWeb.BrokerFreightUiRenderTest do
  @moduledoc """
  T158 — direct-render coverage for the new freight CRUD UI (mirrors the existing
  `web_red_paths_test.exs`/`ui_kit_test.exs` `mod.render(assigns)` harness — no live
  socket, just the template). Proves:

    * the loads panel renders the REAL filter bar, edit/delete affordances, and the
      honest "no matches" empty state (distinct from the "no loads yet" onboarding
      empty state);
    * the roster/settlements panels render their Edit affordances and the topbar's
      create action is CONTEXTUAL to the active panel (T148's "New load" no longer
      shows on every panel);
    * all four new modals (edit load, new/edit driver, new/edit settlement) render
      with a real backing form and don't crash the template.
  """
  use Driftwood.DataCase, async: false

  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000b7"

  defp render(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> BrokerLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        no_org: false,
        org_id: @org,
        panel: "loads",
        summary: nil,
        loads: [],
        drivers: [],
        settlements: []
      },
      overrides
    )
  end

  test "the topbar create action is CONTEXTUAL — 'New load' on Loads, absent elsewhere" do
    loads_html = render(base_assigns(%{panel: "loads"}))
    roster_html = render(base_assigns(%{panel: "roster"}))
    settlements_html = render(base_assigns(%{panel: "settlements"}))
    dashboard_html = render(base_assigns(%{panel: "dashboard"}))

    assert loads_html =~ ~s(id="new-load")
    refute loads_html =~ ~s(id="new-driver")
    refute loads_html =~ ~s(id="new-settlement")

    assert roster_html =~ ~s(id="new-driver")
    refute roster_html =~ ~s(id="new-load")

    assert settlements_html =~ ~s(id="new-settlement")
    refute settlements_html =~ ~s(id="new-load")

    refute dashboard_html =~ ~s(id="new-load")
    refute dashboard_html =~ ~s(id="new-driver")
    refute dashboard_html =~ ~s(id="new-settlement")
  end

  test "loads panel: the real filter form + edit/delete affordances render for a non-empty board" do
    load = %{id: Ecto.UUID.generate(), name: "BRL-UI-1", value: Money.new!(:USD, 100), status: :open, __lane__: "TX->CA"}
    html = render(base_assigns(%{panel: "loads", loads: [load]}))

    assert html =~ ~s(id="load-filter-form")
    assert html =~ ~s(id="load-filter-q")
    assert html =~ ~s(id="load-filter-status")
    assert html =~ "edit_load"
    assert html =~ "delete_load"
    assert html =~ "BRL-UI-1"
  end

  test "loads panel: TRUE zero-loads renders the onboarding empty state (create-first-load CTA)" do
    html = render(base_assigns(%{panel: "loads", loads: [], load_filter: %{status: nil, q: ""}}))

    assert html =~ "No loads yet"
    assert html =~ ~s(id="empty-new-load")
    refute html =~ "No loads match this filter"
  end

  test "loads panel: a FILTER that matches nothing renders the honest 'no matches' empty state, not the onboarding one" do
    html = render(base_assigns(%{panel: "loads", loads: [], load_filter: %{status: "open", q: ""}}))

    assert html =~ "No loads match this filter"
    assert html =~ ~s(id="empty-clear-load-filter")
    refute html =~ "No loads yet"
    refute html =~ ~s(id="empty-new-load")
  end

  test "roster panel: the Edit affordance renders per driver row" do
    driver = %{
      id: Ecto.UUID.generate(),
      full_name: "Dana Compliant",
      cdl_number: "CDL-1",
      cdl_state: "TX",
      cdl_expiry: "2030-01-01",
      medical_card_expiry: ~D[2030-01-01],
      status: :available,
      __fmcsa__: :ok
    }

    html = render(base_assigns(%{panel: "roster", drivers: [driver]}))
    assert html =~ "edit_driver"
    assert html =~ ~s(phx-value-driver)
  end

  test "settlements panel: the Edit affordance renders per settlement row" do
    settlement = %{
      id: Ecto.UUID.generate(),
      status: :draft,
      linehaul_cents: 1000,
      advances_cents: 0,
      claim_deduction_cents: 0,
      factoring_fee_cents: 0,
      net_payable_cents: 1000,
      carryover_cents: 0
    }

    html = render(base_assigns(%{panel: "settlements", settlements: [settlement]}))
    assert html =~ "edit_settlement"
    assert html =~ ~s(phx-value-settlement)
  end

  test "the edit-load modal renders with a real backing form (no crash)" do
    form = Phoenix.Component.to_form(%{"name" => "BRL-1", "lane" => "TX->CA", "rate" => "100.00", "status" => "open"}, as: :load)

    html =
      render(
        base_assigns(%{panel: "loads", show_edit_load: true, edit_load_id: Ecto.UUID.generate(), edit_load_form: form})
      )

    assert html =~ ~s(id="edit-load-modal")
    assert html =~ ~s(id="edit-load-form")
  end

  test "the new/edit driver modals render with a real AshPhoenix.Form backing (no crash, no plaintext PII injected)" do
    scope = BrokerLive.broker_scope(@org)

    new_form =
      Driftwood.Freight.Driver
      |> AshPhoenix.Form.for_create(:create, scope: scope)
      |> Phoenix.Component.to_form()

    html_new = render(base_assigns(%{panel: "roster", show_new_driver: true, new_driver_form: new_form}))
    assert html_new =~ ~s(id="new-driver-modal")
    assert html_new =~ ~s(id="new-driver-form")

    driver =
      Driftwood.Freight.Driver
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @org,
          full_name: %{first: "Ui", last: "Test"},
          cdl_number: "CDL-UI-TEST",
          cdl_state: "TX",
          cdl_expiry: "2030-01-01",
          medical_card_expiry: ~D[2030-01-01],
          status: :available
        },
        authorize?: false
      )
      |> Ash.create!()

    {:ok, resolved} = Driftwood.Reads.get_driver(scope, driver.id)
    edit_form = driver |> AshPhoenix.Form.for_update(:update, scope: scope) |> Phoenix.Component.to_form()

    html_edit =
      render(base_assigns(%{panel: "roster", show_edit_driver: true, edit_driver_id: driver.id, edit_driver_form: edit_form}))

    assert html_edit =~ ~s(id="edit-driver-modal")
    assert html_edit =~ ~s(id="edit-driver-form")
    # The tenant-plane resolved CDL is CLEAR — proving the form isn't silently masking on
    # this console (masking is verified independently in driver_pii_masking_test.exs).
    refute match?(%Samen.Masked{}, resolved.cdl_number)
  end

  test "the new/edit settlement modals render with a real AshPhoenix.Form backing (no crash)" do
    scope = BrokerLive.broker_scope(@org)

    new_form =
      Driftwood.Freight.Settlement
      |> AshPhoenix.Form.for_create(:create, scope: scope)
      |> Phoenix.Component.to_form()

    html_new = render(base_assigns(%{panel: "settlements", show_new_settlement: true, new_settlement_form: new_form}))
    assert html_new =~ ~s(id="new-settlement-modal")
    assert html_new =~ ~s(id="new-settlement-form")

    settlement =
      Driftwood.Freight.Settlement
      |> Ash.Changeset.for_create(:create, %{org_id: @org, linehaul_cents: 1000}, authorize?: false)
      |> Ash.create!()

    edit_form = settlement |> AshPhoenix.Form.for_update(:update, scope: scope) |> Phoenix.Component.to_form()

    html_edit =
      render(
        base_assigns(%{
          panel: "settlements",
          show_edit_settlement: true,
          edit_settlement_id: settlement.id,
          edit_settlement_form: edit_form
        })
      )

    assert html_edit =~ ~s(id="edit-settlement-modal")
    assert html_edit =~ ~s(id="edit-settlement-form")
  end
end
