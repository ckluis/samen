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

    test "positive control: the stdlib calls DO block behind the file server", %{root: root} do
      assert nil == with_file_server_suspended(fn -> File.read!(Path.join(root, "a.ex")) end)
    end
  end
end
