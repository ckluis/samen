defmodule Samen.Web.Reads.SwallowLintTest do
  @moduledoc """
  The WP6 swallow ratchet (`Samen.Web.Reads.SwallowLint`): a NEW bare `rescue _ -> []` anywhere
  in samen_web / driftwood / pawchart fails this suite; a converted file cannot re-grow one; the
  baseline only shrinks. Red path, anti-tautology twin, and the live sweep.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Reads.SwallowLint

  # The audit's shape: an outage becomes "No contacts yet".
  @swallow ~S"""
  defmodule Fixture.Swallow do
    def contacts(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      _ -> []
    end

    def contacts_tryblock(scope) do
      try do
        Ash.read!(Person, scope: scope)
      rescue
        _error -> %{}
      catch
        :exit, _ -> nil
      end
    end
  end
  """

  # The SAME module converted: logs/reports, re-raises, hands the exception on, or names the error.
  @handled ~S"""
  defmodule Fixture.Handled do
    require Logger

    def a(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      e ->
        Logger.error("read failed: #{inspect(e.__struct__)}")
        []
    end

    def b(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      e -> Samen.Web.Reads.Guard.report(:b, scope, e)
    end

    def c(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      e -> {:error, e}
    end

    def d(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      _ -> reraise ArgumentError, "x", __STACKTRACE__
    end

    def e(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      ArgumentError -> []
    end

    def f(scope) do
      Ash.read!(Person, scope: scope)
    rescue
      e in [ArgumentError, RuntimeError] -> {:error, e}
    end
  end
  """

  describe "scan_source/2" do
    test "RED: flags a function-level `rescue _ -> []`, a `try` rescue and a catch-all catch" do
      swallows = SwallowLint.scan_source(@swallow)
      assert Enum.map(swallows, & &1.fun) |> Enum.sort() == [:contacts, :contacts_tryblock, :contacts_tryblock]
    end

    test "GREEN twin: logged, reported, handed-on, re-raised and typed clauses are not swallows" do
      assert SwallowLint.scan_source(@handled) == []
    end
  end

  describe "check/2 — the ratchet" do
    test "a file over its baseline (or not listed) fails and names the fix" do
      assert {:error, [msg]} = SwallowLint.check(%{"a.ex" => 2}, %{"a.ex" => 1})
      assert msg =~ "a.ex"
      assert msg =~ "Guard.run"

      assert {:error, [_]} = SwallowLint.check(%{"new.ex" => 1}, %{})
    end

    test "a file UNDER its baseline fails too: the baseline must be lowered (shrink-only)" do
      assert {:error, [msg]} = SwallowLint.check(%{"a.ex" => 1}, %{"a.ex" => 3})
      assert msg =~ "lower it to 1"
      assert {:error, [_]} = SwallowLint.check(%{}, %{"gone.ex" => 1})
    end

    test "equal counts pass" do
      assert :ok = SwallowLint.check(%{"a.ex" => 2}, %{"a.ex" => 2})
      assert :ok = SwallowLint.check(%{}, %{})
    end
  end

  describe "the live sweep" do
    test "non-vacuity: the scan sees the tree and finds the debt the baseline records" do
      files = SwallowLint.files()
      assert length(files) > 300
      assert Enum.any?(files, &String.ends_with?(&1, "crm/reads.ex"))
      assert Enum.any?(files, &String.ends_with?(&1, "driftwood/lib/driftwood/reads.ex"))
      # The scanner sees the whole tree: the UNFILTERED swallow count (reviewed ones included) stays
      # large however far the baseline is paid down, so a scanner that stopped matching could not
      # hide behind a baseline that reached zero.
      root = SwallowLint.repo_root()

      unfiltered =
        files
        |> Enum.map(&length(SwallowLint.scan_source(File.read!(Path.join(root, &1)), &1)))
        |> Enum.sum()

      assert unfiltered > 60
      assert Enum.sum(Map.values(SwallowLint.scan())) > 0
    end

    test "the converted read modules are swallow-free (WP6 phase 1)" do
      counts = SwallowLint.scan()

      for converted <- ~w(
            samen_web/lib/samen/web/crm/reads.ex
            samen_web/lib/samen/web/crm/sequences_reads.ex
            samen_web/lib/samen/web/support/reads.ex
            samen_web/lib/samen/web/search/search_live.ex
            samen_web/lib/samen/web/list_live.ex
          ) do
        assert Map.get(counts, converted, 0) == 0, "#{converted} grew a swallowing rescue"
      end
    end

    test "the tree matches the baseline exactly (no new swallow, no un-lowered row)" do
      assert :ok = SwallowLint.check()
    end
  end
end
