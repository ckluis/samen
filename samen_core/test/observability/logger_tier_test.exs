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
end
