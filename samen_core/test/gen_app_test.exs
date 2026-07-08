defmodule Samen.Gen.AppTest do
  @moduledoc """
  Unit coverage for the `mix samen.gen.app` generator engine (T6.4). Exercises the pure
  spec derivation, the fail-closed validation rules (the generator's own guardrails), and
  the idempotent registry reservation — all WITHOUT touching the committed abbrev registry
  or scaffolding a real app (a temp registry file + a temp target dir keep it hermetic).

  The end-to-end "generated app passes its own gate" claim is covered by
  `priv/gen_app_gate_probe.exs` (the anti-tautology probe) and, in the workflow, by the
  T6.4 red path that scaffolds Widgetco and runs its ci.sh.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App, as: Gen

  defp spec(opts \\ []) do
    Gen.build_spec(
      module: opts[:module] || "Widgetco",
      prefix: opts[:prefix] || "wg",
      abbrev: opts[:abbrev] || "wid",
      target: opts[:target] || "/tmp/samen_gen_test_target"
    )
  end

  describe "build_spec/1 derivation" do
    test "derives otp_app, app_dir, resource, billing abbrevs, and aggregate abbrev" do
      s = spec()

      assert s.otp_app == :widgetco
      assert s.app_dir == "/tmp/samen_gen_test_target/widgetco"
      assert s.resource_module == "Widgetco.Vertical.Record"
      assert s.resource_table == "wid_record"

      assert s.billing_abbrevs == %{
               customer: "wgc",
               subscription: "wgs",
               plan: "wgl",
               price: "wgp",
               invoice: "wgi",
               payment: "wgy",
               usage: "wgu",
               entitlement: "wge"
             }

      assert s.agg_abbrev == "wga"
      assert s.agg_table == "wga_record_count"
    end

    test "reserved_pairs covers the 8 billing + aggregate + authored abbrevs (10 total)" do
      pairs = Gen.reserved_pairs(spec())
      abbrevs = Enum.map(pairs, &elem(&1, 0))

      assert length(pairs) == 10
      assert "wid" in abbrevs
      assert "wga" in abbrevs
      assert "wgc" in abbrevs
      assert {"wid", "Widgetco.Vertical.Record"} in pairs
      assert {"wga", "Widgetco.Aggregate.RecordCountBySegment"} in pairs
      assert {"wgc", "Widgetco.Billing.Customer"} in pairs
    end
  end

  describe "validate_against!/2 fail-closed rules" do
    @empty %{}

    test "green: a fresh, well-formed spec validates against an empty registry" do
      assert Gen.validate_against!(spec(), @empty) == :ok
    end

    test "red: a non-2-letter prefix is rejected" do
      assert_raise ArgumentError, ~r/prefix must be exactly 2 lowercase letters/, fn ->
        Gen.validate_against!(spec(prefix: "wgx"), @empty)
      end
    end

    test "red: a non-3-letter abbrev is rejected" do
      assert_raise ArgumentError, ~r/abbrev must be exactly 3 lowercase letters/, fn ->
        Gen.validate_against!(spec(abbrev: "wi"), @empty)
      end
    end

    test "red: an invalid module alias is rejected" do
      assert_raise ArgumentError, ~r/valid Elixir module alias/, fn ->
        Gen.validate_against!(spec(module: "widgetco"), @empty)
      end
    end

    test "red: internal collision (resource abbrev == derived aggregate abbrev) is rejected" do
      # prefix "nb" derives aggregate abbrev "nba"; the same abbrev on the resource collides.
      assert_raise ArgumentError, ~r/internal collisions/, fn ->
        Gen.validate_against!(spec(module: "Nb", prefix: "nb", abbrev: "nba"), @empty)
      end
    end

    test "red: an abbrev already owned by a DIFFERENT resource is rejected (permanence)" do
      registry = %{"wid" => "SomeoneElse.Resource"}

      assert_raise ArgumentError, ~r/already reserved to SomeoneElse.Resource/, fn ->
        Gen.validate_against!(spec(), registry)
      end
    end

    test "green: an abbrev already owned by the SAME resource is fine (idempotent re-run)" do
      registry = %{"wid" => "Widgetco.Vertical.Record"}
      assert Gen.validate_against!(spec(), registry) == :ok
    end
  end

  describe "reserve_abbrevs!/2 (idempotent, preserves $comment)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "samen_gen_reg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "abbrev_registry.json")

      File.write!(
        path,
        Jason.encode!(%{"$comment" => "PERMANENT registry.", "abbrevs" => %{"com" => "X.Y"}},
          pretty: true
        )
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: path}
    end

    test "appends every reserved abbrev and preserves the pre-existing rows + comment",
         %{path: path} do
      :ok = Gen.reserve_abbrevs!(spec(), path)

      decoded = path |> File.read!() |> Jason.decode!()

      assert decoded["$comment"] == "PERMANENT registry."
      # pre-existing row preserved
      assert decoded["abbrevs"]["com"] == "X.Y"
      # all 10 app abbrevs reserved to their owners
      assert decoded["abbrevs"]["wid"] == "Widgetco.Vertical.Record"
      assert decoded["abbrevs"]["wga"] == "Widgetco.Aggregate.RecordCountBySegment"
      assert decoded["abbrevs"]["wgc"] == "Widgetco.Billing.Customer"
      assert decoded["abbrevs"]["wge"] == "Widgetco.Billing.Entitlement"
    end

    test "is idempotent: a second reservation is a no-op (no duplicates, no raise)",
         %{path: path} do
      :ok = Gen.reserve_abbrevs!(spec(), path)
      first = File.read!(path)

      :ok = Gen.reserve_abbrevs!(spec(), path)
      second = File.read!(path)

      assert first == second
    end

    test "refuses to hand a reserved abbrev to a different owner", %{path: path} do
      # Pre-seed "wid" to a different owner, then attempt reservation for Widgetco.
      File.write!(
        path,
        Jason.encode!(%{"abbrevs" => %{"wid" => "Intruder.Resource"}}, pretty: true)
      )

      assert_raise ArgumentError, ~r/already owned by Intruder.Resource/, fn ->
        Gen.reserve_abbrevs!(spec(), path)
      end
    end
  end

  describe "samen_core_rel_path/1" do
    test "a direct sibling resolves to ../samen_core" do
      s = spec(target: Gen.default_target())
      assert Gen.samen_core_rel_path(s) == "../samen_core"
    end

    test "a nested scratch parent resolves with extra .. segments" do
      s = spec(target: Path.join(Gen.default_target(), "_scratch"))
      assert Gen.samen_core_rel_path(s) == "../../samen_core"
    end
  end

  describe "render/2 template substitution" do
    test "replaces <%= key %> tokens and leaves unrelated text intact" do
      out = Gen.render("app=<%= otp_app %> mod=<%= module %> x<%= abbrev %>y", Gen.bindings(spec()))
      assert out == "app=widgetco mod=Widgetco xwidy"
    end
  end
end
