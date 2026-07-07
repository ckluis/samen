defmodule Driftwood.DispatchWorkerTest do
  @moduledoc """
  The load/dispatch workflow as an Oban job (T2.1). The worker runs the SAME
  FMCSA-gated action, so the compliance gate guards the async path too: a compliant
  driver dispatches and writes a row; an expired driver is DISCARDED (a compliance
  refusal is not a transient error).
  """
  use Driftwood.DataCase, async: false
  require Ash.Query

  @org "00000000-0000-0000-0000-0000000000d1"

  defp driver(attrs) do
    base = %{
      org_id: @org,
      full_name: %{first: "Otto", last: "Wheel"},
      cdl_number: "OW-1",
      cdl_state: "TX",
      cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
      medical_card_expiry: Date.add(Date.utc_today(), 180),
      status: :available
    }

    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), authorize?: false)
    |> Ash.create!()
  end

  defp load do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, %{org_id: @org, name: "Worker load"}, authorize?: false)
    |> Ash.create!()
  end

  defp run(driver, load) do
    Driftwood.Jobs.DispatchWorker.perform(%Oban.Job{
      args: %{"driver_id" => to_string(driver.id), "load_id" => to_string(load.id), "org_id" => @org}
    })
  end

  defp count(load_id) do
    Driftwood.Freight.DispatchEvent
    |> Ash.Query.filter(load_id == ^load_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  test "worker dispatches a compliant driver and writes the DispatchEvent" do
    d = driver(%{})
    l = load()

    assert {:ok, _event} = run(d, l)
    assert count(l.id) == 1
  end

  test "worker DISCARDS (not retries) an expired-medical-card driver — no row" do
    d = driver(%{medical_card_expiry: Date.add(Date.utc_today(), -1)})
    l = load()

    assert {:discard, reason} = run(d, l)
    assert reason =~ "medical_card_expired"
    assert count(l.id) == 0
  end

  test "worker DISCARDS an out_of_service driver" do
    d = driver(%{status: :out_of_service})
    l = load()

    assert {:discard, reason} = run(d, l)
    assert reason =~ "out_of_service"
    assert count(l.id) == 0
  end
end
