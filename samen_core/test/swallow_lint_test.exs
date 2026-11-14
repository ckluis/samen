defmodule Samen.Lint.SwallowLintTest do
  @moduledoc """
  The SWALLOW ratchet over the KERNEL (`Samen.Lint.KernelSwallow` over the shared scanner
  `Samen.Lint.Swallow`; the same scanner backs `Samen.Web.Reads.SwallowLint` in samen_web). A NEW
  `rescue _ -> []` or `{:error, _} -> []` in samen_core/lib fails this suite; a converted file cannot
  re-grow one; the baselines only shrink; a reviewed function's clause count is pinned.
  """
  use ExUnit.Case, async: true

  alias Samen.Lint.KernelSwallow
  alias Samen.Lint.Swallow

  @fixture "samen_core/test/fixtures/swallow_fixture.ex"

  defp fixture_root, do: KernelSwallow.repo_root()

  describe "scan_source/3 — rescue class" do
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
        e -> Samen.Observability.Failure.report(:b, scope, e)
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
    end
    """

    test "RED: flags a function-level `rescue _ -> []`, a `try` rescue and a catch-all catch" do
      assert Swallow.scan_source(@swallow) |> Enum.map(& &1.fun) |> Enum.sort() ==
               [:contacts, :contacts_tryblock, :contacts_tryblock]
    end

    test "GREEN twin: logged, Failure.report-ed, handed-on, re-raised and typed clauses are not swallows" do
      assert Swallow.scan_source(@handled) == []
    end
  end

  describe "scan_source/3 — the non-rescue `{:error, _} -> literal` class" do
    test "RED: an Ash read, a repo write and an Ash count whose error arm is a literal are flagged" do
      sites = Swallow.scan_source(File.read!(Path.join(fixture_root(), @fixture)), @fixture, :error_arm)
      assert Enum.map(sites, & &1.fun) == [:arm_read, :arm_write, :arm_count]
      assert Enum.all?(sites, &(&1.kind == :error_arm))
    end

    test "GREEN twin: tagged, used-error, no-read wrapper and non-error arms are not flagged" do
      src = """
      defmodule Fixture.Arms do
        def tagged(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            {:error, _} -> {:error, :unavailable}
          end
        end

        def wrapper(s) do
          case tagged(s) do
            {:ok, r} -> r
            {:error, _} -> []
          end
        end

        def ok_arm(s) do
          case Ash.read(P, scope: s) do
            {:ok, _} -> []
            {:error, e} -> {:error, e}
          end
        end

        def non_ash(s) do
          case Date.from_iso8601(s) do
            {:ok, d} -> d
            {:error, _} -> nil
          end
        end
      end
      """

      assert Swallow.scan_source(src, "x.ex", :error_arm) == []
    end

    test "every literal the detector names is flagged, a computed value is not" do
      for lit <- ["[]", "%{}", "\"\"", "0", "0.0", "nil", "false", "true", ":ok"] do
        src = "defmodule F do\n def f(s) do\n case Ash.read(P, scope: s) do\n {:error, _} -> #{lit}\n _ -> 1\n end\n end\n end\n"
        assert [%{fun: :f}] = Swallow.scan_source(src, "x.ex", :error_arm), "literal #{lit}"
      end

      src = "defmodule F do\n def f(s) do\n case Ash.read(P, scope: s) do\n {:error, _} -> compute()\n _ -> 1\n end\n end\n end\n"
      assert Swallow.scan_source(src, "x.ex", :error_arm) == []
    end
  end

  describe "reviewed entries are pinned to a count" do
    test "RED: a clause ADDED to an already-reviewed function counts as an unreviewed swallow" do
      # `pinned/1` holds two swallowing clauses (a rescue and a catch); the entry pins ONE.
      reviewed = %{{@fixture, :pinned} => {1, "reviewed total helper"}}
      assert Swallow.scan(fixture_root(), [@fixture], reviewed, :rescue)[@fixture] == 4
      # no pin at all: five rescue-class sites in the fixture, and a pin of 2 covers `pinned/1` fully.
      assert Swallow.scan(fixture_root(), [@fixture], %{}, :rescue)[@fixture] == 5

      assert Swallow.scan(fixture_root(), [@fixture], %{{@fixture, :pinned} => {2, "both clauses"}}, :rescue)[@fixture] == 3
    end

    test "a pin that overstates the count is a stale pin; the exact pin is clean" do
      assert [msg] =
               Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {3, "r"}}, :rescue)

      assert msg =~ "pins 3"
      assert [] == Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {2, "r"}}, :rescue)
    end

    test "a pin that understates the count is reported too, naming the added clause" do
      assert [msg] =
               Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {1, "r"}}, :rescue)

      assert msg =~ "new clause was added"
    end

    test "an entry without a reason, with a zero count, or for an unscanned file is reported" do
      files = [@fixture]
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{@fixture, :pinned} => {2, ""}})
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{@fixture, :pinned} => {0, "r"}})
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{"nope.ex", :pinned} => {1, "r"}})
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{@fixture, :missing_fun} => {1, "r"}})
    end
  end

  describe "check/3 — the ratchet" do
    test "a file over its baseline (or not listed) fails and names the fix" do
      assert {:error, [msg]} = Swallow.check(%{"a.ex" => 2}, %{"a.ex" => 1}, "do the fix")
      assert msg =~ "a.ex"
      assert msg =~ "do the fix"
      assert {:error, [_]} = Swallow.check(%{"new.ex" => 1}, %{})
    end

    test "a file UNDER its baseline fails too: the baseline must be lowered (shrink-only)" do
      assert {:error, [msg]} = Swallow.check(%{"a.ex" => 1}, %{"a.ex" => 3})
      assert msg =~ "lower it to 1"
      assert {:error, [_]} = Swallow.check(%{}, %{"gone.ex" => 1})
    end

    test "equal counts pass" do
      assert :ok = Swallow.check(%{"a.ex" => 2}, %{"a.ex" => 2})
      assert :ok = Swallow.check(%{}, %{})
    end
  end

  describe "the live kernel sweep" do
    test "non-vacuity: the scanner sees the kernel tree and every reviewed pin is exact" do
      files = KernelSwallow.files()
      assert length(files) > 300
      assert Enum.any?(files, &String.ends_with?(&1, "samen_core/lib/samen/vault.ex"))
      assert Enum.any?(files, &String.ends_with?(&1, "samen_core/lib/samen/lint/swallow.ex"))
      assert map_size(KernelSwallow.reviewed()) > 0
      assert KernelSwallow.reviewed_problems() == []
    end

    test "the kernel baseline is real debt the scanner finds: it counts what it says it counts" do
      scanned = KernelSwallow.scan()
      assert map_size(KernelSwallow.baseline()) > 0
      assert scanned == KernelSwallow.baseline()
    end

    # A partial scan is compared to the matching slice of the real baseline (the rest of the baseline is other files).
    test "POSITIVE CONTROL: scan/1 counts the fixture's swallows and check/2 against the real baseline fails naming it" do
      refute @fixture in KernelSwallow.files()
      refute Enum.any?(KernelSwallow.roots(), &String.starts_with?(@fixture, &1))

      assert KernelSwallow.scan([@fixture]) == %{@fixture => 5}
      assert KernelSwallow.scan_error_arms([@fixture]) == %{@fixture => 3}

      assert {:error, [msg]} = KernelSwallow.check(KernelSwallow.scan([@fixture]), Map.take(KernelSwallow.baseline(), [@fixture]))
      assert msg =~ @fixture
      assert msg =~ "5 swallowing"

      assert {:error, [msg]} =
               KernelSwallow.check_error_arms(KernelSwallow.scan_error_arms([@fixture]), Map.take(KernelSwallow.error_arm_baseline(), [@fixture]))

      assert msg =~ @fixture
      assert msg =~ "3 swallowing"

      # not a blanket failure: a clean kernel file scans empty and passes.
      clean = "samen_core/lib/samen/observability/failure.ex"
      assert KernelSwallow.scan([clean]) == %{}
      assert :ok = KernelSwallow.check(KernelSwallow.scan([clean]), %{})
    end

    test "the kernel tree matches both baselines exactly (no new swallow, no un-lowered row)" do
      assert :ok = KernelSwallow.check()
      assert :ok = KernelSwallow.check_error_arms()
    end
  end
end
