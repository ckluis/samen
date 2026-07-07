defmodule Driftwood.Context do
  @moduledoc """
  Driftwood's bounded context (design §1.2, §3) — the anti-corruption layer that
  writes freight's ubiquitous language over the shared kernel, using `Samen.Context`:

    * `alias_resource Company, as: Carrier` AND `as: Shipper` — two ubiquitous-language
      renames over ONE kernel Company (DECISION C2). The alias is a NAME only; the
      kernel Company's OrgScope/vault/audit ride underneath unchanged. The role is
      carried in the `company_role` Tier-1 custom field; aliased reads filter on it.
    * `alias_resource Opportunity, as: Load` — the freight load/shipment (DECISION L).
    * `alias_resource Activity, as: CheckCall` — the routine check-call event stream
      (DECISION A). Dispatch itself is the vertical DispatchEvent resource.
    * `reshape Settlement do … end` — the carrier-settlement netting math as derived
      `calculate … expr(...)` fields (DECISION S). This is the load-bearing billing
      reshape: `net_payable = linehaul − advances − factoring_fee − claims`, clamped
      at 0 with the shortfall as `carryover` (DECISION N).

  ## OR-4 resolution (inlined net_raw)

  Ash expression calculations do not reliably reference sibling calcs within one
  reshape block, so `net_raw` is INLINED into `net_payable_cents` and
  `carryover_cents`. The arithmetic is byte-for-byte the §3.5 canonical math; the
  property test (`SettlementMathTest`) pins every worked example to the cent,
  including the negative/carryover edge and the integer-division truncation (OR-5).
  """
  use Samen.Context

  context do
    domain(Driftwood.Freight)

    # --- ubiquitous-language renames (name-only aliases) ---
    alias_resource(Driftwood.Crm.Company, as: Driftwood.Carrier)
    alias_resource(Driftwood.Crm.Company, as: Driftwood.Shipper)
    alias_resource(Driftwood.Crm.Opportunity, as: Driftwood.Load)
    alias_resource(Driftwood.Crm.Activity, as: Driftwood.CheckCall)

    # --- the carrier-settlement netting reshape (derived money) ---
    #
    # OR-5 (integer-division truncation) is PINNED by computing the factoring fee as
    # `(gross*bps - rem(gross*bps, 10000)) / 10000`. `gross*bps - rem(gross*bps,10000)`
    # is an exact multiple of 10000, so the `/10000` is exact and the `:integer` cast
    # rounds nothing — reproducing `div/2` truncation toward zero (all inputs are
    # non-negative, so truncation = floor). Ash's plain `/` yields a numeric that the
    # `:integer` cast would ROUND (240.65 → 241); the rem form floors it (→ 240), which
    # the property test proved is the correct, reference-matching direction.
    reshape Driftwood.Freight.Settlement do
      # gross = linehaul + fuel surcharge + accessorials (all cents)
      calculate(
        :gross_cents,
        :integer,
        expr(linehaul_cents + fuel_surcharge_cents + accessorial_cents)
      )

      # factoring fee = trunc(gross * rate_bps / 10000)  (integer cents)
      calculate(
        :factoring_fee_cents,
        :integer,
        expr(
          ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps -
             rem(
               (linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps,
               10000
             )) / 10000
        )
      )

      # net_raw (may be negative) = gross - advances - factoring_fee - claims.
      calculate(
        :net_raw_cents,
        :integer,
        expr(
          linehaul_cents + fuel_surcharge_cents + accessorial_cents - advances_cents -
            ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps -
               rem(
                 (linehaul_cents + fuel_surcharge_cents + accessorial_cents) *
                   factoring_rate_bps,
                 10000
               )) / 10000 - claim_deduction_cents
        )
      )

      # net_payable = max(net_raw, 0) — a carrier is never paid a negative settlement.
      calculate(
        :net_payable_cents,
        :integer,
        expr(
          if(
            linehaul_cents + fuel_surcharge_cents + accessorial_cents - advances_cents -
              ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps -
                 rem(
                   (linehaul_cents + fuel_surcharge_cents + accessorial_cents) *
                     factoring_rate_bps,
                   10000
                 )) / 10000 - claim_deduction_cents > 0,
            linehaul_cents + fuel_surcharge_cents + accessorial_cents - advances_cents -
              ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps -
                 rem(
                   (linehaul_cents + fuel_surcharge_cents + accessorial_cents) *
                     factoring_rate_bps,
                   10000
                 )) / 10000 - claim_deduction_cents,
            0
          )
        )
      )

      # carryover = max(-net_raw, 0) — the negative rolls forward as a debt.
      calculate(
        :carryover_cents,
        :integer,
        expr(
          if(
            linehaul_cents + fuel_surcharge_cents + accessorial_cents - advances_cents -
              ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) * factoring_rate_bps -
                 rem(
                   (linehaul_cents + fuel_surcharge_cents + accessorial_cents) *
                     factoring_rate_bps,
                   10000
                 )) / 10000 - claim_deduction_cents < 0,
            -(linehaul_cents + fuel_surcharge_cents + accessorial_cents - advances_cents -
                  ((linehaul_cents + fuel_surcharge_cents + accessorial_cents) *
                     factoring_rate_bps -
                     rem(
                       (linehaul_cents + fuel_surcharge_cents + accessorial_cents) *
                         factoring_rate_bps,
                       10000
                     )) / 10000 - claim_deduction_cents),
            0
          )
        )
      )
    end
  end
end
