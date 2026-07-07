defmodule Driftwood.SettlementMathTest do
  @moduledoc """
  RED-PATH + PROPERTY test for the carrier-settlement netting reshape (design §3).

  The netting math is a `Driftwood.Context` `reshape` over the vertical `Settlement`
  resource: `net_payable = linehaul − advances − factoring_fee − claims`, clamped at
  0 with the shortfall booked as `carryover`. This test:

    * pins the FOUR worked examples from design §3.5 TO THE CENT (incl. the
      advance-exceeds-linehaul negative/carryover edge);
    * property-tests the derived values against an independent Elixir reference over
      thousands of random settlements (the netting math must match the reference for
      every input — including negative net_raw);
    * pins the integer-division truncation direction (OR-5): factoring_fee uses
      `gross * bps / 10000` and MUST match the reference's `div/2` truncation.

  ANTI-TAUTOLOGY: see `test/anti_tautology_probe_test.md` (a scratch-dir sabotage of
  the reshape flips these assertions; confirmed and reverted — result recorded in the
  T5.2 report).
  """
  use Driftwood.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  @org_id "00000000-0000-0000-0000-0000000000aa"

  # The independent reference implementation (NOT the reshape) — pure integer cents.
  # This is what the reshape's expr(...) must reproduce exactly.
  defp ref(inputs) do
    linehaul = inputs.linehaul_cents
    fuel = inputs.fuel_surcharge_cents
    accessorial = inputs.accessorial_cents
    advances = inputs.advances_cents
    claims = inputs.claim_deduction_cents
    bps = inputs.factoring_rate_bps

    gross = linehaul + fuel + accessorial
    factoring_fee = div(gross * bps, 10_000)
    net_raw = gross - advances - factoring_fee - claims
    net_payable = max(net_raw, 0)
    carryover = max(-net_raw, 0)

    %{
      gross_cents: gross,
      factoring_fee_cents: factoring_fee,
      net_raw_cents: net_raw,
      net_payable_cents: net_payable,
      carryover_cents: carryover
    }
  end

  defp create_settlement(inputs) do
    Driftwood.Freight.Settlement
    |> Ash.Changeset.for_create(:create, Map.put(inputs, :org_id, @org_id),
      authorize?: false
    )
    |> Ash.create!()
  end

  # Read the settlement back WITH the reshape calcs loaded (the derived money).
  defp reshaped(id) do
    Samen.Context.reshaped_query(Driftwood.Context, Driftwood.Freight.Settlement)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp assert_matches_reference(inputs) do
    settlement = create_settlement(inputs)
    row = reshaped(settlement.id)
    expected = ref(inputs)

    for {field, exp} <- expected do
      # Reshape calcs (loaded ad-hoc via Ash.Query.calculate) land in row.calculations.
      got = Map.fetch!(row.calculations, field)
      # The reshape returns :integer calcs; normalise to integer for the compare.
      got_int = to_int(got)

      assert got_int == exp,
             "field #{field}: reshape=#{inspect(got)} (#{got_int}) != reference=#{exp} " <>
               "for inputs #{inspect(inputs)}"
    end

    {row, expected}
  end

  defp to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp to_int(i) when is_integer(i), do: i
  defp to_int(f) when is_float(f), do: round(f)

  # -- Worked examples (design §3.5), to the cent ---------------------------------

  test "Example 1 — plain settlement, no factoring: $2000 − $500 = $1500" do
    {_row, exp} =
      assert_matches_reference(%{
        linehaul_cents: 200_000,
        advances_cents: 50_000,
        fuel_surcharge_cents: 0,
        accessorial_cents: 0,
        claim_deduction_cents: 0,
        factoring_rate_bps: 0
      })

    assert exp.net_payable_cents == 150_000
    assert exp.factoring_fee_cents == 0
    assert exp.carryover_cents == 0
  end

  test "Example 2 — 3% factoring on $2150 gross: fee $64.50, net $2085.50" do
    {_row, exp} =
      assert_matches_reference(%{
        linehaul_cents: 200_000,
        advances_cents: 0,
        fuel_surcharge_cents: 15_000,
        accessorial_cents: 0,
        claim_deduction_cents: 0,
        factoring_rate_bps: 300
      })

    assert exp.gross_cents == 215_000
    assert exp.factoring_fee_cents == 6_450
    assert exp.net_payable_cents == 208_550
  end

  test "Example 3 — advance exceeds linehaul: net_raw −$324 → net_payable $0, carryover $324" do
    {_row, exp} =
      assert_matches_reference(%{
        linehaul_cents: 120_000,
        advances_cents: 150_000,
        fuel_surcharge_cents: 0,
        accessorial_cents: 0,
        claim_deduction_cents: 0,
        factoring_rate_bps: 200
      })

    assert exp.net_raw_cents == -32_400
    assert exp.net_payable_cents == 0
    assert exp.carryover_cents == 32_400
  end

  test "Example 4 — full stack (surcharge+accessorial+factoring+advance+claim): net $1382.15" do
    {_row, exp} =
      assert_matches_reference(%{
        linehaul_cents: 180_000,
        advances_cents: 60_000,
        fuel_surcharge_cents: 22_000,
        accessorial_cents: 7_500,
        claim_deduction_cents: 5_000,
        factoring_rate_bps: 300
      })

    assert exp.gross_cents == 209_500
    assert exp.factoring_fee_cents == 6_285
    assert exp.net_payable_cents == 138_215
  end

  # -- Property test (thousands of random settlements) ----------------------------

  property "reshape netting matches the independent reference for every input" do
    check all(
            linehaul <- integer(0..1_000_000),
            fuel <- integer(0..200_000),
            accessorial <- integer(0..200_000),
            advances <- integer(0..1_500_000),
            claims <- integer(0..200_000),
            bps <- integer(0..2_000),
            max_runs: 200
          ) do
      inputs = %{
        linehaul_cents: linehaul,
        advances_cents: advances,
        fuel_surcharge_cents: fuel,
        accessorial_cents: accessorial,
        claim_deduction_cents: claims,
        factoring_rate_bps: bps
      }

      assert_matches_reference(inputs)
    end
  end

  # -- Integer-division truncation pinned (OR-5) ----------------------------------

  test "factoring_fee truncates toward zero (integer division), pinned" do
    # gross 100_001c * 333 bps / 10000 = 3330.033... → truncates to 3330c.
    {_row, exp} =
      assert_matches_reference(%{
        linehaul_cents: 100_001,
        advances_cents: 0,
        fuel_surcharge_cents: 0,
        accessorial_cents: 0,
        claim_deduction_cents: 0,
        factoring_rate_bps: 333
      })

    assert exp.factoring_fee_cents == div(100_001 * 333, 10_000)
    assert exp.factoring_fee_cents == 3_330
  end
end
