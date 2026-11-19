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
  def files(dir, exts) when is_list(exts), do: dir |> files_checked(exts) |> elem(0)

  @doc """
  Like `files/2`, but also returns what the walk could NOT inspect: `{files, errors}`, where each error is
  `{path, reason}` for a directory that could not be listed or an entry that could not be stat'ed (a permission
  failure, a dangling symlink). `files/2` skips those silently; a gate that must never pass over a tree it could not
  fully see (`mix samen.verify.read_scope`) uses this and turns every error into a violation.
  """
  @spec files_checked(Path.t(), [String.t()]) :: {[Path.t()], [{Path.t(), term()}]}
  def files_checked(dir, exts) when is_list(exts) do
    {files, errors} = walk(dir, exts)
    {Enum.sort(files), Enum.sort(errors)}
  end

  @doc """
  The directories `Path.wildcard(Path.join(root, rel))` names, for a `rel` whose only wildcards are whole `*` segments
  (`"samen_core/lib"`, `"spikes/*/lib"`), found without the file server. Sorted; an absent directory is absent.
  """
  @spec dirs(Path.t(), Path.t()) :: [Path.t()]
  def dirs(root, rel) do
    rel
    |> Path.split()
    |> Enum.reduce([root], fn
      "*", acc -> Enum.flat_map(acc, &subdirs/1)
      segment, acc -> Enum.map(acc, &Path.join(&1, segment))
    end)
    |> Enum.filter(&dir?/1)
    |> Enum.sort()
  end

  defp subdirs(dir) do
    case :prim_file.list_dir(dir) do
      {:ok, names} -> for name <- Enum.map(names, &to_string/1), not String.starts_with?(name, "."), do: Path.join(dir, name)
      {:error, _} -> []
    end
  end

  defp dir?(path) do
    match?({:ok, info} when elem(info, 2) == :directory, :prim_file.read_file_info(path))
  end

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
        for name <- Enum.map(names, &to_string/1), not String.starts_with?(name, "."), reduce: {[], []} do
          {files, errors} ->
            {f, e} = entry(Path.join(dir, name), name, exts)
            {files ++ f, errors ++ e}
        end

      {:error, reason} ->
        {[], [{dir, reason}]}
    end
  end

  defp entry(path, name, exts) do
    case :prim_file.read_file_info(path) do
      {:ok, info} ->
        case elem(info, 2) do
          :directory -> walk(path, exts)
          :regular -> if Path.extname(name) in exts, do: {[path], []}, else: {[], []}
          _ -> {[], []}
        end

      {:error, reason} ->
        {[], [{path, reason}]}
    end
  end
end
