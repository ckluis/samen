defmodule Driftwood.OperatorCrossProductScopeTest do
  @moduledoc """
  T83 / J3 — driftwood is scoped to its OWN product, at ALL FIVE `:operator_authority` sites
  (ADR-044 §6.2, §6.3a #4).

  Per-product role scoping means every `:operator_authority` wiring carries the `[:driftwood]`
  args carrier, and `Driftwood.Auth.operator_role/2` refuses any non-`:driftwood` scope — a role
  granted here confers scope ONLY on driftwood (RP-J-5). §6.3a #4 names this a grep-asserted
  CHECKLIST, not a code-review hope: a missed site silently keeps the old unscoped resolver, which
  would grant a cross-product role BY OMISSION.

  SABOTAGE-REFUTABLE: drop the app_scope guard from `operator_role/2` and the host-isolation rows
  flip (a non-driftwood scope resolves a role) — proven by
  `scripts/sabotages/121-t83-j3-driftwood-operator-role-scope-guard-drop.patch`.
  """
  use ExUnit.Case, async: false

  @router_path Path.expand("../lib/driftwood_web/router.ex", __DIR__)
  @config_path Path.expand("../config/config.exs", __DIR__)
  @operator_user "cross-product-op-1"

  setup do
    prev_roster = Application.get_env(:driftwood, :operator_roster)
    prev_armed = Application.get_env(:driftwood, :auth_required?)
    prev_fleet = Application.get_env(:driftwood, :fleet_operators)

    on_exit(fn ->
      restore(:operator_roster, prev_roster)
      restore(:auth_required?, prev_armed)
      restore(:fleet_operators, prev_fleet)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:driftwood, key)
  defp restore(key, val), do: Application.put_env(:driftwood, key, val)

  describe "§6.3a #4 checklist — all FIVE :operator_authority sites carry the [:driftwood] carrier" do
    test "the four router mounts + the conn-level app-env twin are ALL product-scoped" do
      router = File.read!(@router_path)
      config = File.read!(@config_path)

      scoped = "{Driftwood.Auth, :operator_role, [:driftwood]}"
      unscoped = "{Driftwood.Auth, :operator_role, []}"

      # Four scoped wirings in the router (the operator scope, chat mount, impersonate mount,
      # live-nav session) + one in config.exs — five in total, ZERO left unscoped.
      router_hits = count(router, scoped)
      config_hits = count(config, scoped)

      assert router_hits == 4,
             "expected 4 scoped :operator_authority wirings in router.ex, found #{router_hits}"

      assert config_hits == 1,
             "expected 1 scoped :operator_authority wiring in config.exs, found #{config_hits}"

      # No site left on the old unscoped resolver (the by-omission cross-product leak).
      refute String.contains?(router, unscoped),
             "router.ex still has an UNSCOPED :operator_authority wiring — a cross-product role by omission"

      refute String.contains?(config, unscoped),
             "config.exs still has an UNSCOPED :operator_authority wiring"
    end
  end

  describe "host resolver — a role in driftwood confers ZERO capability in another product" do
    test "operator_role(:driftwood, user) resolves the role; a foreign scope resolves nil" do
      Application.put_env(:driftwood, :auth_required?, true)
      Application.put_env(:driftwood, :operator_roster, %{@operator_user => :operator_admin})

      # CONTROL: driftwood scope grants the assigned role.
      assert Driftwood.Auth.operator_role(:driftwood, @operator_user) == :operator_admin

      # RED: the SAME operator on any other product scope resolves nil.
      assert Driftwood.Auth.operator_role(:pawchart, @operator_user) == nil
      assert Driftwood.Auth.operator_role(:some_other_app, @operator_user) == nil
    end

    test "even the DEV grant is per-product — a foreign scope is nil while unarmed" do
      Application.put_env(:driftwood, :auth_required?, false)
      Application.delete_env(:driftwood, :operator_roster)

      # dev convenience grants :operator_admin on driftwood ONLY.
      assert Driftwood.Auth.operator_role(:driftwood, "anyone") == :operator_admin
      assert Driftwood.Auth.operator_role(:pawchart, "anyone") == nil
    end
  end

  describe ":fleet_authority seam — the fleet-wide read reflects per-product grants" do
    test "an operator with a driftwood role sees the driftwood scope; :fleet is separately gated" do
      Application.put_env(:driftwood, :auth_required?, true)
      Application.put_env(:driftwood, :operator_roster, %{@operator_user => :operator_support})
      Application.put_env(:driftwood, :fleet_operators, %{@operator_user => :operator_admin})

      assert Driftwood.Auth.fleet_roles(@operator_user) == %{
               driftwood: :operator_support,
               fleet: :operator_admin
             }
    end

    test "the :fleet cockpit scope fails CLOSED when :fleet_operators is empty" do
      Application.put_env(:driftwood, :auth_required?, true)
      Application.put_env(:driftwood, :operator_roster, %{@operator_user => :operator_support})
      Application.delete_env(:driftwood, :fleet_operators)

      # a driftwood operator with no fleet grant does NOT reach the cockpit scope.
      assert Driftwood.Auth.fleet_roles(@operator_user) == %{driftwood: :operator_support}
    end

    test "a non-operator gets an empty fleet-role map (deny-by-default)" do
      Application.put_env(:driftwood, :auth_required?, true)
      Application.put_env(:driftwood, :operator_roster, %{})
      Application.delete_env(:driftwood, :fleet_operators)

      assert Driftwood.Auth.fleet_roles("nobody") == %{}
    end
  end

  defp count(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
