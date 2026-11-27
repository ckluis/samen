defmodule Samen.HostDomainsTest do
  @moduledoc """
  `Samen.HostDomains` is the host's domain registry, under samen's OWN config key (`:host_domains`), never Ash's
  `:samen_core, :ash_domains` (which `Ash.Resource.verify` reads while samen_core compiles as a dependency: a host
  domain not compiled yet raised "is not a Spark DSL module", nine warning blocks per host build).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @root Path.expand("../..", __DIR__)

  setup do
    prev = for k <- [:host_domains, :ash_domains], do: {k, Application.fetch_env(:samen_core, k)}
    :persistent_term.erase({Samen.HostDomains, :warned})

    on_exit(fn ->
      for {k, v} <- prev do
        case v do
          {:ok, val} -> Application.put_env(:samen_core, k, val)
          :error -> Application.delete_env(:samen_core, k)
        end
      end

      :persistent_term.erase({Samen.HostDomains, :warned})
    end)

    :ok
  end

  test "the registry is :host_domains, de-duplicated, and does NOT read Ash's :ash_domains when it is set" do
    Application.put_env(:samen_core, :host_domains, [A.Dom, B.Dom, A.Dom])
    Application.put_env(:samen_core, :ash_domains, [Other.Dom])

    log = capture_log(fn -> assert Samen.HostDomains.registry() == [A.Dom, B.Dom] end)
    refute log =~ "deprecated"
  end

  test "an explicitly empty :host_domains is an empty registry (the old key is not consulted)" do
    Application.put_env(:samen_core, :host_domains, [])
    Application.put_env(:samen_core, :ash_domains, [Old.Dom])
    assert Samen.HostDomains.registry() == []
  end

  test "an un-renamed host (only :ash_domains) is still read, with ONE deprecation warning, never silently empty" do
    Application.delete_env(:samen_core, :host_domains)
    Application.put_env(:samen_core, :ash_domains, [Old.Dom])

    log =
      capture_log(fn ->
        assert Samen.HostDomains.registry() == [Old.Dom]
        assert Samen.HostDomains.registry() == [Old.Dom]
      end)

    assert log =~ "`config :samen_core, :ash_domains` is deprecated"
    assert length(String.split(log, "is deprecated")) == 2, "the warning is printed once"
  end

  test "neither key set is an empty registry, so the verifiers that fail on zero resources still fail" do
    Application.delete_env(:samen_core, :host_domains)
    Application.delete_env(:samen_core, :ash_domains)
    assert Samen.HostDomains.registry() == []
  end

  test "no samen_core lib file reads :samen_core's :ash_domains except Samen.HostDomains (the legacy fallback)" do
    offenders =
      for f <- Samen.SourceScan.files(Path.join(@root, "samen_core/lib"), ~w(.ex)),
          rel = Path.relative_to(f, @root),
          rel != "samen_core/lib/samen/host_domains.ex",
          src = Samen.SourceScan.read!(f),
          Regex.match?(~r/get_env\(:samen_core,\s*:ash_domains|fetch_env!?\(:samen_core,\s*:ash_domains/, src),
          do: rel

    assert offenders == [], "read Samen.HostDomains.registry/0 instead: #{inspect(offenders)}"
  end

  test "the three host configs and both generator templates register under :host_domains, not Ash's key" do
    for rel <- ~w(demo/config/config.exs driftwood/config/config.exs pawchart/config/config.exs
                  samen_core/priv/templates/config_exs.eex samen_core/priv/templates/config_exs_web.eex) do
      src = File.read!(Path.join(@root, rel))
      assert src =~ "config :samen_core, :host_domains,", "#{rel} does not set :host_domains"
      refute src =~ "config :samen_core, :ash_domains", "#{rel} still sets Ash's :ash_domains key"
    end
  end
end
