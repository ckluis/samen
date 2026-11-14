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
      ArgumentError -> {:error, :bad_argument}
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

      assert Enum.map(swallows, & &1.fun) |> Enum.sort() == [
               :contacts,
               :contacts_tryblock,
               :contacts_tryblock
             ]
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
    test "non-vacuity: the scanner sees the tree, and every @reviewed entry is still FOUND by it in its file" do
      files = SwallowLint.files()
      assert length(files) > 300
      assert Enum.any?(files, &String.ends_with?(&1, "crm/reads.ex"))
      assert Enum.any?(files, &String.ends_with?(&1, "driftwood/lib/driftwood/reads.ex"))

      # Debt-independent: this holds however far the baseline is paid down. The reviewed swallows are real
      # code the scanner must keep matching — a scanner that stopped matching (or a refactor that renamed or
      # deleted the helper, leaving a stale entry whose reason now describes nothing) fails here.
      root = SwallowLint.repo_root()
      reviewed = SwallowLint.reviewed()
      assert map_size(reviewed) > 0

      # Every pin is EXACT (count == the swallowing clauses the scanner finds in that function) and carries a
      # reason; a stale pin, or a clause added to a reviewed function, fails here (or in the ratchet below).
      assert SwallowLint.reviewed_problems() == []

      for {{file, fun}, {count, hash, reason}} <- reviewed do
        assert is_binary(hash) and hash != "", "#{file} #{fun}: a reviewed entry needs its hash"
        assert is_binary(reason) and reason != "", "#{file} #{fun}: a reviewed entry needs its reason"
        assert is_integer(count) and count > 0, "#{file} #{fun}: a reviewed entry needs its pinned count"
        assert file in files, "#{file} is reviewed but is not in the scanned tree (stale entry)"
      end

      # And the unfiltered count is never below the reviewed set (each reviewed entry is one found clause).
      unfiltered =
        files
        |> Enum.map(&length(SwallowLint.scan_source(File.read!(Path.join(root, &1)), &1)))
        |> Enum.sum()

      assert unfiltered >= reviewed |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sum()
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

    # The live ratchet's positive control. `@baseline` is `%{}`, so over the real tree `scan/1` is always `%{}`
    # and `check/0` always `:ok` — a `scan/1` that stopped counting would stay green. This runs the SAME
    # `scan/1` and `check/2` over a file outside the lint roots that holds known swallows.
    test "POSITIVE CONTROL: scan/1 counts a fixture's swallows and check/2 against the real baseline fails naming it" do
      fixture = "samen_web/test/fixtures/swallow_fixture.ex"
      refute fixture in SwallowLint.files()
      refute Enum.any?(SwallowLint.roots(), &String.starts_with?(fixture, &1))

      # five known swallows (the typed `rescue ArgumentError -> []` now counts); `logged/1` is not; `safe_count/1` shares a name with a reviewed
      # function in ANOTHER file and is still counted (reviewed entries are keyed by {file, function}).
      assert SwallowLint.scan([fixture]) == %{fixture => 5}
      assert Enum.any?(SwallowLint.reviewed(), fn {{_file, fun}, _} -> fun == :safe_count end)

      assert {:error, [msg]} =
               SwallowLint.check(SwallowLint.scan([fixture]), Map.take(SwallowLint.baseline(), [fixture]))

      assert msg =~ fixture
      assert msg =~ "5 swallowing"

      # the control is not a blanket failure: a clean file scans empty and passes.
      assert SwallowLint.scan(["samen_web/lib/samen/web/reads/guard.ex"]) == %{}

      assert :ok =
               SwallowLint.check(
                 SwallowLint.scan(["samen_web/lib/samen/web/reads/guard.ex"]),
                 Map.take(SwallowLint.baseline(), ["samen_web/lib/samen/web/reads/guard.ex"])
               )
    end

    test "the tree matches the baseline exactly (no new swallow, no un-lowered row)" do
      assert :ok = SwallowLint.check()
      assert :ok = SwallowLint.check_error_arms()
    end

    test "each baseline sums to its committed per-root ceiling; a raised row fails the ceiling" do
      assert :ok = SwallowLint.check_ceilings()

      raised = Map.update(SwallowLint.baseline(), "samen_web/lib/samen/web/csv.ex", 1, &(&1 + 1))
      assert {:error, [msg]} = Samen.Lint.Swallow.check_ceiling(raised, SwallowLint.ceilings().rescue, SwallowLint.roots())
      assert msg =~ "ceiling only goes down"
    end

    test "a clause added to a reviewed function is NOT absorbed by its entry (the pin is a count)" do
      file = "samen_web/lib/samen/web/reads/guard.ex"
      {pinned, _hash, _reason} = Map.fetch!(SwallowLint.reviewed(), {file, :run})
      src = File.read!(Path.join(SwallowLint.repo_root(), file))

      # One more catch-all in `run/3` than the entry pins: the same scan the live ratchet runs must count it.
      grown =
        String.replace(
          src,
          "    :throw, _value -> failed(name, scope, :throw)\n  end\n",
          "    :throw, _value -> failed(name, scope, :throw)\n    :error, _ -> :empty\n  end\n",
          global: false
        )

      refute grown == src
      sites = Samen.Lint.Swallow.scan_source(grown, file, :rescue)
      assert Enum.count(sites, &(&1.fun == :run)) > pinned
    end

    test "the non-rescue class: the tree matches its baseline, and the shared fixture proves the detector is live here" do
      assert :ok = SwallowLint.check_error_arms()
      fixture = "samen_core/test/fixtures/swallow_fixture.ex"
      assert SwallowLint.scan_error_arms([fixture]) == %{fixture => 4}
      assert {:error, [msg]} = SwallowLint.check_error_arms(SwallowLint.scan_error_arms([fixture]), Map.take(SwallowLint.error_arm_baseline(), [fixture]))
      assert msg =~ fixture
    end
  end
end
