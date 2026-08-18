defmodule Samen.Fleet.ResolutionTest do
  @moduledoc """
  T83 / J3 / Amendment 1 — `Samen.Fleet.Resolution.scope_of/2`, the `:fleet_resolution` SEAM
  SHAPE (ADR-044 §16.2, §6.3a #2).

  **T83 ships the seam READER + shape validator + fail-closed posture — NOT the answer.** The
  host resolver behind the seam (the `{:accounts, set}` book of business), the assignment resource
  it reads (operator ruling R-A, §16.5 #1), and the `gate/2` scope-conjunct composition
  (`may_drill_in?`, §16.4a) are all T84. This suite pins ONLY the contract T83 owns: the closed
  shape `:all | {:accounts, MapSet} | :none`, and that ANY deviation fails CLOSED to `:none`
  (mask-by-omission, ADR-028 — a resolver bug fails toward masking, never toward all names).

  SABOTAGE-REFUTABLE: widen the validator to pass an unvalidated resolver return through and the
  "fail closed on bad shape" rows flip — proven by
  `scripts/sabotages/119-t83-j3-fleet-resolution-shape-validation-drop.patch`.
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.Resolution

  @otp_app :samen_core

  setup do
    prev = Application.get_env(@otp_app, :fleet_resolution)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(@otp_app, :fleet_resolution)
        val -> Application.put_env(@otp_app, :fleet_resolution, val)
      end
    end)

    :ok
  end

  defp wire(mfa), do: Application.put_env(@otp_app, :fleet_resolution, mfa)

  # Host resolvers returning each pole of the closed shape.
  def all_scope(_p), do: :all
  def none_scope(_p), do: :none
  def accounts_scope(_p), do: {:accounts, MapSet.new(["org-a", "org-b"])}
  def accounts_bad_members(_p), do: {:accounts, MapSet.new(["org-a", :not_binary])}
  def accounts_as_list(_p), do: {:accounts, ["org-a", "org-b"]}
  def garbage(_p), do: {:something_else, 42}
  def nil_scope(_p), do: nil
  def boom(_p), do: raise("resolver blew up")

  describe "GREEN — each pole of the closed shape passes through validated" do
    test ":all (operator-admin/support parity with /operator/accounts)" do
      wire({__MODULE__, :all_scope, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :all
    end

    test "{:accounts, MapSet} (the salesperson's book of business)" do
      wire({__MODULE__, :accounts_scope, []})
      assert Resolution.scope_of(@otp_app, "op-1") == {:accounts, MapSet.new(["org-a", "org-b"])}
    end

    test ":none (the fleet-only viewer — health, no identity)" do
      wire({__MODULE__, :none_scope, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end
  end

  describe "FAIL CLOSED to :none — anything out of shape masks" do
    test "no seam wired at all (a host that wires nothing gets NO names, never all)" do
      Application.delete_env(@otp_app, :fleet_resolution)
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end

    test "an {:accounts, set} with a non-binary member" do
      wire({__MODULE__, :accounts_bad_members, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end

    test "an {:accounts, LIST} (not a MapSet) — the wrong container is refused, not coerced" do
      wire({__MODULE__, :accounts_as_list, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end

    test "an unrecognized tuple" do
      wire({__MODULE__, :garbage, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end

    test "a nil return" do
      wire({__MODULE__, :nil_scope, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end

    test "a non-MFA config value" do
      wire(:not_an_mfa)
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end

    test "an erroring resolver" do
      wire({__MODULE__, :boom, []})
      assert Resolution.scope_of(@otp_app, "op-1") == :none
    end
  end

  describe "validate_scope/1 — one shared definition of valid shape (T84 reuses it)" do
    test "the poles validate; deviations become :none" do
      assert Resolution.validate_scope(:all) == :all
      assert Resolution.validate_scope(:none) == :none
      assert Resolution.validate_scope({:accounts, MapSet.new(["x"])}) == {:accounts, MapSet.new(["x"])}
      assert Resolution.validate_scope({:accounts, ["x"]}) == :none
      assert Resolution.validate_scope(:whatever) == :none
      assert Resolution.validate_scope(nil) == :none
    end
  end
end
