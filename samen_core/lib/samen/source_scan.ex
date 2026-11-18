defmodule Samen.SourceScan do
  @moduledoc """
  The file walk the structural source scanners share (`Samen.Chokepoint`, `Samen.PiiReads`,
  `Samen.Cdc.NeverReadCurrent`, `Samen.Lint.Swallow`).

  `Path.wildcard/1` and `File.read!/1` are each a `gen_server.call` into the node's single `:file_server_2`
  process, per directory and per file. A scan of a 600-file tree is therefore ~1,200 calls queued behind every
  other test and task doing file I/O on the VM; measured on `samen_core/lib` that is 53 ms alone and 1,746 ms
  with 40 processes hammering the file server — and it grew past ExUnit's 60 s on a busy machine (load ~20).
  Here the walk and the reads go straight to `:prim_file` (what `:raw` mode uses), so they never queue.

  `files/2` returns what `Path.wildcard(Path.join(dir, "**/*.{ext,…}"))` returned: sorted full paths, dot-entries
  skipped, symlinks followed. `read!/1` returns what `File.read!/1` does and raises a `File.Error`.
  """

  @doc "Every file under `dir` (recursively) whose extension is in `exts` (e.g. `[\".ex\"]`), sorted."
  @spec files(Path.t(), [String.t()]) :: [Path.t()]
  def files(dir, exts) when is_list(exts), do: dir |> walk(exts) |> Enum.sort()

  @doc "`File.read!/1` without the file-server round trip."
  @spec read!(Path.t()) :: binary()
  def read!(file) do
    case :prim_file.read_file(file) do
      {:ok, bin} -> bin
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: file
    end
  end

  defp walk(dir, exts) do
    case :prim_file.list_dir(dir) do
      {:ok, names} ->
        for name <- Enum.map(names, &to_string/1),
            not String.starts_with?(name, "."),
            path = Path.join(dir, name),
            file <- entry(path, name, exts),
            do: file

      {:error, _} ->
        []
    end
  end

  defp entry(path, name, exts) do
    case :prim_file.read_file_info(path) do
      {:ok, info} ->
        case elem(info, 2) do
          :directory -> walk(path, exts)
          :regular -> if Path.extname(name) in exts, do: [path], else: []
          _ -> []
        end

      {:error, _} ->
        []
    end
  end
end
