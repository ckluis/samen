defmodule Samen.NoPlaintextPii.Tiers.LoggerGovernanceTest do
  @moduledoc """
  ADR-052 §2.1 (P1 item 3) — red path **R4**: the `no_plaintext_pii` tier `:logger` fails a
  `filter_parameters` that is not a `{:keep, _}` keep-list, and a prod Logger level below
  `:info`. Each denial pairs with a positive control (the framework keep-list + `:info` pass),
  and the real samen_core prod config is read end-to-end through the tier.
  """
  use ExUnit.Case, async: true

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Tiers.LoggerGovernance

  @keep {:keep, ~w(id org org_id page per_page limit cursor after before sort sort_by order dir)}
  @good_prod [logger: [level: :info], phoenix: [filter_parameters: @keep]]

  defp subjects(findings), do: Enum.map(findings, & &1.subject)

  describe "POSITIVE CONTROL" do
    test "the framework keep-list + an :info prod level pass" do
      assert LoggerGovernance.check_config({:ok, @good_prod}, @keep, true) == []
    end

    test "every level at or above :info passes" do
      for level <- [:info, :notice, :warning, :error, :critical, :alert, :emergency, :none] do
        prod = put_in(@good_prod, [:logger, :level], level)
        assert LoggerGovernance.check_config({:ok, prod}, @keep, true) == [], "#{level}"
      end
    end

    test "the tier is in the default no_plaintext_pii roster as :logger" do
      assert LoggerGovernance in NoPlaintextPii.default_tiers()
      assert LoggerGovernance.tier_name() == :logger
    end

    test "end-to-end: the real samen_core prod config passes the level check" do
      # samen_core is not a Phoenix app (deps: [] → the filter check does not apply); its
      # config/prod.exs is read for env :prod through Config.Reader.
      {:ok, findings} = NoPlaintextPii.run(tiers: [LoggerGovernance], deps: [], domains: [])
      assert NoPlaintextPii.violations(findings) == []
    end
  end

  describe "R4 — filter_parameters must be a {:keep, _} keep-list" do
    test "Phoenix's default deny-list shape fails (prod config AND running env)" do
      prod = put_in(@good_prod, [:phoenix, :filter_parameters], ["password"])

      findings = LoggerGovernance.check_config({:ok, prod}, ["password"], true)
      assert "filter_parameters (prod config)" in subjects(findings)
      assert "filter_parameters (running app env)" in subjects(findings)
    end

    test "an unset filter (nil — Phoenix then filters only \"password\") fails" do
      prod = put_in(@good_prod, [:phoenix], [])
      assert [_ | _] = LoggerGovernance.check_config({:ok, prod}, @keep, true)
    end

    test "a {:discard, _} filter fails" do
      assert [f] =
               LoggerGovernance.check_config({:ok, @good_prod}, {:discard, ["password"]}, true)

      assert f.subject == "filter_parameters (running app env)"
    end

    test "a keep-list that keeps a PII-named or secret-named key fails" do
      for key <- ["email", "phone", "password", "api_token"] do
        bad = {:keep, ["id", key]}
        prod = put_in(@good_prod, [:phoenix, :filter_parameters], bad)

        assert [f] = LoggerGovernance.check_config({:ok, prod}, @keep, true)
        assert f.detail =~ key
      end
    end

    test "the filter check only applies when Phoenix is a dependency" do
      prod = put_in(@good_prod, [:phoenix, :filter_parameters], ["password"])
      assert LoggerGovernance.check_config({:ok, prod}, nil, false) == []
    end
  end

  describe "R4 — the prod Logger level must be :info or above" do
    test ":debug fails" do
      prod = put_in(@good_prod, [:logger, :level], :debug)

      assert ["logger level (prod config)"] =
               subjects(LoggerGovernance.check_config({:ok, prod}, @keep, true))
    end

    test "an UNSET level fails (Logger's default logs everything)" do
      prod = Keyword.delete(@good_prod, :logger)

      assert ["logger level (prod config)"] =
               subjects(LoggerGovernance.check_config({:ok, prod}, @keep, false))
    end

    test ":all fails" do
      prod = put_in(@good_prod, [:logger, :level], :all)
      assert [_] = LoggerGovernance.check_config({:ok, prod}, @keep, false)
    end
  end

  test "fail closed: an unreadable prod config is a violation, not a pass" do
    assert [f] = LoggerGovernance.check_config({:error, :enoent}, @keep, true)
    assert f.severity == :violation
    assert f.subject == "prod config"
  end

  describe "config/runtime.exs can not lower the prod level (ADR-052 §2.1.2 item 3)" do
    defp runtime(source), do: LoggerGovernance.runtime_findings({:ok, source})

    test "POSITIVE CONTROL: no runtime.exs, a logger-free one, literals ≥ :info and the clamp pass" do
      assert LoggerGovernance.runtime_findings(:absent) == []

      # The generated --deploy runtime.exs (fail-closed secrets, OTLP mapping) sets no level.
      assert runtime(deploy_runtime_exs()) == []

      assert runtime("""
             import Config
             if config_env() == :prod do
               config :logger, level: :warning
               config :logger, :default_handler, level: :info
               config :logger, :default_formatter, format: "$message\\n", metadata: [:request_id]
               Logger.put_module_level(MyApp.Noisy, :error)
               :logger.set_primary_config(:level, :notice)
               config :logger,
                 level: Samen.Observability.prod_log_level(System.get_env("LOG_LEVEL"))
             end
             """) == []
    end

    test "an env-var level (LOG_LEVEL) is refused — it cannot be proven ≥ :info" do
      assert [f] =
               runtime("""
               import Config
               config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info"))
               """)

      assert f.severity == :violation
      assert f.subject == "logger level (runtime.exs)"
      assert f.detail =~ "LOG_LEVEL"
    end

    test "a literal level below :info is refused, wherever runtime.exs sets it" do
      for source <- [
            "config :logger, level: :debug",
            "if config_env() == :prod, do: config(:logger, level: :all)",
            "config :logger, :default_handler, level: :debug",
            "Logger.configure(level: :debug)",
            "Logger.put_application_level(:my_app, :debug)",
            ":logger.set_primary_config(:level, :debug)",
            ":logger.set_primary_config(%{level: :debug})",
            ":logger.set_handler_config(:default, :level, :all)",
            ":logger.set_module_level(MyApp.Repo, :debug)"
          ] do
        assert [_] = runtime(source), "not refused: #{source}"
      end
    end

    test "fail closed: non-literal options, an unparsable file, an unreadable file" do
      assert [_] = runtime("opts = [level: :debug]\nconfig :logger, opts")
      assert [_] = runtime("Logger.configure(Application.get_env(:my_app, :log))")
      assert [_] = runtime(":logger.update_primary_config(cfg)")
      assert [_] = runtime("config :logger, level: (")
      assert [_] = LoggerGovernance.runtime_findings({:error, :eacces})
    end

    test "the clamp itself never yields a level below :info" do
      assert Samen.Observability.prod_log_level("warning") == :warning
      assert Samen.Observability.prod_log_level(" ERROR ") == :error

      for v <- ["debug", "all", "", "alice", nil] do
        assert Samen.Observability.prod_log_level(v) == :info
      end
    end
  end

  # The --deploy runtime.exs the generator emits (rendered with placeholder bindings).
  defp deploy_runtime_exs do
    {"config/runtime.exs", template} =
      Samen.Gen.Templates.files(true, false, true)
      |> Enum.find(&match?({"config/runtime.exs", _}, &1))

    Samen.Gen.App.render(template, module: "MyApp", otp_app: "my_app")
  end
end
