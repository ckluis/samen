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
        ArgumentError -> {:error, :bad_argument}
      end

      def f(scope) do
        Ash.read!(Person, scope: scope)
      rescue
        e in ArgumentError ->
          Logger.error("bad argument: #{inspect(e.__struct__)}")
          []
      end

      def g(scope) do
        Ash.read!(Person, scope: scope)
      rescue
        e ->
          msg = Exception.message(e)
          {:error, msg}
      end
    end
    """

    test "RED: flags a function-level `rescue _ -> []`, a `try` rescue and a catch-all catch" do
      assert Swallow.scan_source(@swallow) |> Enum.map(& &1.fun) |> Enum.sort() ==
               [:contacts, :contacts_tryblock, :contacts_tryblock]
    end

    test "GREEN twin: logged, Failure.report-ed, handed-on (also via a derived variable), re-raised and typed clauses that return a tagged value are not swallows" do
      assert Swallow.scan_source(@handled) == []
    end
  end

  describe "scan_source/3 — the non-rescue `{:error, _} -> literal` class" do
    test "RED: an Ash read, a repo write and an Ash count whose error arm is a literal are flagged" do
      sites = Swallow.scan_source(File.read!(Path.join(fixture_root(), @fixture)), @fixture, :error_arm)
      assert Enum.map(sites, & &1.fun) == [:arm_read, :arm_write, :arm_count, :arm_wrapper]
      assert Enum.all?(sites, &(&1.kind == :error_arm))
    end

    test "GREEN twin: tagged, used-error, wrapper over a helper that does no I/O, error-signal atoms and non-error arms are not flagged" do
      src = """
      defmodule Fixture.Arms do
        def tagged(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            {:error, _} -> {:error, :unavailable}
          end
        end

        def pure_wrapper(s) do
          case helper(s) do
            {:ok, r} -> r
            {:error, _} -> []
          end
        end

        defp helper(s), do: {:ok, s}

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

  describe "S5 widened detections — each with a positive AND a negative case" do
    defp arm_funs(src), do: src |> Swallow.scan_source("x.ex", :error_arm) |> Enum.map(& &1.fun)
    defp rescue_funs(src), do: src |> Swallow.scan_source("x.ex", :rescue) |> Enum.map(& &1.fun)

    defp arm_src(arm) do
      "defmodule F do\n def f(s) do\n case Ash.read(P, scope: s) do\n {:ok, r} -> r\n #{arm}\n end\n end\n end\n"
    end

    test "(a) RED: {:ok, <literal>}, a bare non-error atom and MapSet.new() are swallowed by an error arm" do
      for arm <- [
            "{:error, _} -> {:ok, []}",
            "{:error, _} -> {:ok, %{}}",
            "{:error, _} -> {:ok, nil}",
            "{:error, _} -> :none",
            "{:error, _} -> :not_found",
            "{:error, _} -> MapSet.new()",
            "{:error, _} -> MapSet.new([])"
          ] do
        assert [:f] == arm_funs(arm_src(arm)), arm
      end
    end

    test "(a) GREEN twin: another error atom, an error tuple, a computed value and {:ok, computed} are not swallows" do
      for arm <- [
            "{:error, _} -> :error",
            "{:error, _} -> :unavailable",
            "{:error, _} -> :timeout",
            "{:error, _} -> {:error, :unavailable}",
            "{:error, _} -> {:ok, compute()}",
            "{:error, _} -> MapSet.new(compute())",
            "{:error, e} -> {:error, e}"
          ] do
        assert [] == arm_funs(arm_src(arm)), arm
      end
    end

    test "(a) a `_ ->` arm is a swallow when the case scrutinee is I/O, and a `with … else _ ->` likewise" do
      assert [:f] == arm_funs(arm_src("_ -> []"))
      assert [:f] == arm_funs(arm_src("_other -> nil"))

      with_src = "defmodule F do\n def f(r) do\n with {:ok, x} <- r.insert(r) do\n x\n else\n _ -> []\n end\n end\n end\n"
      assert [:f] == arm_funs(with_src)
    end

    test "(a) GREEN twin: a `_ ->` arm over a scrutinee that is not I/O is not flagged, even in a function that does I/O" do
      src = """
      defmodule F do
        def f(s, flag) do
          rows = Ash.read!(P, scope: s)
          case flag do
            true -> rows
            _ -> []
          end
        end
      end
      """

      assert [] == arm_funs(src)
    end

    test "(a) io_call? is transitive over local defs, and a helper that does no I/O does not make a wrapper one" do
      src = """
      defmodule F do
        defp load(s), do: Ash.read(P, scope: s)
        defp load_twice(s), do: load(s)

        def deep(s) do
          case load_twice(s) do
            {:ok, r} -> r
            {:error, _} -> []
          end
        end

        defp pure(s), do: {:ok, s}

        def shallow(s) do
          case pure(s) do
            {:ok, r} -> r
            {:error, _} -> []
          end
        end
      end
      """

      assert [:deep] == arm_funs(src)
    end

    test "(b) RED: `e -> _ = e; []` is a swallow — mentioning the variable is not handling it" do
      src = """
      defmodule F do
        def f(s) do
          Ash.read!(P, scope: s)
        rescue
          e ->
            _ = e
            []
        end

        def g(s) do
          Ash.read!(P, scope: s)
        rescue
          e ->
            notify(e)
            []
        end
      end
      """

      assert [:f, :g] == rescue_funs(src)
    end

    test "(b) GREEN twin: the variable reaching the final expression (directly or via an assignment) is handling" do
      src = """
      defmodule F do
        def f(s) do
          Ash.read!(P, scope: s)
        rescue
          e -> {:error, e}
        end

        def g(s) do
          Ash.read!(P, scope: s)
        rescue
          e ->
            reason = Exception.message(e)
            {:error, {:failed, reason}}
        end
      end
      """

      assert [] == rescue_funs(src)
    end

    test "(c) RED: a broad typed list that returns a swallow literal counts" do
      src = """
      defmodule F do
        def f(s) do
          Ash.read!(P, scope: s)
        rescue
          _ in [Postgrex.Error, DBConnection.ConnectionError, Ash.Error.Unknown] -> []
        end

        def g(s) do
          Ash.read!(P, scope: s)
        rescue
          e in [ArgumentError] -> nil
        end
      end
      """

      assert [:f, :g] == rescue_funs(src)
    end

    test "(c) GREEN twin: a typed list that reports, re-raises or returns a tagged value is not a swallow" do
      src = """
      defmodule F do
        def f(s) do
          Ash.read!(P, scope: s)
        rescue
          e in [Postgrex.Error, DBConnection.ConnectionError] ->
            Samen.Observability.Failure.report(:f, s, e)
            []
        end

        def g(s) do
          Ash.read!(P, scope: s)
        rescue
          _ in [Postgrex.Error] -> {:error, :unavailable}
        end

        def h(s) do
          Ash.read!(P, scope: s)
        rescue
          e in [ArgumentError] -> reraise e, __STACKTRACE__
        end
      end
      """

      assert [] == rescue_funs(src)
    end

    test "(d) RED: defmacro bodies and module-body nodes (Ash DSL `change fn`) are scanned under their own names" do
      src = """
      defmodule F do
        defmacro build(x) do
          quote do
            try do
              Ash.read!(unquote(x))
            rescue
              _ -> []
            end
          end
        end

        change fn changeset, _ctx ->
          try do
            Ash.read!(P)
          rescue
            _ -> nil
          end
        end

        def plain(s) do
          Ash.read!(P, scope: s)
        rescue
          _ -> []
        end
      end
      """

      assert [:build, :__module__, :plain] == rescue_funs(src)

      arms = "defmodule F do\n  after_action fn cs, r ->\n    case Ash.read(P) do\n      {:error, _} -> []\n      {:ok, x} -> x\n    end\n  end\nend\n"
      assert [:__module__] == arm_funs(arms)
    end

    test "(d) GREEN twin: a def inside the module body is counted once, under its own name; clean macros and DSL nodes are clean" do
      src = """
      defmodule F do
        use Something
        attribute :name, :string

        def f(s) do
          Ash.read!(P, scope: s)
        rescue
          _ -> []
        end

        defmacro clean(x), do: quote(do: Ash.read!(unquote(x)))
      end
      """

      assert [:f] == rescue_funs(src)
    end
  end

  describe "S5 (e) reviewed entries pin {count, hash} of the clauses' normalised source" do
    @src_a """
    defmodule F do
      def f(s) do
        Ash.read!(P, scope: s)
      rescue
        _ -> []
      end
    end
    """

    # same clause count, DIFFERENT clause (returns %{} and is reformatted over more lines)
    @src_b """
    defmodule F do
      def f(s) do
        Ash.read!(P, scope: s)
      rescue
        _ ->
          %{}
      end
    end
    """

    # same clause as @src_a, reformatted and moved down the file
    @src_a_moved """
    # a comment

    defmodule F do
      def other, do: 1


      def f(s) do
        Ash.read!(P, scope: s)
      rescue
        _ ->
          []
      end
    end
    """

    defp hash_for(src) do
      [site] = Swallow.scan_source(src, "x.ex", :rescue)
      :crypto.hash(:sha256, site.norm) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    end

    test "RED: a REPLACED clause (same count) is no longer covered by the pin; the hash is stable across formatting" do
      # a plain scratch dir: ExUnit's :tmp_dir names a directory after the test name (quotes, brackets), which breaks
      # the `find | xargs` scans of scripts/mutation_lint.sh while it lingers under samen_core/tmp
      dir = Path.join(System.tmp_dir!(), "swallow_lint_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(Path.join(dir, "lib"))
      path = "lib/f.ex"
      File.write!(Path.join(dir, path), @src_a)
      hash = Swallow.reviewed_hash(dir, path, :f, 1)
      reviewed = %{{path, :f} => {1, hash, "a reason"}}

      assert %{} == Swallow.scan(dir, [path], reviewed)
      assert [] == Swallow.reviewed_problems(dir, [path], reviewed)

      # reformatted + moved: still covered
      File.write!(Path.join(dir, path), @src_a_moved)
      assert hash == Swallow.reviewed_hash(dir, path, :f, 1)
      assert %{} == Swallow.scan(dir, [path], reviewed)

      # replaced (`[]` became `%{}`): the count is still 1, but the pin covers nothing and the problem is named
      File.write!(Path.join(dir, path), @src_b)
      assert %{^path => 1} = Swallow.scan(dir, [path], reviewed)
      assert [msg] = Swallow.reviewed_problems(dir, [path], reviewed)
      assert msg =~ "REPLACED"
    end

    test "the hash is independent of line numbers and whitespace (pure function of the clause)" do
      assert hash_for(@src_a) == hash_for(String.replace(@src_a, "_ -> []", "_ ->\n      []"))
      refute hash_for(@src_a) == hash_for(@src_b)
    end

    test "an entry without a hash is reported" do
      assert [msg] = Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {2, "", "r"}})
      assert msg =~ "hash"
    end
  end

  describe "S5 (g) the hard ceiling" do
    test "RED: a baseline row raised without raising the ceiling fails; a lowered baseline needs the ceiling lowered" do
      roots = ["a/lib"]
      assert :ok = Swallow.check_ceiling(%{"a/lib/x.ex" => 2, "a/lib/y.ex" => 1}, %{"a/lib" => 3}, roots)

      assert {:error, [msg]} = Swallow.check_ceiling(%{"a/lib/x.ex" => 3, "a/lib/y.ex" => 1}, %{"a/lib" => 3}, roots)
      assert msg =~ "ceiling only goes down"

      assert {:error, [msg]} = Swallow.check_ceiling(%{"a/lib/x.ex" => 1}, %{"a/lib" => 3}, roots)
      assert msg =~ "lower the ceiling to 1"

      assert {:error, [msg]} = Swallow.check_ceiling(%{"b/lib/z.ex" => 1}, %{"a/lib" => 0}, roots)
      assert msg =~ "outside every ceiling root"
    end

    test "the live baselines sum to their committed ceilings" do
      assert :ok = KernelSwallow.check_ceilings()
    end

    test "the merge-base reader parses the committed @ceilings shape (so the comparison below cannot silently skip)" do
      src = File.read!(Path.join(fixture_root(), "samen_core/lib/samen/lint/kernel_swallow.ex"))

      for {class, roots} <- KernelSwallow.ceilings(), {root, total} <- roots do
        assert base_ceiling(src, class, root) == total
      end

      assert base_ceiling("@ceilings %{\n    rescue: %{\"a\" => 7}\n  }", :rescue, "b") == nil
    end

    @ceiling_files [
      {"kernel", "samen_core/lib/samen/lint/kernel_swallow.ex"},
      {"web", "samen_web/lib/samen/web/reads/swallow_lint.ex"}
    ]

    test "a ceiling can only go down: no root's ceiling, nor a class total, is higher than on the merge base (kernel AND web)" do
      for {label, rel} <- @ceiling_files, class <- [:rescue, :error_arm] do
        current = ceiling_pairs(File.read!(Path.join(fixture_root(), rel)), class)
        assert current != %{}, "#{label}: no #{class} ceilings parsed from #{rel} (the reader is blind)"

        case merge_base_source(rel) do
          {:ok, base_src} ->
            base = ceiling_pairs(base_src, class)

            for {root, total} <- current, Map.has_key?(base, root) do
              assert total <= base[root], "#{label} #{class} ceiling for #{root} rose: #{base[root]} -> #{total}"
            end

            # A renamed or new root has nothing to compare with per root, so the CLASS total must not rise either.
            # (A base with no ceilings block at all predates the hard ceiling: nothing to compare.)
            assert base == %{} or Enum.sum(Map.values(current)) <= Enum.sum(Map.values(base)),
                   "#{label} #{class} ceilings rose in total: #{Enum.sum(Map.values(base))} -> #{Enum.sum(Map.values(current))}"

          :new_file ->
            :ok

          :no_merge_base ->
            # Skipping would turn the guard off exactly where it matters (a shallow CI checkout): fail there.
            if System.get_env("CI") in [nil, ""] do
              :skip
            else
              flunk("no merge base with origin/main in CI: the ceiling can-only-go-down check cannot run (fetch-depth: 0)")
            end
        end
      end
    end

    defp merge_base_source(rel) do
      case System.cmd("git", ["merge-base", "HEAD", "origin/main"], cd: fixture_root(), stderr_to_stdout: true) do
        {base, 0} ->
          case System.cmd("git", ["show", "#{String.trim(base)}:#{rel}"], cd: fixture_root(), stderr_to_stdout: true) do
            {src, 0} -> {:ok, src}
            _ -> :new_file
          end

        _ ->
          :no_merge_base
      end
    end

    # Every `"root" => n` of one class in the committed `@ceilings` literal.
    defp ceiling_pairs(src, class) do
      with [_, block] <- Regex.run(~r/@ceilings %\{(.*?)\n  \}/s, src),
           [_, inner] <- Regex.run(~r/#{class}: %\{(.*?)\}/s, block) do
        ~r/"([^"]+)" => (\d+)/ |> Regex.scan(inner) |> Map.new(fn [_, root, n] -> {root, String.to_integer(n)} end)
      else
        _ -> %{}
      end
    end

    # The ceiling literal as committed: `@ceilings %{rescue: %{"root" => n}, error_arm: %{"root" => n}}`.
    defp base_ceiling(src, class, root) do
      with [_, block] <- Regex.run(~r/@ceilings %\{(.*?)\n  \}/s, src),
           [_, inner] <- Regex.run(~r/#{class}: %\{(.*?)\}/s, block),
           [_, n] <- Regex.run(~r/"#{Regex.escape(root)}" => (\d+)/, inner) do
        String.to_integer(n)
      else
        _ -> nil
      end
    end
  end

  describe "reviewed entries are pinned to a count" do
    defp pin_hash(n), do: Swallow.reviewed_hash(fixture_root(), @fixture, :pinned, n)

    test "RED: a clause ADDED to an already-reviewed function counts as an unreviewed swallow" do
      # `pinned/1` holds two swallowing clauses (a rescue and a catch); the entry pins ONE.
      reviewed = %{{@fixture, :pinned} => {1, pin_hash(1), "reviewed total helper"}}
      assert Swallow.scan(fixture_root(), [@fixture], reviewed, :rescue)[@fixture] == 5
      # no pin at all: six rescue-class sites in the fixture, and a pin of 2 covers `pinned/1` fully.
      assert Swallow.scan(fixture_root(), [@fixture], %{}, :rescue)[@fixture] == 6

      assert Swallow.scan(fixture_root(), [@fixture], %{{@fixture, :pinned} => {2, pin_hash(2), "both clauses"}}, :rescue)[@fixture] == 4
    end

    test "a pin that overstates the count is a stale pin; the exact pin is clean" do
      assert [msg] =
               Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {3, pin_hash(2), "r"}}, :rescue)

      assert msg =~ "pins 3"
      assert [] == Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {2, pin_hash(2), "r"}}, :rescue)
    end

    test "a pin that understates the count is reported too, naming the added clause" do
      assert [msg] =
               Swallow.reviewed_problems(fixture_root(), [@fixture], %{{@fixture, :pinned} => {1, pin_hash(1), "r"}}, :rescue)

      assert msg =~ "new clause was added"
    end

    test "an entry without a reason, with a zero count, or for an unscanned file is reported" do
      files = [@fixture]
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{@fixture, :pinned} => {2, pin_hash(2), ""}})
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{@fixture, :pinned} => {0, pin_hash(2), "r"}})
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{"nope.ex", :pinned} => {1, "h", "r"}})
      assert [_] = Swallow.reviewed_problems(fixture_root(), files, %{{@fixture, :missing_fun} => {1, "h", "r"}})
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

      assert KernelSwallow.scan([@fixture]) == %{@fixture => 6}
      assert KernelSwallow.scan_error_arms([@fixture]) == %{@fixture => 4}

      assert {:error, [msg]} = KernelSwallow.check(KernelSwallow.scan([@fixture]), Map.take(KernelSwallow.baseline(), [@fixture]))
      assert msg =~ @fixture
      assert msg =~ "6 swallowing"

      assert {:error, [msg]} =
               KernelSwallow.check_error_arms(KernelSwallow.scan_error_arms([@fixture]), Map.take(KernelSwallow.error_arm_baseline(), [@fixture]))

      assert msg =~ @fixture
      assert msg =~ "4 swallowing"

      # not a blanket failure: a clean kernel file scans empty and passes.
      clean = "samen_core/lib/samen/observability/failure.ex"
      assert KernelSwallow.scan([clean]) == %{}
      assert :ok = KernelSwallow.check(KernelSwallow.scan([clean]), %{})
    end

    test "the kernel tree matches both baselines exactly (no new swallow, no un-lowered row)" do
      assert :ok = KernelSwallow.check()
      assert :ok = KernelSwallow.check_error_arms()
      assert :ok = KernelSwallow.check_ceilings()
    end
  end

  describe "re-review: multi-statement error arms, typed catch, hash over the enclosing definition" do
    test "RED: an error arm that does something and THEN answers a swallow literal is flagged; logging or reporting clears it" do
      src = """
      defmodule Fixture.MultiArms do
        def blank_then_empty(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            {:error, _} ->
              _ = 1
              []
          end
        end

        def telemetry_then_empty(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            {:error, _} ->
              :telemetry.execute([:x], %{}, %{})
              []
          end
        end

        def wildcard_block(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            _ ->
              _ = 1
              nil
          end
        end

        def logged_then_empty(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            {:error, _} ->
              Logger.error("read failed")
              []
          end
        end

        def reported_then_tagged(s) do
          case Ash.read(P, scope: s) do
            {:ok, r} -> r
            {:error, _} ->
              _ = 1
              {:error, :unavailable}
          end
        end
      end
      """

      assert Swallow.scan_source(src, "m.ex", :error_arm) |> Enum.map(& &1.fun) ==
               [:blank_then_empty, :telemetry_then_empty, :wildcard_block]
    end

    test "RED: a typed `catch :exit, {:timeout, _} -> []` is flagged; one that logs, or answers a tagged error, is not" do
      src = """
      defmodule Fixture.TypedCatch do
        def timed_out(pid) do
          GenServer.call(pid, :x)
        catch
          :exit, {:timeout, _} -> []
        end

        def logged(pid) do
          GenServer.call(pid, :x)
        catch
          :exit, {:timeout, _} ->
            Logger.error("timeout")
            []
        end

        def tagged(pid) do
          GenServer.call(pid, :x)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end
      end
      """

      assert Swallow.scan_source(src, "c.ex", :rescue) |> Enum.map(& &1.fun) == [:timed_out]
    end

    test "RED: editing the function body OUTSIDE the reviewed clause changes the pinned hash (the pin covers the whole definition)" do
      dir = Path.join(System.tmp_dir!(), "swallow_span_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(Path.join(dir, "lib"))
      path = "lib/f.ex"

      write = fn body -> File.write!(Path.join(dir, path), "defmodule F do\n  def f(s) do\n    #{body}\n  rescue\n    _ -> []\n  end\nend\n") end

      write.("Ash.read!(P, scope: s)")
      hash = Swallow.reviewed_hash(dir, path, :f, 1)
      reviewed = %{{path, :f} => {1, hash, "a reason"}}
      assert %{} == Swallow.scan(dir, [path], reviewed)

      # the clause is byte-identical; only the guarded body changed
      write.("Ash.destroy!(P, scope: s)")
      assert %{^path => 1} = Swallow.scan(dir, [path], reviewed)
      assert [msg] = Swallow.reviewed_problems(dir, [path], reviewed)
      assert msg =~ "REPLACED"
    end
  end
end
