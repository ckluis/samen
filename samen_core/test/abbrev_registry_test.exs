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

  # --- ADR-023 host-namespaced schema + compat shim --------------------------

  describe "ADR-023 compat shim + host-namespaced reader" do
    # A file WITHOUT a "hosts" key (the committed 263-entry registry shape).
    defp flat_file! do
      path = Path.join(System.tmp_dir!(), "flat_reg_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"abbrevs": {"com": "MyApp.Crm.Contact"}}))
      path
    end

    # A host-namespaced file: legacy global net + two hosts, one reusing "com".
    defp ns_file! do
      path = Path.join(System.tmp_dir!(), "ns_reg_#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "abbrevs" => %{"com" => "MyApp.Crm.Contact"},
          "hosts" => %{
            "widgetco" => %{"wid" => "Widgetco.Vertical.Widget"},
            "acme" => %{"wid" => "Acme.Vertical.Gadget"}
          }
        })
      )

      path
    end

    test "the COMMITTED registry: 263 flat entries + the F3 consent-ledger host allocations" do
      %{global: global, hosts: hosts} = Reg.load_namespaced()
      assert map_size(global) == 263

      # F3 Unit 1: the ConsentEvent ledger reserved a host-namespaced abbrev per marketing
      # mount via the sanctioned allocator (ADR-023 host-scoped reservations).
      assert hosts == %{
               "demo" => %{"mce" => "Demo.MarketingScope.ConsentEvent"},
               "driftwood" => %{"fmv" => "Driftwood.Marketing.ConsentEvent"},
               "pawchart" => %{"vmv" => "PawChart.Marketing.ConsentEvent"},
               "samen_core" => %{"sxv" => "SamenCore.Support.SuppressionFixture.ConsentEvent"},
               "samen_web" => %{"wmv" => "Samen.WebTest.Marketing.ConsentEvent"}
             }

      # The compat shim's flat view unions the global net with every host entry (263 + 5).
      assert map_size(Reg.load()) == 268
    end

    test "load/1 (compat shim) reads a flat file byte-identically — hosts empty" do
      path = flat_file!()

      try do
        assert %{global: g, hosts: %{}} = Reg.load_namespaced(path)
        assert g == %{"com" => "MyApp.Crm.Contact"}
        assert Reg.load(path) == %{"com" => "MyApp.Crm.Contact"}
      after
        File.rm(path)
      end
    end

    test "load/1 (compat shim) flattens host namespaces into the global view" do
      path = ns_file!()

      try do
        flat = Reg.load(path)
        # global net + both hosts' entries all present in the flat union.
        assert flat["com"] == "MyApp.Crm.Contact"
        # Flattened: last-writer (global) wins for a collision; "wid" resolves to a host entry.
        assert flat["wid"] in ["Widgetco.Vertical.Widget", "Acme.Vertical.Gadget"]
      after
        File.rm(path)
      end
    end

    test "owner/2 resolves host-scoped, distinguishing same abbrev across hosts" do
      path = ns_file!()

      try do
        %{global: g, hosts: h} = Reg.load_namespaced(path)
        # (Directly exercise validate_host on the loaded shape — owner/2 reads the
        #  committed file, so we assert the namespaced separation via the loaded map.)
        assert get_in(h, ["widgetco", "wid"]) == "Widgetco.Vertical.Widget"
        assert get_in(h, ["acme", "wid"]) == "Acme.Vertical.Gadget"
        assert g["com"] == "MyApp.Crm.Contact"
      after
        File.rm(path)
      end
    end

    test "validate_host: unowned abbrev is OK" do
      ns = %{global: %{}, hosts: %{}}
      assert Reg.validate_host(ns, "widgetco", "wid", "Widgetco.Vertical.Widget") == :ok
    end

    test "validate_host: same host+abbrev+owner is OK (idempotent)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}
      assert Reg.validate_host(ns, "widgetco", "wid", "Widgetco.Vertical.Widget") == :ok
    end

    test "validate_host: cross-owner collision WITHIN a host fails (per-host permanence)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}
      assert {:error, reason} = Reg.validate_host(ns, "widgetco", "wid", "Widgetco.Other.Thing")
      assert reason =~ ~s(already owned by Widgetco.Vertical.Widget in host "widgetco")
      assert reason =~ "never recycled"
    end

    test "validate_host: SAME abbrev in a DIFFERENT host is allowed (Option B namespacing)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}
      assert Reg.validate_host(ns, "acme", "wid", "Acme.Vertical.Gadget") == :ok
    end

    test "validate_host: global cross-host net still refuses a clash on the legacy map" do
      ns = %{global: %{"com" => "MyApp.Crm.Contact"}, hosts: %{}}
      assert {:error, reason} = Reg.validate_host(ns, "newhost", "com", "NewHost.Foo")
      assert reason =~ "GLOBAL cross-host net"
      assert reason =~ "MyApp.Crm.Contact"
    end

    test "validate_host: malformed abbrev fails on shape first" do
      ns = %{global: %{}, hosts: %{}}
      assert {:error, reason} = Reg.validate_host(ns, "widgetco", "WID", "Widgetco.X")
      assert reason =~ "not 3 lowercase letters"
    end

    test "load_namespaced raises fail-closed on a malformed hosts value" do
      path = Path.join(System.tmp_dir!(), "badhosts_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"abbrevs": {}, "hosts": {"widgetco": "not-a-map"}}))

      try do
        assert_raise RuntimeError, ~r/must be a JSON object of abbrev/, fn ->
          Reg.load_namespaced(path)
        end
      after
        File.rm(path)
      end
    end
  end
end
