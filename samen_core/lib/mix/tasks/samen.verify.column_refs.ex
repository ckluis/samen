defmodule Mix.Tasks.Samen.Verify.ColumnRefs do
  @shortdoc "Fail build on any source reference to an unknown ^[a-z]{3}_ storage column."

  @moduledoc """
  `mix samen.verify.column_refs` — CI linter (plan B4).

  Scans Elixir source files for string literals or atom literals that match the
  pattern `^[a-z]{3}_` (three lowercase letters followed by an underscore) and
  rejects any that do not appear in the `fld_field` catalog table.

  The doc states: "a CI linter rejects any reference to a column that isn't
  catalogued — a hallucinated field doesn't compile." This linter is that check.

  ## What it scans

  Source files under `lib/` and `test/` for the current mix project (configurable
  via `--source-dirs`). It finds literals of the form:

    * Atom literals in Elixir code: `:com_name`, `:pat_id`
    * String literals quoted in migration SQL: `"com_contact.com_name"`
    * Any bare token matching `~r/\\b[a-z]{3}_[a-z][a-z0-9_]*\\b/` in `.ex`/`.exs`
      files

  ## What is NOT flagged

    * Table names (patterns like `com_contact` where the part after `_` starts
      with the same abbrev convention) — the linter only checks against the
      `fld_field` column list, not `tam_table`. Table-level parity is C1's job.
    * Tokens that are catalog columns: these pass.
    * Tokens in comments (best-effort; the regex approach may catch some).
    * The catalog tables themselves (`tam_` and `fld_` prefixed names used by
      the catalog infrastructure).

  ## False-positive escape hatch

  Add a `# samen:allow com_legacy_col` comment on the line to suppress the
  linter for that specific token on that line.

  ## Database connection

  The task requires a running Postgres connection to read `fld_field`. It calls
  `app.start` to ensure the repo is running. Configure the repo via:

      config :samen_core, :verify_repo, MyApp.Repo

  or pass `--repo MyApp.Repo`.

  ## Exit code

  Exits 0 on success (all found tokens are catalogued or allowed), 1 on any
  violation (fail-closed).

  ## Usage

      mix samen.verify.column_refs
      mix samen.verify.column_refs --repo MyApp.Repo
      mix samen.verify.column_refs --source-dirs lib test
  """

  use Mix.Task

  @task_name "samen.verify.column_refs"

  # Matches tokens that look like storage column names: 3 lowercase letters,
  # underscore, then one or more lowercase-letter/digit/underscore chars.
  # The \\b word-boundary anchors prevent matching inside longer words.
  @column_pattern ~r/\b([a-z]{3}_[a-z][a-z0-9_]*)\b/

  # Tokens that are part of the catalog infrastructure itself — never flagged.
  @catalog_infra_prefixes ["tam_", "fld_"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [repo: :string, source_dirs: [:string, :keep]]
      )

    Mix.Task.run("app.start")

    repo = resolve_repo(opts)
    ensure_repo_started!(repo)

    source_dirs = resolve_source_dirs(opts)
    violations = check(repo, source_dirs)
    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the column-ref check and return a list of human-readable violation strings.

  Separated from `run/1` so tests can call it without triggering `:erlang.halt/1`.
  """
  def check(repo, source_dirs \\ ["lib", "test"]) do
    known = known_column_names(repo)
    source_files = find_source_files(source_dirs)

    source_files
    |> Enum.flat_map(fn path ->
      check_file(path, known)
    end)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp known_column_names(repo) do
    %{rows: rows} = repo.query!("SELECT fld_column_name FROM fld_field")
    MapSet.new(Enum.map(rows, fn [col] -> col end))
  end

  defp find_source_files(dirs) do
    dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join([dir, "**", "*.{ex,exs}"]))
    end)
  end

  defp check_file(path, known_columns) do
    content = File.read!(path)
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      check_line(path, lineno, line, known_columns)
    end)
  end

  defp check_line(path, lineno, line, known_columns) do
    # Skip if the line has a samen:allow comment for the whole line
    if String.contains?(line, "# samen:allow") do
      # Parse specifically allowed tokens on this line
      allowed_tokens = parse_allow_list(line)
      check_tokens_on_line(path, lineno, line, known_columns, allowed_tokens)
    else
      check_tokens_on_line(path, lineno, line, known_columns, MapSet.new())
    end
  end

  defp parse_allow_list(line) do
    # Extract tokens listed after "# samen:allow" on the same line
    case Regex.run(~r/# samen:allow\s+(.+)$/, line) do
      [_, tokens_str] ->
        tokens_str
        |> String.split(~r/\s+/)
        |> MapSet.new()

      nil ->
        MapSet.new()
    end
  end

  defp check_tokens_on_line(path, lineno, line, known_columns, allowed_tokens) do
    @column_pattern
    |> Regex.scan(line, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&catalog_infra_token?/1)
    |> Enum.reject(&MapSet.member?(known_columns, &1))
    |> Enum.reject(&MapSet.member?(allowed_tokens, &1))
    |> Enum.map(fn token ->
      "unknown storage column reference: #{token} at #{path}:#{lineno}"
    end)
  end

  defp catalog_infra_token?(token) do
    Enum.any?(@catalog_infra_prefixes, &String.starts_with?(token, &1))
  end

  defp resolve_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        Application.get_env(:samen_core, :verify_repo) ||
          raise "No repo configured. Pass --repo MyApp.Repo or set config :samen_core, :verify_repo, MyApp.Repo"

      repo_str ->
        Module.concat([repo_str])
    end
  end

  defp resolve_source_dirs(opts) do
    case Keyword.get_values(opts, :source_dirs) do
      [] -> ["lib", "test"]
      dirs -> dirs
    end
  end

  defp ensure_repo_started!(repo) do
    case repo.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Could not start repo #{inspect(repo)}: #{inspect(reason)}"
    end
  end
end
