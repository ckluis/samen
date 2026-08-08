defmodule DriftwoodWeb.BrokerSettlementCrudTest do
  @moduledoc """
  T158 — SETTLEMENT create + edit (previously seed-only). Both ride the real
  `Driftwood.Freight.Settlement` `:create`/`:update` actions through
  `AshPhoenix.Form` — the stored integer-cents inputs; the derived netting calcs
  (gross/factoring_fee/net_payable/carryover) stay a `Driftwood.Context` reshape,
  untouched by this write (the resource's own actions, not the reshape, own writes).
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000e1"
  @other_org "c1230000-0000-4000-8000-0000000000e2"

  defp create_settlement(org, overrides \\ %{}) do
    scope = BrokerLive.broker_scope(org)

    params =
      Map.merge(
        %{
          "linehaul_cents" => "500000",
          "advances_cents" => "10000",
          "fuel_surcharge_cents" => "5000",
          "accessorial_cents" => "0",
          "claim_deduction_cents" => "2500",
          "factoring_rate_bps" => "300",
          "currency" => "USD",
          "status" => "draft"
        },
        overrides
      )
      |> Map.put("org_id", org)

    Driftwood.Freight.Settlement
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> AshPhoenix.Form.submit(params: params)
  end

  test "GREEN: a real AshPhoenix.Form create persists a settlement, visible on the panel read" do
    scope = BrokerLive.broker_scope(@org)
    assert Reads.settlements(scope) == []

    assert {:ok, settlement} = create_settlement(@org)

    rows = Reads.settlements(scope)
    assert Enum.any?(rows, &(&1.id == settlement.id and &1.linehaul_cents == 500_000))
  end

  test "RED: cross-org read never surfaces the settlement (org-scope pin)" do
    {:ok, settlement} = create_settlement(@org)

    other_scope = BrokerLive.broker_scope(@other_org)
    refute Enum.any?(Reads.settlements(other_scope), &(&1.id == settlement.id))
  end

  test "GREEN: a real AshPhoenix.Form edit persists — the reshaped netting calc reflects it" do
    {:ok, settlement} = create_settlement(@org, %{"linehaul_cents" => "100000", "advances_cents" => "0", "factoring_rate_bps" => "0", "claim_deduction_cents" => "0", "fuel_surcharge_cents" => "0", "accessorial_cents" => "0"})
    scope = BrokerLive.broker_scope(@org)

    {:ok, resolved} = Reads.get_settlement(scope, settlement.id)

    {:ok, updated} =
      resolved
      |> AshPhoenix.Form.for_update(:update, scope: scope)
      |> AshPhoenix.Form.submit(params: %{"linehaul_cents" => "200000", "status" => "approved"})

    assert updated.linehaul_cents == 200_000
    assert updated.status == :approved

    row = Enum.find(Reads.settlements(scope), &(&1.id == settlement.id))
    assert row.linehaul_cents == 200_000
    # net_payable reflects the new linehaul (200000 - 0 advances - 0 factoring - 0 claims).
    assert row.net_payable_cents == 200_000
  end

  test "RED: editing another org's settlement id is a genuine :not_found" do
    {:ok, settlement} = create_settlement(@org)
    other_scope = BrokerLive.broker_scope(@other_org)

    assert :error = Reads.get_settlement(other_scope, settlement.id)
  end
end
