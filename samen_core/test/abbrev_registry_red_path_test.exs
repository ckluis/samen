defmodule Samen.AbbrevRegistryRedPathTest do
  @moduledoc """
  RED PATHS for the abbrev registry (T1.1): the compile-time verifier
  (`Samen.Verifiers.AbbrevRegistry`) must FAIL closed when a resource:

    * uses an abbrev NOT present in the committed registry (unreserved), or
    * uses an abbrev already registered to a DIFFERENT resource (collision /
      recycle), or
    * (defense in depth) changes its abbrev away from its registered one.

  If any of these compiles, abbrevs are not permanent and the idiom is broken.
  """
  use ExUnit.Case, async: false

  defp resource_src(mod, abbrev, table) do
    """
    defmodule #{mod} do
      use Samen.Resource,
        otp_app: :samen_core,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        abbrev: #{inspect(abbrev)}

      postgres do
        table #{inspect(table)}
        repo SamenCore.TestRepo
      end

      attributes do
        attribute :name, :string, public?: true
      end
    end
    """
  end

  test "red path: an abbrev NOT in the registry fails compile" do
    err =
      assert_raise CompileError, fn ->
        Code.compile_string(resource_src("RedPath.UnregisteredAbbrev", "zzz", "zzz_thing"))
      end

    assert err.description =~ "not in the abbrev registry"
    assert err.description =~ "permanent"
  end

  test "red path: an abbrev registered to a DIFFERENT resource fails compile (collision)" do
    # "com" is registered to SamenCore.Support.Crm.Contact. A different module
    # claiming it must be rejected — abbrevs are one-owner-forever.
    err =
      assert_raise CompileError, fn ->
        Code.compile_string(resource_src("RedPath.CollidingAbbrev", "com", "com_impostor"))
      end

    assert err.description =~ "registered to SamenCore.Support.Crm.Contact"
    assert err.description =~ "never recycled"
  end

  # --- Anti-tautology control ------------------------------------------------
  # Prove the red paths fail for the RIGHT reason: a properly-registered abbrev on
  # its own resource compiles. (Contact is already compiled in support; recompiling
  # its source shape here would redefine it, so we assert the pure decision instead
  # — the compiled Contact fixture in resource_test.exs is the live green proof.)
  test "control: the committed fixtures are all registered to themselves (green path)" do
    reg = Samen.AbbrevRegistry.load()

    for {resource, abbrev} <- [
          {SamenCore.Support.Crm.Contact, "com"},
          {SamenCore.Support.Crm.Company, "cpy"},
          {SamenCore.Support.Clinical.Patient, "pat"},
          {SamenCore.Support.Clinical.Staff, "stf"}
        ] do
      assert Samen.AbbrevRegistry.validate(reg, abbrev, inspect(resource)) == :ok
    end
  end
end
