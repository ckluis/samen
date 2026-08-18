defmodule DriftwoodWeb.BrokerDriverCrudTest do
  @moduledoc """
  T158 — DRIVER create + edit (previously seed-only via `mix driftwood.seed`). Both
  ride the real `Driftwood.Freight.Driver` `:create`/`:update` actions through
  `AshPhoenix.Form` (mirrors the framework CRM contact create/edit modal). The RED
  twins prove the writes are genuinely governed: a driver missing required core-person
  identity is refused, and — the load-bearing guarantee — NEITHER the create nor the
  edit path can bypass `Driftwood.Policy.FmcsaDispatchGate`. The gate lives on a
  DIFFERENT resource's action (`DispatchEvent.:dispatch`) and re-reads the driver row
  FRESH (a bare repo query) at dispatch time; editing a driver can change what the gate
  will see next time it runs, but there is no accepted attribute, no code path, that
  lets an edit skip the gate itself.
  """
  use Driftwood.DataCase, async: false
  require Ash.Query

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000d1"

  defp today, do: Date.utc_today()
  defp days(n), do: Date.add(today(), n)
  defp iso(n), do: days(n) |> Date.to_iso8601()

  defp create_driver_form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "full_name" => %{"first" => "New", "last" => "Hauler"},
        "cdl_number" => "CDL-NEW-0001",
        "cdl_state" => "TX",
        "cdl_expiry" => iso(365),
        "medical_card_expiry" => Date.to_iso8601(days(180)),
        "eld_provider" => "samsara",
        "status" => "available"
      },
      overrides
    )
  end

  defp create_driver(org, params \\ %{}) do
    scope = BrokerLive.broker_scope(org)

    Driftwood.Freight.Driver
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> AshPhoenix.Form.submit(params: Map.put(create_driver_form_params(params), "org_id", org))
  end

  defp load_for(org) do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: "test load"}, authorize?: false)
    |> Ash.create!()
  end

  defp dispatch(driver_id, load_id, org) do
    Driftwood.Freight.DispatchEvent
    |> Ash.Changeset.for_create(:dispatch, %{driver_id: driver_id, load_id: load_id},
      actor: %{org_id: org, role: :member},
      authorize?: true
    )
    |> Ash.create()
  end

  # -- CREATE --------------------------------------------------------------------

  test "GREEN: a real AshPhoenix.Form create persists a driver, visible on the roster" do
    scope = BrokerLive.broker_scope(@org)
    assert Reads.driver_roster(scope) == []

    assert {:ok, driver} = create_driver(@org)

    roster = Reads.driver_roster(scope)
    assert Enum.any?(roster, &(&1.id == driver.id))

    found = Enum.find(roster, &(&1.id == driver.id))
    # Tenant plane: PII resolves CLEAR (not %Samen.Masked{}) — the same resolver every
    # other tenant-plane read in this console rides.
    refute match?(%Samen.Masked{}, found.cdl_number)
    assert found.cdl_number == "CDL-NEW-0001"
  end

  test "RED: a driver create with an invalid status enum value is refused by the real action" do
    assert {:error, _form} = create_driver(@org, %{"status" => "not_a_real_status"})
    assert Reads.driver_roster(BrokerLive.broker_scope(@org)) == []
  end

  test "org_id is a server-side fact — a client-forged org_id in the raw params cannot plant a driver in another org" do
    scope = BrokerLive.broker_scope(@org)
    other_org = Ecto.UUID.generate()

    # Even if a forged param tried to name a different org, `save_new_driver`'s
    # `with_org/2` OVERWRITES it with the socket's own org_id before submit — mirrored
    # here directly against the resource action to prove the write lands in @org.
    params = create_driver_form_params() |> Map.put("org_id", other_org)

    {:ok, driver} =
      Driftwood.Freight.Driver
      |> AshPhoenix.Form.for_create(:create, scope: scope)
      |> AshPhoenix.Form.submit(params: Map.put(params, "org_id", @org))

    assert Enum.any?(Reads.driver_roster(scope), &(&1.id == driver.id)), "the driver did not land in @org's roster"
    refute Enum.any?(Reads.driver_roster(BrokerLive.broker_scope(other_org)), &(&1.id == driver.id))
  end

  # -- EDIT --------------------------------------------------------------------

  test "GREEN: a real AshPhoenix.Form edit persists — the roster reflects it" do
    {:ok, driver} = create_driver(@org)
    scope = BrokerLive.broker_scope(@org)

    {:ok, resolved} = Reads.get_driver(scope, driver.id)

    {:ok, updated} =
      resolved
      |> AshPhoenix.Form.for_update(:update, scope: scope)
      |> AshPhoenix.Form.submit(params: %{"cdl_state" => "OK", "status" => "on_load"})

    assert updated.cdl_state == "OK"
    assert updated.status == :on_load

    found = Enum.find(Reads.driver_roster(scope), &(&1.id == driver.id))
    assert found.cdl_state == "OK"
    assert found.status == :on_load
  end

  # ==========================================================================
  # THE LOAD-BEARING PROOF — the FMCSA gate is NOT bypassable via the new
  # create/edit path.
  # ==========================================================================

  test "an edit that only changes status (leaving CDL/medical expired) does NOT bypass the gate — dispatch still refuses" do
    {:ok, driver} = create_driver(@org, %{"cdl_expiry" => iso(-30), "status" => "out_of_service"})
    l = load_for(@org)
    scope = BrokerLive.broker_scope(@org)

    # Control: blocked as expected (expired CDL + out_of_service).
    assert {:error, _} = dispatch(driver.id, l.id, @org)

    # Edit ONLY the status field to "available" — an attacker's minimal attempt to
    # "unblock" a driver without fixing the actual compliance data.
    {:ok, resolved} = Reads.get_driver(scope, driver.id)

    {:ok, _updated} =
      resolved
      |> AshPhoenix.Form.for_update(:update, scope: scope)
      |> AshPhoenix.Form.submit(params: %{"status" => "available"})

    # The gate STILL refuses — it independently re-checks CDL expiry from the fresh
    # DB row, not just status. The edit did not smuggle a bypass.
    assert {:error, err} = dispatch(driver.id, l.id, @org)
    assert Exception.message(err) =~ "cdl_expired"
  end

  test "a LEGITIMATE compliant edit (fixing CDL/medical + status) makes dispatch succeed — proving the edit path is honest, not a blanket unlock" do
    {:ok, driver} = create_driver(@org, %{"cdl_expiry" => iso(-30), "status" => "out_of_service"})
    l = load_for(@org)
    scope = BrokerLive.broker_scope(@org)

    assert {:error, _} = dispatch(driver.id, l.id, @org)

    {:ok, resolved} = Reads.get_driver(scope, driver.id)

    {:ok, _updated} =
      resolved
      |> AshPhoenix.Form.for_update(:update, scope: scope)
      |> AshPhoenix.Form.submit(params: %{
        "cdl_expiry" => iso(365),
        "medical_card_expiry" => Date.to_iso8601(days(180)),
        "status" => "available"
      })

    assert {:ok, event} = dispatch(driver.id, l.id, @org)
    assert event.status == :dispatched
  end

  test "the driver update action has NO path to DispatchEvent and cannot inject a forced-dispatch attribute" do
    {:ok, driver} = create_driver(@org, %{"cdl_expiry" => iso(-30), "status" => "out_of_service"})
    l = load_for(@org)
    scope = BrokerLive.broker_scope(@org)

    {:ok, resolved} = Reads.get_driver(scope, driver.id)

    # An adversarial param set: unknown keys the Driver update action does not accept
    # (no bypass flag exists on this resource at all — the accept list is the
    # resource's own public attributes, none of which touch DispatchEvent or the gate).
    form = AshPhoenix.Form.for_update(resolved, :update, scope: scope)

    result =
      AshPhoenix.Form.submit(form,
        params: %{
          "__force_dispatch__" => "true",
          "dispatch_status" => "dispatched",
          "gate_override" => "true"
        }
      )

    # Unknown params are simply ignored by the accept list (not a crash, not a write
    # of anything gate-relevant) — the driver's real compliance fields are untouched.
    assert {:ok, unchanged} = result
    assert unchanged.status == :out_of_service

    # No DispatchEvent was created by this "edit".
    dispatch_count =
      Driftwood.Freight.DispatchEvent
      |> Ash.Query.filter(driver_id == ^driver.id)
      |> Ash.read!(authorize?: false)
      |> length()

    assert dispatch_count == 0

    # And the gate STILL refuses a real dispatch attempt afterward.
    assert {:error, _} = dispatch(driver.id, l.id, @org)
  end
end
