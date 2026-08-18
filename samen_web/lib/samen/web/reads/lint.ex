defmodule Samen.Web.Reads.Lint do
  @moduledoc """
  The EXHAUSTIVE `read!`-elimination lint (AC-G1-5, A3-GATE-2 closure).

  `Samen.Web.Reads.bounded!/4` is an OPT-IN runtime probe: it proves a specific reads
  function is bounded, but only for the functions a test explicitly hands it. That
  opt-in shape is exactly how `Samen.Web.CRM.Reads.pipeline/2` and the chat reads
  shipped UNBOUNDED behind mounted LiveViews while the gate reported green
  (A3-GATE-1): a reads function nobody opted in was invisible.

  This module closes the hole with a COMPLETENESS scan: it parses the SOURCE of every
  `reads.ex` module under `samen_web/lib/samen/web/` and asserts that **every function
  clause that performs an Ash read also carries an explicit bound in the same clause**.
  New reads modules and new reads functions are swept in automatically — an unconverted
  read cannot go green by simply not being mentioned in a test.

  ## The rule

  A function clause CONTAINS A READ when it calls any of
  `Ash.read!/read/read_one!/read_one/stream!`.

  A read-bearing clause IS BOUNDED when the same clause also contains one of:

    * `Ash.Query.limit(...)` — the explicit cap (`@detail_limit` / `@lookup_limit` /
      `limit(1)` single-id reads);
    * `Samen.Web.Reads.page!(...)`, `Samen.Web.Reads.page_operator!(...)`, or
      `Samen.Web.Reads.build(...)` (any alias ending in `Reads`) — the keyset builder, which
      applies `limit(page_size + 1)` by construction.

  Aggregate reads (`Ash.count!`/`Ash.sum!`/`Ash.aggregate`) transfer a scalar, never a
  row set — they are bounded by construction and not flagged.

  This is a STATIC companion to the runtime `bounded!/4` probe, not a replacement: the
  probe proves the observable bound for the `ListLive` page contract; this scan proves
  NO read anywhere in the reads layer omits a bound. Deliberately conservative: a
  clause that delegates its read to a helper is only checked where the `Ash.read!`
  literally appears (the helper's own clause), so every read site is checked exactly
  once and a bound can never be "inherited" from a caller that might not apply.

  ## Masking / PII posture

  The lint reads SOURCE CODE only. It never executes a query, never touches a record,
  never resolves or reveals a field.
  """

  alias Samen.Web.Reads.UnboundedReadError

  @read_funs [:read!, :read, :read_one!, :read_one, :stream!]
  @bound_funs [:page!, :page_operator!, :build]

  # ADR-045 §4.2 (O8) — the SHIPPED vertical read layers. The original glob anchored inside
  # `samen_web/lib/samen/web/`, so `driftwood/lib/driftwood/reads.ex` and
  # `pawchart/lib/pawchart_web/clinic_reads.ex` were INVISIBLE to the completeness scan — the
  # verticals reproduced the A3-GATE-1 unbounded-read defect one directory outside the scanner
  # (`Driftwood.Reads.driver_roster/1`). These trees are now swept too, so a future unbounded
  # vertical read fails the gate instead of silently mounting. The pattern is `*reads.ex` (not
  # just `reads.ex`) so `clinic_reads.ex` is caught alongside `reads.ex`.
  @vertical_read_trees ["driftwood/lib", "pawchart/lib"]

  @doc """
  The reads modules under lint: every `reads.ex` beneath `lib/samen/web/` in the
  `samen_web` app (chat, crm, billing, support, marketing, operator, and any module a
  future phase adds — new files are swept in automatically), PLUS the shipped vertical
  read layers (driftwood/pawchart — ADR-045 §4.2 O8), so an unbounded vertical read is
  caught by the gate rather than living one directory outside the scanner.
  """
  def reads_files do
    framework_reads_files() ++ vertical_reads_files()
  end

  # `__ENV__.file` is this file's compile-time source path (.../lib/samen/web/reads/
  # lint.ex), so the glob anchors on the source tree wherever the suite runs from.
  defp framework_reads_files do
    __ENV__.file
    |> Path.dirname()
    |> Path.join("../**/reads.ex")
    |> Path.expand()
    |> Path.wildcard()
  end

  @doc """
  The shipped vertical read-layer files under lint (driftwood/pawchart) — ADR-045 §4.2 (O8).
  Anchored on this file's compile-time path (repo root is five levels above the `reads`
  dir), so it is cwd-independent like `framework_reads_files/0`. Matches `*reads.ex`, so
  `clinic_reads.ex` is covered as well as `reads.ex`.
  """
  def vertical_reads_files do
    root = repo_root()

    Enum.flat_map(@vertical_read_trees, fn tree ->
      root
      |> Path.join(tree)
      |> Path.join("**/*reads.ex")
      |> Path.wildcard()
    end)
  end

  # <root>/samen_web/lib/samen/web/reads/lint.ex → ascend 5 dirs to the repo root.
  defp repo_root do
    __ENV__.file
    |> Path.dirname()
    |> Path.join("../../../../..")
    |> Path.expand()
  end

  @doc """
  Scan `source` (one reads module) and return `{violations, read_clause_count}`:
  `violations` is a list of `%{file:, fun:, arity:, line:}` for every read-bearing
  function clause WITHOUT a bound; `read_clause_count` counts every read-bearing
  clause seen (bounded or not) — the caller's non-vacuity check (a scan that parses
  the module but matches zero reads would otherwise green-light everything).
  """
  def scan_source(source, file) do
    ast = Code.string_to_quoted!(source, file: file)

    clauses = collect_clauses(ast)

    read_clauses =
      Enum.filter(clauses, fn {_fun, _arity, _line, body} -> contains_read?(body) end)

    violations =
      read_clauses
      |> Enum.reject(fn {_fun, _arity, _line, body} -> contains_bound?(body) end)
      |> Enum.map(fn {fun, arity, line, _body} ->
        %{file: file, fun: fun, arity: arity, line: line}
      end)

    {violations, length(read_clauses)}
  end

  @doc """
  Scan every file in `files` (default `reads_files/0`). Returns
  `{:ok, %{files: n, read_clauses: n}}` when every read is bounded; raises
  `Samen.Web.Reads.UnboundedReadError` listing every offender otherwise — the LOUD
  failure AC-G1-5 requires (an unbounded read fails the suite, it is never silently
  mounted).
  """
  def assert_all_bounded!(files \\ reads_files()) do
    {violations, read_clauses} =
      Enum.reduce(files, {[], 0}, fn file, {acc_v, acc_n} ->
        {v, n} = file |> File.read!() |> scan_source(file)
        {acc_v ++ v, acc_n + n}
      end)

    case violations do
      [] ->
        {:ok, %{files: length(files), read_clauses: read_clauses}}

      violations ->
        raise UnboundedReadError,
          message:
            "UNBOUNDED READ(S) in the reads layer (AC-G1-5 / A3-GATE-1): every function " <>
              "clause that performs an Ash read must carry Ash.Query.limit/2 or route " <>
              "through Samen.Web.Reads.page!/3 (or build/3) in the SAME clause.\n" <>
              Enum.map_join(violations, "\n", fn v ->
                "  * #{Path.relative_to_cwd(v.file)}:#{v.line} — #{v.fun}/#{v.arity}"
              end)
    end
  end

  # -- AST walking ---------------------------------------------------------------

  # Every def/defp clause in the module (including clauses inside nested modules),
  # as {fun_name, arity, line, body_ast}. The body includes the whole do-block plus
  # any rescue/else clauses — a bound anywhere in the clause counts.
  defp collect_clauses(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {def_kind, meta, [head, body]} = node, acc when def_kind in [:def, :defp] ->
          {fun, arity} = fun_arity(head)
          {node, [{fun, arity, meta[:line], body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp fun_arity({:when, _, [head | _guards]}), do: fun_arity(head)
  defp fun_arity({fun, _, args}) when is_atom(fun) and is_list(args), do: {fun, length(args)}
  defp fun_arity({fun, _, _}) when is_atom(fun), do: {fun, 0}
  defp fun_arity(_), do: {:__unknown__, 0}

  defp contains_read?(body), do: contains_call?(body, [:Ash], @read_funs)

  defp contains_bound?(body) do
    contains_call?(body, [:Ash, :Query], [:limit]) or reads_builder_call?(body)
  end

  # A call to `page!`/`build` on ANY alias whose last segment is `Reads`
  # (`Samen.Web.Reads.page!`, `Reads.page!` under an alias, …) — or a LOCAL
  # `page!`/`build` call (inside `Samen.Web.Reads` itself, whose `page!/3` pipes
  # through its own `build/3` → `Ash.Query.limit`).
  defp reads_builder_call?(body) do
    walk_any?(body, fn
      {{:., _, [{:__aliases__, _, segments}, fun]}, _, _}
      when fun in @bound_funs and is_list(segments) ->
        List.last(segments) == :Reads

      {fun, _, args} when fun in @bound_funs and is_list(args) ->
        true

      _ ->
        false
    end)
  end

  defp contains_call?(body, alias_segments, funs) do
    walk_any?(body, fn
      {{:., _, [{:__aliases__, _, ^alias_segments}, fun]}, _, _} when is_atom(fun) ->
        fun in funs

      _ ->
        false
    end)
  end

  defp walk_any?(ast, pred) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn node, found ->
        {node, found or pred.(node)}
      end)

    found
  end
end
