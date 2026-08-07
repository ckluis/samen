defmodule Samen.Fleet.AuthzTest do
  @moduledoc """
  T83 / J3 — `Samen.Fleet.Authz.roles_for/2`, the fleet-wide read of the host operator grant
  store via the `:fleet_authority` seam (ADR-044 §6.2, §6.3a #1).

  The seam is HOST-owned and FAILS CLOSED: no seam ⇒ `%{}` ⇒ no cockpit, no tiles. Each
  `{scope, role}` pair is validated (atom scope, real operator role) and invalid entries are
  DROPPED (mask-by-omission, ADR-028: a resolver bug fails toward LESS access, never more).

  SABOTAGE-REFUTABLE: make the reader admit an unvalidated map (skip role validation) and the
  "invalid entries dropped" rows flip — proven by
  `scripts/sabotages/118-t83-j3-fleet-authority-validation-drop.patch`.
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.Authz

  @otp_app :samen_core

  setup do
    prev = Application.get_env(@otp_app, :fleet_authority)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(@otp_app, :fleet_authority)
        val -> Application.put_env(@otp_app, :fleet_authority, val)
      end
    end)

    :ok
  end

  defp wire(mfa), do: Application.put_env(@otp_app, :fleet_authority, mfa)

  # A host resolver in the §6.2 grant-store shape.
  def resolve(principal_id) do
    %{
      "op-1" => %{driftwood: :operator_admin, fleet: :operator_admin},
      "op-2" => %{driftwood: :operator_support}
    }
    |> Map.get(principal_id, %{})
  end

  def resolve_dirty(_principal_id) do
    # A mix of valid + invalid entries — validation must keep only the good ones.
    %{
      # valid
      :driftwood => :operator_admin,
      # invalid role value → dropped
      :pawchart => :superuser,
      # non-atom scope → dropped
      "string_scope" => :operator_support,
      # valid
      :fleet => :operator_readonly
    }
  end

  describe "GREEN — a wired seam returns the validated per-product role map" do
    test "the fleet-wide read reflects the host grant store, scope by scope" do
      wire({__MODULE__, :resolve, []})

      assert Authz.roles_for(@otp_app, "op-1") == %{driftwood: :operator_admin, fleet: :operator_admin}
      assert Authz.roles_for(@otp_app, "op-2") == %{driftwood: :operator_support}
    end

    test "an operator with no grant gets an EMPTY map (deny-by-default), not an error" do
      wire({__MODULE__, :resolve, []})
      assert Authz.roles_for(@otp_app, "nobody") == %{}
    end
  end

  describe "VALIDATION — invalid entries are dropped, not admitted" do
    test "a non-role value and a non-atom scope are both dropped; valid entries survive" do
      wire({__MODULE__, :resolve_dirty, []})

      assert Authz.roles_for(@otp_app, "anyone") == %{
               driftwood: :operator_admin,
               fleet: :operator_readonly
             }
    end
  end

  describe "FAIL CLOSED — anything malformed collapses to %{}" do
    test "no seam wired at all" do
      Application.delete_env(@otp_app, :fleet_authority)
      assert Authz.roles_for(@otp_app, "op-1") == %{}
    end

    test "a non-MFA config value" do
      wire(:not_an_mfa)
      assert Authz.roles_for(@otp_app, "op-1") == %{}
    end

    test "an erroring resolver" do
      wire({__MODULE__, :boom, []})
      assert Authz.roles_for(@otp_app, "op-1") == %{}
    end

    test "a resolver returning a non-map" do
      wire({__MODULE__, :not_a_map, []})
      assert Authz.roles_for(@otp_app, "op-1") == %{}
    end

    test "a nil/non-atom otp_app" do
      assert Authz.roles_for(nil, "op-1") == %{}
    end
  end

  def boom(_principal_id), do: raise("resolver blew up")
  def not_a_map(_principal_id), do: [:not, :a, :map]
end
