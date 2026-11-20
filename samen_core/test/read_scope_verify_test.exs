defmodule SamenCore.ReadScopeVerifyTest do
  @moduledoc """
  `mix samen.verify.read_scope` — the read-scope lint (`Samen.Lint.ReadScope`) as a verifier every
  host and every generated app runs on its OWN `lib/` tree (D3 phase 1).

    * **GREEN** — a clean corpus (pinned, by-id, sanctioned) exits 0; the three reference hosts'
      `lib/` trees pass with EXACTLY the sanction count their `ci.sh` pins as the ceiling.
    * **RED, with the positive control above** — an unscoped `authorize?: false` read exits 1 and
      names `file:line`; a missing dir, an empty dir, an unparseable file and an unreadable
      file are each a violation (fail-closed: a tree the lint could not inspect never passes).
    * **GATE PARITY** — the hosts' `ci.sh` and EVERY generated app's `ci.sh` run the task.

  The exit code is observed in a child OS process (`:erlang.halt/1`), the same convention as the
  other `samen.verify.*` task tests.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.ReadScope, as: Task
  alias Samen.Lint.ReadScope

  @project_dir Path.expand("../", __DIR__)
  @repo_root Path.expand("../../", __DIR__)
  @corpus Path.join([__DIR__, "fixtures", "read_scope_corpus"])

  # A plain scratch dir OUTSIDE the repo, removed on exit. ExUnit's :tmp_dir names a directory after the test (quotes,
  # parentheses) inside samen_core/tmp and never deletes it; copies left there once broke a `find | xargs` gate scan.
  defp scratch! do
    dir = Path.join(System.tmp_dir!(), "read_scope_verify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    dir
  end

  # The deliberately unparseable fixture is stored as `unparseable/broken.ex.txt` so `mix format` (its inputs are
  # `test/**/*.ex`) never meets it; each test that scans it gets a copy named `broken.ex` in a scratch dir.
  defp unparseable_dir! do
    dir = scratch!()
    File.cp!(Path.join([@corpus, "unparseable", "broken.ex.txt"]), Path.join(dir, "broken.ex"))
    dir
  end

  defp run_task(args) do
    System.cmd("mix", ["samen.verify.read_scope" | args],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  @tag :exit_code
  test "GREEN: a clean corpus (pinned, by-id, sanctioned) exits 0 and reports its counts" do
    {out, code} = run_task(["--source-dirs", Path.join(@corpus, "clean")])
    assert code == 0, out
    assert out =~ "3 authorize?: false read(s), 1 sanctioned"
    assert out =~ "OK"
  end

  @tag :exit_code
  test "RED: an unscoped authorize?: false read exits 1 and names file:line and the function" do
    {out, code} = run_task(["--source-dirs", Path.join(@corpus, "leak")])
    assert code == 1, out
    assert out =~ "leak.ex:3 — every_orgs_rows/1"
    assert out =~ "UNSCOPED `authorize?: false` READ"
  end

  @tag :exit_code
  test "RED: a positional argument is refused, never silently ignored (it would scan `lib` instead of what was named)" do
    {out, code} = run_task([Path.join(@corpus, "leak")])
    assert code != 0, out
    assert out =~ "unexpected argument"
    assert out =~ "--source-dirs"

    # positive control: the same dir named with the flag is scanned
    {out, code} = run_task(["--source-dirs", Path.join(@corpus, "leak")])
    assert code == 1 and out =~ "leak.ex:3", out
  end

  @tag :exit_code
  test "RED: an unparseable file exits 1 — a file the lint could not inspect is never a pass" do
    {out, code} = run_task(["--source-dirs", unparseable_dir!()])
    assert code == 1, out
    assert out =~ "broken.ex"
    assert out =~ "could not be scanned"
  end

  @tag :exit_code
  test "RED: --max-sanctioned is a CEILING — one marker over a ceiling of 0 exits 1; a ceiling of 1 passes" do
    dir = Path.join(@corpus, "clean")
    {out0, code0} = run_task(["--source-dirs", dir, "--max-sanctioned", "0"])
    assert code0 == 1, out0
    assert out0 =~ "over the ceiling of 0"

    {out1, code1} = run_task(["--source-dirs", dir, "--max-sanctioned", "1"])
    assert code1 == 0, out1
  end

  describe "scan/2 (fail-closed on anything it cannot inspect)" do
    test "a source dir that does not exist is a violation" do
      tmp = scratch!()
      missing = Path.join(tmp, "nope")
      assert %{violations: [v]} = Task.scan([missing])
      assert v =~ "does not exist"
    end

    test "a dir with no .ex file is a violation (nothing was inspected)" do
      tmp = scratch!()
      File.write!(Path.join(tmp, "notes.txt"), "no elixir here")
      assert %{violations: [v], files: 0} = Task.scan([tmp])
      assert v =~ "no .ex file found"
    end

    test "an unreadable file is a violation, and the readable sibling is still scanned" do
      tmp = scratch!()
      File.write!(Path.join(tmp, "ok.ex"), File.read!(Path.join([@corpus, "clean", "clean.ex"])))
      locked = Path.join(tmp, "locked.ex")
      File.write!(locked, "defmodule Locked do\nend\n")
      File.chmod!(locked, 0o000)

      try do
        # root can read a 000 file; only assert the unreadable branch when the OS enforces it
        if match?({:error, _}, :prim_file.read_file(locked)) do
          assert %{violations: [v], governed_reads: 3} = Task.scan([tmp])
          assert v =~ "locked.ex"
          assert v =~ "cannot be read"
        end
      after
        File.chmod!(locked, 0o644)
      end
    end

    test "an unlistable subdirectory and a dangling symlink are violations, never silently skipped; the readable sibling is still scanned" do
      tmp = scratch!()
      File.write!(Path.join(tmp, "ok.ex"), File.read!(Path.join([@corpus, "clean", "clean.ex"])))

      # positive control: the same tree with nothing wrong passes
      assert %{violations: [], governed_reads: 3} = Task.scan([tmp])

      locked = Path.join(tmp, "locked_dir")
      File.mkdir_p!(locked)
      File.write!(Path.join(locked, "hidden.ex"), "defmodule Hidden do\nend\n")
      File.chmod!(locked, 0o000)
      :ok = File.ln_s(Path.join(tmp, "no_such_target.ex"), Path.join(tmp, "dangling.ex"))

      try do
        # root can list a 000 directory; only assert that branch when the OS enforces it
        if match?({:error, _}, :prim_file.list_dir(locked)) do
          assert %{violations: violations, governed_reads: 3} = Task.scan([tmp])
          assert Enum.any?(violations, &(&1 =~ "locked_dir: could not be inspected")), inspect(violations)
        end

        assert %{violations: violations, governed_reads: 3} = Task.scan([tmp])
        assert Enum.any?(violations, &(&1 =~ "dangling.ex: could not be inspected")), inspect(violations)
      after
        File.chmod!(locked, 0o755)
      end
    end

    test "the clean corpus passes (positive control for every red above)" do
      assert %{violations: [], unscoped: 0, files: 1, governed_reads: 3, sanctioned_reads: 1} =
               Task.scan([Path.join(@corpus, "clean")])
    end
  end

  describe "the unparseable fixture and the formatter" do
    test "no file `mix format` would read is a deliberately unparseable one (it is stored as .ex.txt)" do
      {opts, _} = Code.eval_file(Path.join(@project_dir, ".formatter.exs"))

      inputs =
        opts[:inputs]
        |> Enum.flat_map(&Path.wildcard(Path.join(@project_dir, &1)))
        |> Enum.map(&Path.relative_to(&1, @project_dir))

      # positive control: the glob does see the parseable fixtures beside it
      assert "test/fixtures/read_scope_corpus/clean/clean.ex" in inputs
      assert File.exists?(Path.join([@corpus, "unparseable", "broken.ex.txt"]))
      refute Enum.any?(inputs, &String.contains?(&1, "read_scope_corpus/unparseable")), inspect(inputs)
    end
  end

  describe "ReadScope.scan_file/1" do
    test "an unparseable file is {:error, _}, a parseable one is {:ok, counts}" do
      assert {:error, "could not be scanned: " <> _} =
               ReadScope.scan_file(Path.join(unparseable_dir!(), "broken.ex"))

      assert {:ok, {[], 3, 1}} = ReadScope.scan_file(Path.join([@corpus, "clean", "clean.ex"]))
      assert {:error, "cannot be read: " <> _} = ReadScope.scan_file(Path.join(@corpus, "absent.ex"))
    end
  end

  @hosts [demo: 1, driftwood: 1, pawchart: 2]

  describe "the reference hosts run it (D3 phase 1)" do
    test "every host's lib/ passes, and its ci.sh pins EXACTLY the measured sanction count" do
      for {host, ceiling} <- @hosts do
        lib = Path.join([@repo_root, to_string(host), "lib"])

        assert %{violations: [], sanctioned_reads: sanctioned, files: files} = Task.scan([lib])
        assert files > 0
        assert sanctioned == ceiling, "#{host}: measured #{sanctioned} sanctions, test pins #{ceiling}"

        ci = File.read!(Path.join([@repo_root, to_string(host), "ci.sh"]))

        # a WHOLE, uncommented, unindented command line: a `# mix …` comment, an `if false; then` body or a trailing
        # `|| true` must not satisfy it
        assert ci =~ ~r/^mix samen\.verify\.read_scope --max-sanctioned #{sanctioned}$/m,
               "#{host}/ci.sh must run the read-scope lint (a whole, uncommented line) with the exact measured ceiling"
      end
    end

    test "a planted unscoped read scanned with each host's lib/ is caught (the pristine lib passes)" do
      # A plain scratch dir OUTSIDE the repo, removed on exit: ExUnit's :tmp_dir names a directory after the test
      # (quotes, parentheses) and never deletes it, and copies of three hosts' trees then lingered under samen_core/tmp.
      # No copy is needed: the plant is the only new file, scanned beside the real lib/.
      scratch = Path.join(System.tmp_dir!(), "read_scope_plant_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(scratch) end)
      File.mkdir_p!(scratch)

      File.write!(Path.join(scratch, "zz_planted.ex"), """
      defmodule ZzPlanted.Leak do
        def every_orgs_rows(resource), do: Ash.read!(resource, authorize?: false)
      end
      """)

      for {host, ceiling} <- @hosts do
        lib = Path.join([@repo_root, to_string(host), "lib"])

        # positive control: the pristine lib is clean at its ceiling
        assert %{violations: []} = Task.scan([lib], ceiling)

        assert %{unscoped: 1, violations: violations} = Task.scan([lib, scratch], ceiling)
        assert Enum.any?(violations, &(&1 =~ "zz_planted.ex:2 — every_orgs_rows/1")), "#{host}: #{inspect(violations)}"
      end
    end
  end
end
