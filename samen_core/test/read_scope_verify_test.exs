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
  test "RED: an unparseable file exits 1 — a file the lint could not inspect is never a pass" do
    {out, code} = run_task(["--source-dirs", Path.join(@corpus, "unparseable")])
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
    @tag :tmp_dir
    test "a source dir that does not exist is a violation", %{tmp_dir: tmp} do
      missing = Path.join(tmp, "nope")
      assert %{violations: [v]} = Task.scan([missing])
      assert v =~ "does not exist"
    end

    @tag :tmp_dir
    test "a dir with no .ex file is a violation (nothing was inspected)", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "notes.txt"), "no elixir here")
      assert %{violations: [v], files: 0} = Task.scan([tmp])
      assert v =~ "no .ex file found"
    end

    @tag :tmp_dir
    test "an unreadable file is a violation, and the readable sibling is still scanned", %{tmp_dir: tmp} do
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

    test "the clean corpus passes (positive control for every red above)" do
      assert %{violations: [], unscoped: 0, files: 1, governed_reads: 3, sanctioned_reads: 1} =
               Task.scan([Path.join(@corpus, "clean")])
    end
  end

  describe "ReadScope.scan_file/1" do
    test "an unparseable file is {:error, _}, a parseable one is {:ok, counts}" do
      assert {:error, "could not be scanned: " <> _} =
               ReadScope.scan_file(Path.join([@corpus, "unparseable", "broken.ex"]))

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

        assert ci =~ "mix samen.verify.read_scope --max-sanctioned #{sanctioned}\n",
               "#{host}/ci.sh must run the read-scope lint with the exact measured ceiling"
      end
    end

    @tag :tmp_dir
    test "a planted unscoped read in a copy of each host's lib/ is caught (the pristine copy passes)", %{tmp_dir: tmp} do
      for {host, ceiling} <- @hosts do
        copy = Path.join(tmp, to_string(host))
        File.cp_r!(Path.join([@repo_root, to_string(host), "lib"]), copy)

        # positive control: the pristine copy is clean
        assert %{violations: []} = Task.scan([copy], ceiling)

        File.write!(Path.join(copy, "zz_planted.ex"), """
        defmodule ZzPlanted.Leak do
          def every_orgs_rows(resource), do: Ash.read!(resource, authorize?: false)
        end
        """)

        assert %{unscoped: 1, violations: violations} = Task.scan([copy], ceiling)
        assert Enum.any?(violations, &(&1 =~ "zz_planted.ex:2 — every_orgs_rows/1")), "#{host}: #{inspect(violations)}"
      end
    end
  end
end
