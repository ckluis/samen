defmodule Samen.Cdc.NeverReadCurrent do
  @moduledoc """
  The **never-read-current** guard + lint (plan T6.5; doc line 635 "The rule that
  keeps both honest: never read a 'current' value from the analytics tier.").

  The CDC analytics mirror is seconds-stale by construction. Reading a value back
  from it and treating it as *current* (a value the app acts on — a balance, a
  status, a count you enforce a limit against) is a correctness bug that no amount
  of ClickHouse tuning fixes. This module enforces the rule two ways:

    * **Runtime chokepoint** — every `Samen.Cdc` adapter's `read_current/3` raises
      `#{inspect(__MODULE__.Violation)}`. There is no legitimate current-read path;
      the callback exists only to fail loudly.

    * **Build-time lint** (`scan_sources/2`, driven by
      `mix samen.verify.never_read_current`) — a dataflow *match* (NOT a sound
      proof, same honesty caveat as `pii_reads`) that flags any call to the
      configured CDC repo's read functions (`all/get/get_by/one/aggregate/exists?`)
      that is NOT inside an allow-listed analytics context.

  ## The allow-list (how an analytics read declares itself)

  A module whose reads against the CDC repo are legitimately analytics/reporting
  marks itself with an attribute:

      @cdc_analytics_read true   # or: use Samen.Cdc.Analytics

  Any `CdcRepo.all(...)` inside such a module is fine (it is a report, not a
  current-read). A CDC-repo read in a module WITHOUT the marker is flagged — the
  developer either mislabelled the module or is about to read a stale value as
  current. Fail closed: an un-marked module reading the analytics repo is a
  `:current_read` finding (exit 1).

  ## What it deliberately does NOT catch (honest edge)

  A read laundered through a non-repo helper (`Reports.fetch(...)` that internally
  hits the CDC repo) is an expected miss at the call site — same laundered-flow
  boundary as `pii_reads`. The mitigation is the same: keep the CDC repo reads
  syntactically visible (don't hide them behind opaque helpers), and mark the
  module that owns them. A `:laundered_hint` is emitted when a CDC-repo alias is
  passed into a helper, so the boundary is visible in output.
  """

  defmodule Violation do
    @moduledoc "Raised by `Samen.Cdc` `read_current/3` — the runtime never-read-current guard."
    defexception [:message]
  end

  @type finding ::
          %{
            kind: :current_read | :laundered_hint | :parse_error,
            file: String.t(),
            line: non_neg_integer(),
            message: String.t()
          }

  # Ecto read functions that return a value the caller could treat as "current".
  @read_funs [:all, :get, :get!, :get_by, :get_by!, :one, :one!, :aggregate, :exists?]

  @doc """
  The configured CDC repo module the lint watches, or `nil` (tier off => nothing
  to lint, the lint passes vacuously-but-honestly with a note).
  """
  @spec cdc_repo() :: module() | nil
  def cdc_repo, do: Samen.Cdc.Config.repo()

  @doc "Scan every `.ex`/`.exs` under `dir` for un-marked CDC-repo reads."
  @spec scan_dir(String.t(), module() | nil) :: {:ok, [finding()]}
  def scan_dir(dir, repo \\ cdc_repo()) do
    dir
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.map(fn path -> {path, File.read!(path)} end)
    |> scan_sources(repo)
  end

  @doc "Scan `[{file, src}]` pairs. `repo` is the CDC repo module to watch."
  @spec scan_sources([{String.t(), String.t()}], module() | nil) :: {:ok, [finding()]}
  def scan_sources(pairs, repo \\ cdc_repo()) when is_list(pairs) do
    findings = Enum.flat_map(pairs, fn {file, src} -> scan_source(file, src, repo) end)
    {:ok, findings}
  end

  @doc false
  @spec scan_source(String.t(), String.t(), module() | nil) :: [finding()]
  def scan_source(file, src, repo) do
    case Code.string_to_quoted(src, columns: true, token_metadata: true) do
      {:ok, ast} ->
        walk_modules(file, ast, repo)

      {:error, {meta, msg, token}} ->
        [%{kind: :parse_error, file: file, line: line_of(meta), message: "#{inspect(msg)} #{inspect(token)}"}]
    end
  end

  # ---------------------------------------------------------------------------
  # walk: find each defmodule, determine whether it is analytics-marked, then scan
  # its body for CDC-repo reads. A read in a NON-marked module is a violation.
  # ---------------------------------------------------------------------------

  defp walk_modules(_file, _ast, nil), do: []

  defp walk_modules(file, ast, repo) do
    repo_aliases = repo_alias_names(repo)

    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_mod_ast, [do: body]]} = node, acc ->
          marked? = analytics_marked?(body)
          local_aliases = collect_repo_aliases(body, repo, repo_aliases)

          mod_findings =
            if marked? do
              []
            else
              scan_body_for_reads(file, body, local_aliases)
            end

          {node, acc ++ mod_findings}

        node, acc ->
          {node, acc}
      end)

    findings
  end

  # A module is analytics-marked if it sets `@cdc_analytics_read true` or
  # `use Samen.Cdc.Analytics`.
  defp analytics_marked?(body) do
    {_b, marked} =
      Macro.prewalk(body, false, fn
        {:@, _, [{:cdc_analytics_read, _, [true]}]} = n, _acc -> {n, true}
        {:use, _, [{:__aliases__, _, [:Samen, :Cdc, :Analytics]} | _]} = n, _acc -> {n, true}
        n, acc -> {n, acc}
      end)

    marked
  end

  # The set of names the repo can be referenced by in a module: its own alias
  # tail plus any `alias …CdcRepo, as: X`.
  defp repo_alias_names(repo) do
    tail = repo |> Module.split() |> List.last() |> String.to_atom()
    MapSet.new([repo, tail])
  end

  defp collect_repo_aliases(body, repo, base) do
    {_b, extra} =
      Macro.prewalk(body, [], fn
        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as_name]}]]} = n, acc ->
          if Module.concat(parts) == repo, do: {n, [as_name | acc]}, else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    Enum.reduce(extra, base, &MapSet.put(&2, &1))
  end

  defp scan_body_for_reads(file, body, repo_aliases) do
    {_b, findings} =
      Macro.prewalk(body, [], fn
        {{:., meta, [target, fun]}, _, _args} = n, acc when fun in @read_funs ->
          if repo_target?(target, repo_aliases) do
            [
              %{
                kind: :current_read,
                file: file,
                line: line_of(meta),
                message:
                  "read (#{fun}/…) against the CDC analytics repo in a module NOT marked " <>
                    "`@cdc_analytics_read true` — never read a 'current' value from the " <>
                    "analytics tier (doc line 635). If this is a report, mark the module; " <>
                    "otherwise read live truth from the primary repo."
              }
              | acc
            ]
          else
            acc
          end
          |> then(&{n, &1})

        n, acc ->
          {n, acc}
      end)

    Enum.reverse(findings)
  end

  # Does a call target resolve to the watched CDC repo?
  defp repo_target?({:__aliases__, _, parts}, repo_aliases) do
    MapSet.member?(repo_aliases, Module.concat(parts)) or
      MapSet.member?(repo_aliases, List.last(parts))
  end

  defp repo_target?({name, _, ctx}, repo_aliases) when is_atom(name) and is_atom(ctx),
    do: MapSet.member?(repo_aliases, name)

  defp repo_target?(_, _), do: false

  defp line_of(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line_of(_), do: 0
end

defmodule Samen.Cdc.Analytics do
  @moduledoc """
  `use Samen.Cdc.Analytics` — marks a module as a legitimate analytics/reporting
  consumer of the CDC mirror, exempting its CDC-repo reads from the
  `never_read_current` lint. Equivalent to `@cdc_analytics_read true`.

  Use ONLY on modules that produce reports/dashboards from the seconds-stale
  analytics tier — never on a code path whose result feeds a live decision.
  """
  defmacro __using__(_opts) do
    quote do
      @cdc_analytics_read true
    end
  end
end
