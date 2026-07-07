defmodule Driftwood.PitrGameday2Test do
  @moduledoc """
  RED-PATH + anti-vacuity test for the T5.5 PITR game-day #2 settlement-integrity
  harness (plan §7 T5.5, hard-rule 2: every guarantee ships a red-path must-fail test).

  The FULL drill (production-sized dataset, real pg_dump/restore, both arms, key-store
  exclusion) is the bash orchestrator `priv/gameday/pitr_gameday_sim.sh`, which
  driftwood/ci.sh runs as a step and which writes reports/T5.5.md. THIS test pins the
  load-bearing VALIDATION LOGIC that the drill (and the red-path probe) depend on:

    * GREEN path — with the settlements intact, `SettlementIntegrity.run/1` returns
      `{:ok, ...}` (proves the check is non-vacuous: it CAN pass);
    * RED path — dropping the load-bearing input column `stl_advances_cents` (exactly
      what the bad contract does, and what `--probe-corrupt` does to the restore
      target) flips it to `{:error, ...}` — the harness FAILS CLOSED. If this ever
      returned `{:ok, ...}` on a column-dropped table, the drill's red path would be a
      tautology; this test is the guard.

  The bash-orchestrated anti-tautology probe (sabotage `run/1` → it falsely passes →
  revert) is documented in reports/T5.5.md; this in-suite test is its permanent,
  CI-run analogue.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.PitrGameday.SettlementIntegrity

  @org_id "00000000-0000-0000-0000-0000000000bb"

  defp seed_settlements(n) do
    for _ <- 1..n do
      Driftwood.Freight.Settlement
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @org_id,
          linehaul_cents: :rand.uniform(400_000) + 50_000,
          advances_cents: :rand.uniform(120_000),
          fuel_surcharge_cents: :rand.uniform(30_000),
          accessorial_cents: :rand.uniform(15_000),
          claim_deduction_cents: :rand.uniform(8_000),
          factoring_rate_bps: Enum.random([0, 150, 200, 300])
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    :ok
  end

  test "GREEN — settlement integrity holds on an intact dataset (non-vacuous)" do
    seed_settlements(50)

    assert {:ok, %{settlements: n}} = SettlementIntegrity.run(Repo)
    assert n >= 50
  end

  test "RED — dropping the load-bearing stl_advances_cents column FAILS CLOSED" do
    seed_settlements(50)

    # Sanity: it passes BEFORE the bad contract (proves the flip is the drop).
    assert {:ok, _} = SettlementIntegrity.run(Repo)

    # The bad contract: drop the load-bearing settlement INPUT. Raw DDL inside the
    # sandbox transaction — reverted automatically at test end.
    Ecto.Adapters.SQL.query!(Repo, "ALTER TABLE stl_settlement DROP COLUMN stl_advances_cents", [])

    # RED PATH: the harness MUST fail closed (never {:ok, ...}) once advances is gone.
    assert {:error, reason} = SettlementIntegrity.run(Repo)
    assert reason =~ "stl_advances_cents column MISSING"
    assert reason =~ "OVER-PAID"
  end

  test "RED — an empty dataset FAILS CLOSED (restore target wrong/empty)" do
    # No settlements seeded → the non-empty check must reject (a restore that landed
    # on an empty/wrong DB must not validate).
    assert {:error, reason} = SettlementIntegrity.run(Repo)
    assert reason =~ "EMPTY"
  end
end
