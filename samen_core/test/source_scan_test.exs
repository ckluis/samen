defmodule Samen.SourceScanTest do
  @moduledoc """
  `Samen.SourceScan` walks and reads source trees for the structural scanners. Two proofs:

    * it finds exactly what `Path.wildcard(dir/**/*.{ext})` + `File.read!/1` did (same files, same order, dot-entries
      skipped, a symlinked directory followed), and
    * it never queues behind the node's single `:file_server_2`. That process is suspended for the call, so a walk or
      read that went through it (`Path.wildcard`, `File.read!`) would block: this is what made a scan outrun
      ExUnit's 60 s on a loaded machine. `async: false`, so no other test does file I/O while it is suspended.
  """
  use ExUnit.Case, async: false

  alias Samen.SourceScan

  setup do
    root = Path.join(System.tmp_dir!(), "samen_source_scan_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)

    for {rel, body} <- [
          {"a.ex", "a"},
          {"b.exs", "b"},
          {"c.txt", "c"},
          {"a/z.ex", "z"},
          {"a-b.ex", "ab"},
          {"a/deep/y.ex", "y"},
          {".hidden/h.ex", "h"},
          {".dot.ex", "d"},
          {"real/r.ex", "r"}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(root, rel)))
      File.write!(Path.join(root, rel), body)
    end

    File.ln_s!(Path.join(root, "real"), Path.join(root, "link"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "finds exactly what Path.wildcard did", %{root: root} do
    assert SourceScan.files(root, [".ex"]) == Path.wildcard(Path.join(root, "**/*.ex"))
    assert SourceScan.files(root, [".ex", ".exs"]) == Path.wildcard(Path.join(root, "**/*.{ex,exs}"))

    # positive control: the shapes the comparison is about are really present
    found = root |> SourceScan.files([".ex", ".exs"]) |> Enum.map(&Path.relative_to(&1, root))
    assert "a/deep/y.ex" in found and "b.exs" in found and "link/r.ex" in found
    refute Enum.any?(found, &(&1 =~ ".hidden" or &1 =~ ".dot.ex" or &1 =~ "c.txt"))
  end

  test "dirs/2 names what Path.wildcard did, for literal and whole-segment * paths", %{root: root} do
    File.mkdir_p!(Path.join(root, "spikes/one/lib"))
    File.mkdir_p!(Path.join(root, "spikes/two/lib"))
    File.mkdir_p!(Path.join(root, "spikes/three/other"))
    File.mkdir_p!(Path.join(root, "spikes/.hid/lib"))
    File.write!(Path.join(root, "spikes/file.txt"), "not a dir")

    assert SourceScan.dirs(root, "spikes/*/lib") == Path.wildcard(Path.join(root, "spikes/*/lib"))
    assert SourceScan.dirs(root, "a/deep") == Path.wildcard(Path.join(root, "a/deep"))
    assert SourceScan.dirs(root, "nope/lib") == []

    # positive control: both matches are really there, the file, the hidden dir and the lib-less dir are not
    found = root |> SourceScan.dirs("spikes/*/lib") |> Enum.map(&Path.relative_to(&1, root))
    assert found == ["spikes/one/lib", "spikes/two/lib"]
  end

  test "an absent directory is empty and an unreadable file raises File.Error", %{root: root} do
    assert SourceScan.files(Path.join(root, "nope"), [".ex"]) == []
    assert_raise File.Error, fn -> SourceScan.read!(Path.join(root, "nope.ex")) end
    assert SourceScan.read!(Path.join(root, "a.ex")) == "a"
  end

  describe "with :file_server_2 suspended" do
    defp with_file_server_suspended(fun) do
      :ok = :sys.suspend(:file_server_2)

      try do
        {:ok, sup} = Task.Supervisor.start_link()
        task = Task.Supervisor.async_nolink(sup, fun)
        result = Task.yield(task, 5_000)
        if result == nil, do: Task.shutdown(task, :brutal_kill)
        result
      after
        :ok = :sys.resume(:file_server_2)
      end
    end

    test "files/2 completes", %{root: root} do
      assert {:ok, [_ | _]} = with_file_server_suspended(fn -> SourceScan.files(root, [".ex"]) end)
    end

    test "read!/1 completes", %{root: root} do
      assert {:ok, "a"} = with_file_server_suspended(fn -> SourceScan.read!(Path.join(root, "a.ex")) end)
    end

    test "dirs/2 completes", %{root: root} do
      assert {:ok, ["" <> _ | _]} = with_file_server_suspended(fn -> SourceScan.dirs(root, "a/*") end)
    end

    test "positive control: the stdlib calls DO block behind the file server", %{root: root} do
      assert nil == with_file_server_suspended(fn -> File.read!(Path.join(root, "a.ex")) end)
    end
  end

  # The whole-tree scan tests ran their scans through Path.wildcard/File.read!, one file-server call each (~1,100
  # files for the chokepoint probes, ~390 migrations for the role derivation). Measured in one VM: 617 ms alone and
  # 5,096 ms with 40 processes doing file I/O for the chokepoint scan, 382 ms and 6,228 ms for the migration scan, so
  # they outran ExUnit's 60 s on a loaded machine while passing in ~2 s alone. They go through SourceScan; this keeps
  # them there.
  describe "the whole-tree scan tests never walk or read the tree through the file server" do
    @scan_tests ~w(
      test/delivery/chokepoint_anti_bypass_probe_test.exs
      test/ai/chokepoint_anti_bypass_probe_test.exs
      test/aud_role_derivation_test.exs
      test/meta/test_db_guard_test.exs
      test/meta/sandbox_shared_guard_test.exs
      test/chokepoint_test.exs
      ../samen_web/lib/samen/web/authz/read_scope_lint.ex
      ../samen_web/lib/samen/web/reads/lint.ex
    )
    # A call is `Mod.fun(` (also piped: `|> Path.wildcard()`) or a capture `&Mod.fun/N` (`Enum.flat_map(&Path.wildcard/1)` is
    # the idiom read_scope_lint used before it moved to SourceScan). NOT chased: an aliased module (`alias Path, as: P`).
    @file_server_scan ~r/(\b(Path\.wildcard|File\.(read!?|cp_r!?|cp!?|regular\?|dir\?|ls!?|stat!?|lstat!?|exists\?|stream!))|:filelib\.\w+)(\(|\/\d)/

    defp file_server_scan_calls(source) do
      for {line, n} <- source |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          Regex.match?(@file_server_scan, line),
          do: {n, String.trim(line)}
    end

    test "no scan test calls Path.wildcard or File.read!/regular?/dir?/ls through the file server" do
      root = Path.expand("..", __DIR__)

      offenders =
        for rel <- @scan_tests, hit <- file_server_scan_calls(SourceScan.read!(Path.join(root, rel))), do: {rel, hit}

      assert offenders == [], "scan tests must go through Samen.SourceScan: #{inspect(offenders)}"
    end

    test "positive control: the matcher flags each stdlib call it guards against and spares the tmp-file helpers" do
      for call <- ["Path.wildcard(x)", "File.read!(p)", "File.regular?(p)", "File.dir?(d)", "File.ls!(d)", ":filelib.wildcard(x)", ":filelib.is_dir(d)", "File.stream!(p)", "File.cp_r!(a, b)",
                   "x |> Path.wildcard()", "Enum.flat_map(&Path.wildcard/1)", "Enum.map(&Path.wildcard/2)", "Enum.map(&File.read!/1)", "&:filelib.wildcard/2"] do
        assert [_] = file_server_scan_calls("  y = " <> call), call
      end

      assert [] = file_server_scan_calls("  # File.read!(p) in a comment")
      assert [] = file_server_scan_calls("  # Enum.flat_map(&Path.wildcard/1) in a comment")
      assert [] = file_server_scan_calls(~s(  doc = "Path.wildcard is the old way"))
      assert [] = file_server_scan_calls("  File.write!(p, body)\n  File.mkdir_p!(d)\n  File.rm_rf!(d)")
    end

    test "positive control: the scan tests do scan through SourceScan" do
      root = Path.expand("..", __DIR__)
      for rel <- @scan_tests, do: assert(SourceScan.read!(Path.join(root, rel)) =~ "Samen.SourceScan.", rel)
    end
  end
end
