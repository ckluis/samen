defmodule Samen.CdcNeverReadCurrentTest do
  @moduledoc """
  T6.5 — the never-read-current lint (doc line 635 "never read a 'current' value
  from the analytics tier").

  Green: an analytics-marked module reading the CDC repo is clean. Red: an un-marked
  module reading the CDC repo is a `:current_read` violation. Anti-tautology: the
  SAME source that PASSES when marked FAILS when the marker is removed.
  """
  use ExUnit.Case, async: true

  alias Samen.Cdc.NeverReadCurrent

  @cdc_repo MyApp.CdcRepo

  # A module that reads the CDC repo but is NOT analytics-marked → violation.
  @unmarked """
  defmodule App.Billing do
    def current_balance(id) do
      MyApp.CdcRepo.get(Ledger, id)
    end
  end
  """

  # The SAME read, in a module marked @cdc_analytics_read → clean.
  @marked_attr """
  defmodule App.Reports.Revenue do
    @cdc_analytics_read true
    def mrr do
      MyApp.CdcRepo.all(RevenueRollup)
    end
  end
  """

  # Marked via `use Samen.Cdc.Analytics` → clean.
  @marked_use """
  defmodule App.Reports.Funnel do
    use Samen.Cdc.Analytics
    def counts do
      MyApp.CdcRepo.aggregate(Events, :count)
    end
  end
  """

  # A read against the LIVE (primary) repo is not the CDC repo → never flagged.
  @live_read """
  defmodule App.Orders do
    def get(id), do: MyApp.Repo.get(Order, id)
  end
  """

  # An aliased CDC repo (`alias MyApp.CdcRepo, as: Analytics`) is still the CDC repo.
  @aliased """
  defmodule App.Dash do
    alias MyApp.CdcRepo, as: Analytics
    def latest, do: Analytics.one(LatestSnapshot)
  end
  """

  defp scan(src), do: NeverReadCurrent.scan_source("mem.ex", src, @cdc_repo)

  describe "never-read-current lint" do
    test "an un-marked module reading the CDC repo is a :current_read violation" do
      findings = scan(@unmarked)
      assert Enum.any?(findings, &(&1.kind == :current_read))
      v = Enum.find(findings, &(&1.kind == :current_read))
      assert v.message =~ "never read a 'current' value"
    end

    test "a module marked @cdc_analytics_read is clean" do
      assert scan(@marked_attr) == []
    end

    test "a module marked `use Samen.Cdc.Analytics` is clean" do
      assert scan(@marked_use) == []
    end

    test "a read against the primary (non-CDC) repo is never flagged" do
      assert scan(@live_read) == []
    end

    @tag :red_path
    test "an aliased CDC repo read in an un-marked module is still flagged" do
      findings = scan(@aliased)
      assert Enum.any?(findings, &(&1.kind == :current_read))
    end

    test "tier off (repo == nil) → nothing is scanned (no false positives)" do
      assert NeverReadCurrent.scan_source("mem.ex", @unmarked, nil) == []
    end
  end

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: the same source PASSES when marked and FAILS when the marker is removed" do
    # Marked: clean.
    assert scan(@marked_attr) == []

    # Remove the marker line → the identical read now flips to a violation.
    unmarked = String.replace(@marked_attr, "  @cdc_analytics_read true\n", "")
    findings = scan(unmarked)

    assert Enum.any?(findings, &(&1.kind == :current_read)),
           "removing the analytics marker must flip the lint to a violation — proving it " <>
             "discriminates on the marker, not always-passes"
  end
end
