defmodule Samen.AbbrevRegistryTest do
  @moduledoc """
  T1.1 abbrev REGISTRY acceptance: abbrevs are permanent, 3-letter lowercase,
  collision-checked, and never recycled. The pure `validate/3` is unit-tested
  exhaustively; the compile-time enforcement (Samen.Verifiers.AbbrevRegistry) is
  driven end-to-end in `abbrev_registry_red_path_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Samen.AbbrevRegistry, as: Reg

  @registry %{
    "com" => "MyApp.Crm.Contact",
    "cpy" => "MyApp.Crm.Company"
  }

  test "the committed registry file loads and contains the fixture abbrevs" do
    loaded = Reg.load()
    assert loaded["com"] == "SamenCore.Support.Crm.Contact"
    assert loaded["cpy"] == "SamenCore.Support.Crm.Company"
    assert loaded["pat"] == "SamenCore.Support.Clinical.Patient"
    assert loaded["stf"] == "SamenCore.Support.Clinical.Staff"
  end

  test "valid_shape? enforces exactly 3 lowercase letters" do
    assert Reg.valid_shape?("com")
    refute Reg.valid_shape?("co")
    refute Reg.valid_shape?("comm")
    refute Reg.valid_shape?("COM")
    refute Reg.valid_shape?("c0m")
    refute Reg.valid_shape?("c_m")
    refute Reg.valid_shape?(nil)
    refute Reg.valid_shape?(:com)
  end

  # --- validate/3: the fail-closed decision function -------------------------

  test "validate: a registered abbrev owned by this exact resource is OK" do
    assert Reg.validate(@registry, "com", "MyApp.Crm.Contact") == :ok
  end

  test "validate: an unregistered abbrev fails (must be reserved first)" do
    assert {:error, reason} = Reg.validate(@registry, "zzz", "MyApp.New.Thing")
    assert reason =~ "not in the abbrev registry"
    assert reason =~ "permanent"
  end

  test "validate: an abbrev owned by a DIFFERENT resource fails (collision / recycle)" do
    assert {:error, reason} = Reg.validate(@registry, "com", "MyApp.Other.Resource")
    assert reason =~ "registered to MyApp.Crm.Contact"
    assert reason =~ "never recycled"
  end

  test "validate: a malformed abbrev fails on shape before anything else" do
    assert {:error, reason} = Reg.validate(@registry, "COM", "MyApp.Whatever")
    assert reason =~ "not 3 lowercase letters"
  end

  test "validate: changing a resource's abbrev to a new (unregistered) one fails" do
    # Contact is registered as "com"; asking to use "abc" (unregistered) fails.
    assert {:error, reason} = Reg.validate(@registry, "abc", "MyApp.Crm.Contact")
    assert reason =~ "not in the abbrev registry"
  end

  test "load/1 raises fail-closed on a missing registry file" do
    assert_raise RuntimeError, ~r/missing or unreadable/, fn ->
      Reg.load("/nonexistent/path/abbrev_registry.json")
    end
  end

  test "load/1 raises fail-closed on malformed JSON" do
    path = Path.join(System.tmp_dir!(), "bad_registry_#{System.unique_integer([:positive])}.json")
    File.write!(path, "{ not json ")

    try do
      assert_raise RuntimeError, ~r/not valid JSON/, fn -> Reg.load(path) end
    after
      File.rm(path)
    end
  end

  test "load/1 raises fail-closed when the abbrevs key is missing" do
    path = Path.join(System.tmp_dir!(), "shape_registry_#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"other": {}}))

    try do
      assert_raise RuntimeError, ~r/must be a JSON object with an "abbrevs" map/, fn ->
        Reg.load(path)
      end
    after
      File.rm(path)
    end
  end
end
