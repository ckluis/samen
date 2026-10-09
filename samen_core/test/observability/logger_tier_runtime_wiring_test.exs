defmodule Samen.NoPlaintextPii.Tiers.LoggerGovernanceRuntimeWiringTest do
  @moduledoc """
  ADR-052 §2.1.2 item 3 — the `:logger` tier's `check/1` itself reads the host's
  `config/runtime.exs` (next to its `config.exs`), not only `runtime_findings/1` in isolation.

  Drives `check/1` against a throwaway host project pushed onto the Mix project stack. That
  stack is global, so this module is `async: false` (ExUnit runs it after every async module).
  """
  use ExUnit.Case, async: false

  alias Samen.NoPlaintextPii.Context
  alias Samen.NoPlaintextPii.Tiers.LoggerGovernance

  @moduletag :tmp_dir

  defmodule HostProject do
    def project do
      [app: :logger_tier_host, version: "0.0.0", config_path: Process.get(:host_config_path)]
    end
  end

  defp check_host(tmp_dir, runtime_source) do
    config_dir = Path.join(tmp_dir, "config")
    File.mkdir_p!(config_dir)

    File.write!(
      Path.join(config_dir, "config.exs"),
      "import Config\nconfig :logger, level: :info\n"
    )

    if runtime_source, do: File.write!(Path.join(config_dir, "runtime.exs"), runtime_source)

    Process.put(:host_config_path, Path.join(config_dir, "config.exs"))
    Mix.Project.push(HostProject, Path.join(tmp_dir, "mix.exs"))

    try do
      context = %Context{repo: nil, resources: [], vault_routed: [], non_pii_exempt: [], deps: []}
      LoggerGovernance.check(context)
    after
      Mix.Project.pop()
    end
  end

  test "POSITIVE CONTROL: a host with no runtime.exs and an :info prod level passes", ctx do
    assert check_host(ctx.tmp_dir, nil) == []
  end

  test "a host whose runtime.exs sets the level from LOG_LEVEL fails the tier", ctx do
    assert [f] =
             check_host(ctx.tmp_dir, """
             import Config
             config :logger, level: String.to_atom(System.get_env("LOG_LEVEL", "info"))
             """)

    assert f.subject == "logger level (runtime.exs)"
  end
end
