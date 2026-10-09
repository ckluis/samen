defmodule DriftwoodWeb.BrokerDriverFormRoundtripTest do
  @moduledoc """
  ADR-052 §2.1 item 3 (gate finding), on a VERTICAL: the broker console's new-driver modal
  renders the framework's `full_name_field/1` (vaulted `Samen.Type.FullName`) and the kit
  `form_field/1` for the vaulted scalar `cdl_number`. After a `validate`, both values are the
  redacting `%Samen.Pii.Plaintext{}`; the re-render must still echo the user's own pending
  input, or the browser resubmits a blank and the vault stores an erased name.

  Browser emulation: validate → render → SCRAPE the inputs the DOM now carries → submit
  exactly those → the roster resolves the typed values on the tenant plane.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000e3"

  defp render(assigns) do
    %{no_org: false, org_id: @org, panel: "roster", summary: nil, loads: [], drivers: [], settlements: []}
    |> Map.merge(assigns)
    |> Map.put(:__changed__, %{})
    |> BrokerLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp input_value(html, name_attr) do
    [tag] = Regex.run(~r/<input[^>]*#{Regex.escape(name_attr)}[^>]*>/, html)

    case Regex.run(~r/\bvalue="([^"]*)"/, tag) do
      [_, v] -> v
      nil -> ""
    end
  end

  test "new-driver modal: a failed validate re-renders the vaulted name + CDL; the resubmit stores them" do
    scope = BrokerLive.broker_scope(@org)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:org_id, @org)
      |> Phoenix.Component.assign(:show_new_driver, true)
      |> Phoenix.Component.assign(:new_driver_form, Driftwood.Freight.Driver |> AshPhoenix.Form.for_create(:create, scope: scope) |> Phoenix.Component.to_form())

    params = %{
      "full_name" => %{"first" => "Rowan", "last" => "Haulmark"},
      "cdl_number" => "CDL-RT-0042",
      "cdl_state" => "TX",
      "cdl_expiry" => Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
      "medical_card_expiry" => Date.utc_today() |> Date.add(180) |> Date.to_iso8601(),
      "eld_provider" => "samsara",
      # Invalid on purpose: the form stays open with an error, as after a bad submit.
      "status" => "not_a_real_status"
    }

    {:noreply, socket} = BrokerLive.handle_event("validate_new_driver", %{"form" => params}, socket)
    html = render(socket.assigns)

    scraped = %{
      "first" => input_value(html, ~s(name="form[full_name][first]")),
      "last" => input_value(html, ~s(name="form[full_name][last]")),
      "cdl" => input_value(html, ~s(name="form[cdl_number]"))
    }

    assert scraped == %{"first" => "Rowan", "last" => "Haulmark", "cdl" => "CDL-RT-0042"}
    refute html =~ "redacted"

    resubmit =
      params
      |> Map.merge(%{
        "full_name" => Map.take(scraped, ["first", "last"]),
        "cdl_number" => scraped["cdl"],
        "status" => "available",
        "org_id" => @org
      })

    assert {:ok, driver} = AshPhoenix.Form.submit(socket.assigns.new_driver_form, params: resubmit)

    found = Enum.find(Reads.driver_roster(scope), &(&1.id == driver.id))
    assert found.cdl_number == "CDL-RT-0042"
    assert inspect(found.full_name) =~ "Haulmark"
  end
end
