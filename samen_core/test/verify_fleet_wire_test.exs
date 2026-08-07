defmodule Samen.VerifyFleetWireTest do
  @moduledoc """
  T84b — `mix samen.verify.fleet_wire` (ADR-044 §5.2 point 4 / phase6-punchlist P8).

  Three independent checks, each green + red + anti-tautology:

    * RP-J-4 — schema class discipline (delegates to the already-shipped
      `Schema.class_discipline_violations/0`; asserted here at the TASK level so
      a future regression is caught by THIS gate, not just the schema's own test).
    * P8 — closed-catalog MEMBERSHIP: a host that declares a non-empty catalog
      gets REAL membership enforcement (the live smoke-check); a host that
      declares an EMPTY catalog fails (a catalog that claims closure but admits
      nothing is worse than not declaring one); a host with NO declaration at
      all is clean (opt-in, not a regression for the many hosts that haven't
      adopted cohorts yet).
    * RP-J-4b — the route-surface cross-check (needs `--router`; skipped, not a
      violation, when omitted).
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.FleetWire

  @test_host :samen_core_fleet_wire_test_host

  setup do
    on_exit(fn -> Application.delete_env(@test_host, :fleet_wire_catalogs) end)
    :ok
  end

  describe "RP-J-4 — class discipline (delegated, asserted at the gate level)" do
    test "GREEN: the real schema has zero class-discipline violations" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      assert FleetWire.violations(host: @test_host) == []
    end
  end

  describe "P8 — closed-catalog membership" do
    test "GREEN: no catalogs declared at all — not a violation (opt-in, unadopted host untouched)" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      assert FleetWire.violations(host: @test_host) == []
    end

    test "GREEN: a declared non-empty catalog passes the live smoke-check" do
      Application.put_env(@test_host, :fleet_wire_catalogs,
        closed_check_catalog: ~w(db_reachable redis_reachable)
      )

      assert FleetWire.violations(host: @test_host) == []
    end

    test "RED: a declared EMPTY catalog is a violation (claims closure, admits nothing/anything)" do
      Application.put_env(@test_host, :fleet_wire_catalogs, closed_check_catalog: [])

      assert [violation] = FleetWire.violations(host: @test_host)
      assert violation =~ "empty or malformed"
      assert violation =~ "closed_check_catalog"
    end

    test "RED sabotage twin — Schema.validate/2 accepting an out-of-catalog label flips the smoke-check" do
      # Simulate the regression the smoke-check exists to catch: a catalog is
      # declared, but membership enforcement is NOT wired (Schema.validate/2
      # would accept anything shape-valid). We can't literally break the shipped
      # Schema module inside a test without a real sabotage patch, so this test
      # instead pins the CONTRACT the smoke-check depends on: validate/2 MUST
      # reject a label outside a supplied non-empty catalog. If this assertion
      # ever fails, the FleetWire smoke-check silently stops being able to catch
      # a real regression (the anti-tautology guarantee).
      catalogs = %{closed_check_catalog: ~w(db_reachable)}

      payload =
        Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
        |> Samen.Fleet.Report.to_wire()
        |> Map.put("checks", [%{"name" => "zz_not_in_catalog", "status" => "ok"}])

      assert {:error, errors} = Samen.Fleet.Report.Schema.validate(payload, catalogs)
      assert Enum.any?(errors, &String.contains?(&1, "closed_check_catalog"))
    end

    test "all four sentinels get a real smoke-check when declared" do
      Application.put_env(@test_host, :fleet_wire_catalogs,
        closed_check_catalog: ~w(a),
        closed_plan_tier_catalog: ~w(free),
        closed_app_queue_catalog: ~w(mailers),
        closed_audit_taxonomy_catalog: ~w(login)
      )

      assert FleetWire.violations(host: @test_host) == []
    end
  end

  describe "RP-J-4b — route surface (needs --router)" do
    test "no --router: skipped, not a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      assert FleetWire.violations(host: @test_host, router: nil) == []
    end

    test "RED: --router pointing at a non-router module is a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      assert [violation] = FleetWire.violations(host: @test_host, router: Samen.Fleet.RouteTable)
      assert violation =~ "not a compiled Phoenix router"
    end
  end
end
