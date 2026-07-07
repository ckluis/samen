defmodule Driftwood.FmcsaDispatchGateTest do
  @moduledoc """
  RED-PATH tests for the FMCSA dispatch gate (design §4, DECISION F). Every failing
  condition REFUSES dispatch and writes NO DispatchEvent row; a fully-compliant driver
  dispatches (the non-vacuous control).

  ANTI-TAUTOLOGY: `test/anti_tautology_probe_test.md` records a scratch-dir sabotage of
  the gate's comparison (< → >), which flipped the must-fail tests to passing (an
  expired driver dispatched), then was reverted — proving these tests exercise the gate,
  not a constant.
  """
  use Driftwood.DataCase, async: false
  require Ash.Query

  @org "00000000-0000-0000-0000-0000000000b1"

  defp today, do: Date.utc_today()
  defp days(n), do: Date.add(today(), n)
  defp iso(n), do: days(n) |> Date.to_iso8601()

  # Create a driver with a vaulted CDL, and the given expiry dates + status.
  # cdl_expiry is ISO-8601 TEXT (see the Driver resource note); medical_card_expiry
  # is a :date.
  defp driver(attrs) do
    base = %{
      org_id: @org,
      full_name: %{first: "Pat", last: "Hauler"},
      cdl_number: "D1234567",
      cdl_state: "TX",
      cdl_expiry: iso(365),
      medical_card_expiry: days(180),
      status: :available
    }

    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), authorize?: false)
    |> Ash.create!()
  end

  defp load do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, %{org_id: @org, name: "Chicago → Dallas dry van"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp dispatch(driver, load) do
    Driftwood.Freight.DispatchEvent
    |> Ash.Changeset.for_create(
      :dispatch,
      %{driver_id: driver.id, load_id: load.id},
      actor: %{org_id: @org, role: :member},
      authorize?: true
    )
    |> Ash.create()
  end

  defp dispatch_event_count(load_id) do
    Driftwood.Freight.DispatchEvent
    |> Ash.Query.filter(load_id == ^load_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  # -- The non-vacuous CONTROL: a compliant driver dispatches -----------------------

  test "compliant driver dispatches successfully (positive control)" do
    d = driver(%{})
    l = load()

    assert {:ok, event} = dispatch(d, l)
    assert event.status == :dispatched
    assert dispatch_event_count(l.id) == 1
  end

  # -- RED PATHS: each failing condition refuses + writes no row --------------------

  test "expired medical card REFUSES dispatch, no row written" do
    d = driver(%{medical_card_expiry: days(-1)})
    l = load()

    assert {:error, err} = dispatch(d, l)
    assert Exception.message(err) =~ "medical_card_expired"
    assert dispatch_event_count(l.id) == 0
  end

  test "missing medical card REFUSES dispatch" do
    d = driver(%{medical_card_expiry: nil})
    l = load()

    assert {:error, err} = dispatch(d, l)
    assert Exception.message(err) =~ "medical_card_missing"
    assert dispatch_event_count(l.id) == 0
  end

  test "expired CDL REFUSES dispatch, no row written" do
    d = driver(%{cdl_expiry: iso(-1)})
    l = load()

    assert {:error, err} = dispatch(d, l)
    assert Exception.message(err) =~ "cdl_expired"
    assert dispatch_event_count(l.id) == 0
  end

  test "out_of_service driver REFUSES dispatch" do
    d = driver(%{status: :out_of_service})
    l = load()

    assert {:error, err} = dispatch(d, l)
    assert Exception.message(err) =~ "out_of_service"
    assert dispatch_event_count(l.id) == 0
  end

  test "terminated driver REFUSES dispatch" do
    d = driver(%{status: :terminated})
    l = load()

    assert {:error, err} = dispatch(d, l)
    assert Exception.message(err) =~ "terminated"
    assert dispatch_event_count(l.id) == 0
  end

  test "shredded CDL vault token REFUSES dispatch (no valid CDL on file)" do
    d = driver(%{})
    l = load()

    # Crypto-shred the driver subject → the pii_cdl vault row flips to state 'shredded'.
    {:ok, _attestation} = Samen.Erasure.shred(to_string(d.id), repo: Driftwood.Repo)

    assert {:error, err} = dispatch(d, l)
    msg = Exception.message(err)
    assert msg =~ "cdl_shredded" or msg =~ "cdl_missing"
    assert dispatch_event_count(l.id) == 0
  end

  test "driver with no CDL vault row at all REFUSES dispatch (cdl_missing)" do
    # A driver created WITHOUT a cdl_number → no pii_cdl vault row.
    d =
      Driftwood.Freight.Driver
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @org,
          full_name: %{first: "No", last: "License"},
          cdl_state: "TX",
          cdl_expiry: iso(365),
          medical_card_expiry: days(180),
          status: :available
        },
        authorize?: false
      )
      |> Ash.create!()

    l = load()

    assert {:error, err} = dispatch(d, l)
    assert Exception.message(err) =~ "cdl_missing"
    assert dispatch_event_count(l.id) == 0
  end
end
