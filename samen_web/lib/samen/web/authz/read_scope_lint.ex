defmodule Samen.Web.Authz.ReadScopeLint do
  @moduledoc """
  The DEFENSE-IN-DEPTH `authorize?: false` read-scope lint (T132, companion to T127).

  ## What T127 already closed, and the hole this backstops

  `Samen.Web.Reads.page!/3` now RAISES on `authorize?: false` (it refuses to drop
  `OrgScope`) and `page_operator!/3` pins `org_id` by construction — so the *reads
  layer* can no longer mount a cross-tenant read. But `authorize?: false` reads exist
  DIRECTLY across the kernel (`samen_core`) and the web app (`samen_web`) too: the
  operator plane's single-org sweeps, the identity/auth by-credential lookups, the
  billing/notifications/automation system reads. Every one shipped today is
  audited-safe — each carries an explicit narrowing filter (`org_id`, an `id`/PK, or a
  unique credential key), is a by-id `Ash.get`, is a scalar aggregate, or is a
  deliberately org-less system sweep.

  The latent P0 (T127 verify) is a FUTURE one: a new
  `SomeResource |> Ash.read!(authorize?: false)` with NO narrowing returns EVERY org's
  rows — `OrgScope` is a policy, and `authorize?: false` turns policy off. Nothing
  structural stops that from being added. This lint makes the boundary
  governed-by-construction rather than audited-safe-today: a bare, unnarrowed
  `authorize?: false` read FAILS the gate.

  ## The rule

  A function clause performs a GOVERNED read when it calls `Ash.read`, `read!`,
  `read_one`, `read_one!`, `stream!`, `get`, `get!`, `get_by`, `count`, `count!`,
  `exists?`, `aggregate`, `sum!`, `avg!`, `min!` or `max!` **and** that call's own
  arguments carry `authorize?: false` (directly, or spread via `[authorize?: false] ++
  opts`). Such a read is PINNED — and passes — when ANY of the following holds:

    * it is a by-primary-key lookup — the read fn is `get`/`get!`/`get_by` (the id is
      an argument; a single row the caller already holds the id for);
    * it is a scalar aggregate — `count`/`count!`/`exists?`/`aggregate`/`sum!`/…
      (transfers a scalar, never a cross-tenant row set — the aggregate plane);
    * its clause carries an explicit narrowing filter — a call to `filter`,
      `filter_input`, or `for_read` (whether `Ash.Query.filter(...)` or the bare
      imported `filter(...)`), OR the clause references `org_id`/`id` inside a query
      call (the tenant/PK pin, incl. reads whose filter is expressed on a piped var);
    * the read carries an explicit, greppable `# authz-scope:` SANCTION marker on or
      just above the read line — for the small set of deliberately ORG-LESS /
      cross-org reads a static check cannot prove safe (a system retention sweep, an
      operator-namespace anchor bootstrap). The marker names WHY it is safe; the lint
      COUNTS every sanctioned read and reports the total, so a sanction is auditable,
      never a silent whitelist.

  A read with NONE of the above is FLAGGED: a bare, unnarrowed `authorize?: false`
  read — the exact reintroduction T127 warns about. The failure names
  `file:line — fun/arity` and tells the author to pin with an `org_id`/`id` filter
  (or, if the read is deliberately org-less, add the `# authz-scope:` marker).

  ## Scope & posture

  The lint reads SOURCE only — it never executes a query, never touches a record,
  never resolves or reveals a field. It sweeps `samen_core/lib` + `samen_web/lib`
  (the framework planes where `OrgScope` is defined and inherited), skipping the seed
  / fixture harnesses (`factory.ex`, `red_path.ex`) whose `authorize?: false` reads
  run under a system actor at setup time, not on a tenant request path. New modules
  and new reads are swept in automatically — an unpinned read cannot go green by
  simply not being named in a test.

  This is a companion to `Samen.Web.Reads.Lint` (the unbounded-read completeness
  scan): same AST-completeness discipline, a different invariant (scope, not bound).
  """

  alias Samen.Web.Authz.UnscopedReadError

  @read_funs [
    :read,
    :read!,
    :read_one,
    :read_one!,
    :stream!,
    :get,
    :get!,
    :get_by,
    :count,
    :count!,
    :exists?,
    :aggregate,
    :sum!,
    :avg!,
    :min!,
    :max!
  ]

  @by_id_funs [:get, :get!, :get_by]
  @aggregate_funs [:count, :count!, :exists?, :aggregate, :sum!, :avg!, :min!, :max!]
  @narrowing_funs [:filter, :filter_input, :for_read]
  @pin_atoms [:org_id, :id]
  @sanction_marker "authz-scope:"

  # Basenames skipped: seed / fixture harnesses whose authorize?: false reads run under
  # a system actor at setup, not a tenant request (no cross-tenant surface to leak).
  @skip_basenames ~w(factory.ex red_path.ex read_scope_lint.ex)

  @doc """
  The `.ex` source files under lint: everything beneath `samen_core/lib` and
  `samen_web/lib`, minus the seed/fixture harnesses. Anchored on THIS file's compile-
  time path so the glob resolves wherever the suite runs from.
  """
  def source_files do
    # __ENV__.file = .../samen_web/lib/samen/web/authz/read_scope_lint.ex — climb to the
    # samen_web app root, then one more to the repo root that holds both app trees.
    samen_web_root = __ENV__.file |> Path.dirname() |> Path.join("../../../..") |> Path.expand()
    repo_root = Path.expand(Path.join(samen_web_root, ".."))

    [
      Path.join(repo_root, "samen_core/lib/**/*.ex"),
      Path.join(repo_root, "samen_web/lib/**/*.ex")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(fn f -> Path.basename(f) in @skip_basenames end)
    |> Enum.sort()
  end

  @doc """
  Scan one module's `source`. Returns `{violations, governed_count, sanctioned_count}`:

    * `violations` — `%{file:, fun:, arity:, line:}` for every `authorize?: false`
      read that is neither pinned nor sanctioned;
    * `governed_count` — every `authorize?: false` read seen (the non-vacuity counter:
      a scan that parses the module but matches zero governed reads must not green-
      light the gate);
    * `sanctioned_count` — reads that passed ONLY via a `# authz-scope:` marker (the
      audit surface: sanctions are reported, never silent).
  """
  def scan_source(source, file) do
    ast = Code.string_to_quoted!(source, file: file)
    marker_lines = sanction_lines(source)
    total_lines = source |> String.split("\n") |> length()

    ast
    |> collect_clauses()
    |> with_line_spans(total_lines)
    |> Enum.reduce({[], 0, 0}, fn {fun, arity, line, body, span}, {viol, gov, sanc} ->
      reads = authz_reads(body)

      if reads == [] do
        {viol, gov, sanc}
      else
        narrowed? = clause_narrowed?(body)
        marked? = clause_marked?(marker_lines, span)

        Enum.reduce(reads, {viol, gov, sanc}, fn {read_fun, read_line}, {v, g, s} ->
          cond do
            read_fun in @by_id_funs or read_fun in @aggregate_funs or narrowed? ->
              {v, g + 1, s}

            marked? ->
              {v, g + 1, s + 1}

            true ->
              offender = %{file: file, fun: fun, arity: arity, line: line, read_line: read_line}
              {[offender | v], g + 1, s}
          end
        end)
      end
    end)
    |> then(fn {viol, gov, sanc} -> {Enum.reverse(viol), gov, sanc} end)
  end

  # Attach each clause's raw-source line span `{start, end}` — end is the line before the
  # NEXT clause starts (last clause runs to EOF) — so a `# authz-scope:` marker anywhere
  # inside the clause counts, regardless of how many lines the reason spans.
  defp with_line_spans([], _total_lines), do: []

  defp with_line_spans(clauses, total_lines) do
    sorted = Enum.sort_by(clauses, fn {_f, _a, line, _b} -> line || 0 end)
    starts = Enum.map(sorted, fn {_f, _a, line, _b} -> line || 0 end)
    ends = (tl(starts) |> Enum.map(&(&1 - 1))) ++ [total_lines]

    sorted
    |> Enum.zip(ends)
    |> Enum.map(fn {{fun, arity, line, body}, clause_end} ->
      start = line || 0
      {fun, arity, line, body, {start, max(clause_end, start)}}
    end)
  end

  @doc """
  Scan every file in `files` (default `source_files/0`). Returns
  `{:ok, %{files:, governed_reads:, sanctioned_reads:}}` when every
  `authorize?: false` read is pinned or sanctioned; raises `UnscopedReadError`
  listing every unpinned offender otherwise — the LOUD gate failure T132 requires.
  """
  def assert_all_scoped!(files \\ source_files()) do
    {violations, governed, sanctioned} =
      Enum.reduce(files, {[], 0, 0}, fn file, {av, ag, as} ->
        {v, g, s} = file |> File.read!() |> scan_source(file)
        {av ++ v, ag + g, as + s}
      end)

    case violations do
      [] ->
        {:ok, %{files: length(files), governed_reads: governed, sanctioned_reads: sanctioned}}

      violations ->
        raise UnscopedReadError,
          message:
            "UNSCOPED `authorize?: false` READ(S) (T132 defense-in-depth): a direct read " <>
              "with `authorize?: false` turns OrgScope OFF and, unnarrowed, returns EVERY " <>
              "org's rows. Pin it with an explicit `org_id`/`id` filter (or a by-id Ash.get, " <>
              "or a scalar aggregate); if the read is DELIBERATELY org-less (a system sweep " <>
              "/ operator anchor), add a `# authz-scope: <why-safe>` marker on the read line.\n" <>
              Enum.map_join(violations, "\n", fn v ->
                "  * #{Path.relative_to_cwd(v.file)}:#{v.read_line} — #{v.fun}/#{v.arity}"
              end)
    end
  end

  # -- AST walking ---------------------------------------------------------------

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

  # Every `Ash.<read>` call in `body` whose OWN args carry `authorize?: false`, as
  # `{read_fun, line}`. Keyed on the call node's args (not the whole clause) so a read
  # that does NOT pass authorize?: false is never treated as governed.
  defp authz_reads(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Ash]}, fun]}, meta, args} = node, acc
        when fun in @read_funs and is_list(args) ->
          if authorize_false?(args) do
            {node, [{fun, meta[:line]} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # `authorize?: false` appearing anywhere in the call's argument AST — catches a bare
  # `authorize?: false` opt and the `[authorize?: false] ++ opts` spread idiom.
  defp authorize_false?(args), do: walk_any?(args, &authorize_false_pair?/1)

  defp authorize_false_pair?({:authorize?, false}), do: true
  defp authorize_false_pair?(_), do: false

  # A clause is NARROWED when it contains an explicit filter/for_read call, OR
  # references org_id/id inside a query call — the tenant/PK pin.
  defp clause_narrowed?(body), do: has_narrowing_call?(body) or references_pin?(body)

  defp has_narrowing_call?(body) do
    walk_any?(body, fn
      {{:., _, [{:__aliases__, _, segs}, fun]}, _, args}
      when fun in @narrowing_funs and is_list(args) ->
        List.last(segs) == :Query

      {fun, _, args} when fun in @narrowing_funs and is_list(args) ->
        true

      _ ->
        false
    end)
  end

  # An `org_id`/`id` reference inside a query/filter call — the actual scope pin. Only
  # counts when it appears as an ARGUMENT to an `Ash.Query.*` / `filter*` / `for_read`
  # call (a filter/select/for_read on org_id or id), never a bare mention elsewhere.
  defp references_pin?(body) do
    walk_any?(body, fn
      {{:., _, [{:__aliases__, _, [_ | _] = segs}, _fun]}, _, args} ->
        List.last(segs) == :Query and args_reference_pin?(args)

      {fun, _, args} when fun in @narrowing_funs and is_list(args) ->
        args_reference_pin?(args)

      _ ->
        false
    end)
  end

  defp args_reference_pin?(args) do
    walk_any?(args, fn
      atom when is_atom(atom) -> atom in @pin_atoms
      {atom, _, ctx} when is_atom(atom) and is_atom(ctx) -> atom in @pin_atoms
      _ -> false
    end)
  end

  # -- sanction markers (raw source) ---------------------------------------------

  # 1-based line numbers carrying a `# authz-scope:` marker.
  defp sanction_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, @sanction_marker) end)
    |> Enum.map(fn {_line, n} -> n end)
    |> MapSet.new()
  end

  # A clause is sanctioned when a `# authz-scope:` marker sits anywhere within its raw-
  # source line span (the author names WHY the org-less read is safe, at the read site).
  defp clause_marked?(marker_lines, {clause_start, clause_end}) do
    Enum.any?(clause_start..clause_end, &MapSet.member?(marker_lines, &1))
  end

  defp walk_any?(ast, pred) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn node, found -> {node, found or pred.(node)} end)

    found
  end
end
