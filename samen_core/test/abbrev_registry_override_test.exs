defmodule Samen.AbbrevRegistryOverrideTest do
  @moduledoc """
  ADR-053 P5 — `SAMEN_ABBREV_REGISTRY` is the seam that lets the gen probes (flagship/post/deploy) run
  concurrently: `scripts/gen_probe_guard.sh` points each at a PRIVATE copy of the registry, so the committed
  `priv/abbrev_registry.json` is never written and two probes cannot clobber each other's reservations.

  `async: false` on purpose: the variable is process-global, and ExUnit runs the synchronous modules only after
  every async module finished, so no concurrent `Samen.AbbrevRegistry.load/0` can see the override.
  """
  use ExUnit.Case, async: false

  alias Samen.AbbrevRegistry, as: Reg

  @env "SAMEN_ABBREV_REGISTRY"

  setup do
    prior = System.get_env(@env)
    System.delete_env(@env)

    on_exit(fn ->
      if prior, do: System.put_env(@env, prior), else: System.delete_env(@env)
    end)

    :ok
  end

  defp private_registry! do
    dir = Path.join(System.tmp_dir!(), "abbrev_override_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "registry.json")
    File.write!(path, ~s({"abbrevs": {"zqx": "Override.Only.Owner"}}))
    path
  end

  test "unset: path/0 is the committed registry and load/0 reads it" do
    assert String.ends_with?(Reg.path(), "/priv/abbrev_registry.json")
    assert Reg.load()["com"] == "SamenCore.Support.Crm.Contact"
    refute Map.has_key?(Reg.load(), "zqx")
  end

  test "an absolute override is what path/0, load/0 and load_namespaced/0 read — the committed file is not" do
    private = private_registry!()
    committed = Reg.path()
    committed_before = File.read!(committed)

    System.put_env(@env, private)

    assert Reg.path() == private
    assert Reg.load() == %{"zqx" => "Override.Only.Owner"}
    assert Reg.load_namespaced().global == %{"zqx" => "Override.Only.Owner"}
    # the committed registry is byte-identical: reading through the override never writes it
    System.delete_env(@env)
    assert Reg.path() == committed
    assert File.read!(committed) == committed_before
  end

  test "an empty override is ignored (a blank variable must never point the registry at '')" do
    System.put_env(@env, "")
    assert String.ends_with?(Reg.path(), "/priv/abbrev_registry.json")
  end

  test "a relative override is refused — fail closed, never resolved against an unknown cwd" do
    System.put_env(@env, "registry.json")
    assert_raise RuntimeError, ~r/must be an absolute path/, fn -> Reg.path() end
    assert_raise RuntimeError, ~r/must be an absolute path/, fn -> Reg.load() end
  end

  test "an override to a missing file fails closed (the registry can never read as empty)" do
    System.put_env(@env, Path.join(System.tmp_dir!(), "no_such_registry_#{System.unique_integer([:positive])}.json"))
    assert_raise RuntimeError, ~r/missing or unreadable/, fn -> Reg.load() end
  end
end
