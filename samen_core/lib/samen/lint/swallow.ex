defmodule Samen.Lint.Swallow do
  @moduledoc """
  The pure SWALLOW scanner behind both ratchets: `Samen.Lint.KernelSwallow` (samen_core/lib) and
  `Samen.Web.Reads.SwallowLint` (samen_web / driftwood / pawchart). ONE implementation; each app owns
  only its configuration (roots, baselines, reviewed entries). It reads SOURCE only — it never compiles,
  runs or inspects a value — and has no dependency beyond the standard library.

  ## Two classes of swallow

  **`:rescue`** — a `rescue` / `catch` clause that is either

    * a CATCH-ALL (`_`, `_e`, `e`, or `_kind, _reason`), or
    * TYPED (`ArgumentError`, `_ in [Postgrex.Error, DBConnection.ConnectionError]`) but returning a swallow
      literal (below) — a broad typed list is the same lie as a catch-all, and a typed clause that answers
      `[]` is still an outage rendered as "nothing",

  and whose body does NOT

    * log (`Logger.*`) or report (`Failure.report/3,5`, `Guard.report/3`),
    * re-raise (`raise` / `reraise`), or
    * hand the exception on: the bound variable (or a variable assigned from it) must reach the clause's FINAL
      expression (`e -> {:error, e}`). `e -> _ = e; []` does not count: merely mentioning the variable is not
      handling it.

  **`:error_arm`** — the non-rescue form: inside a function that calls an Ash / Ecto / Repo read or write
  (directly, or through a local function of the same module that does, transitively), a `case` / `with … else` /
  `fn` arm `{:error, _} -> <swallow literal>` and the error is NOT used — the same lie as `rescue _ -> []`,
  without the exception. A `_ -> <swallow literal>` arm counts too when the `case` scrutinee (or a `with` clause)
  is itself such a call. An arm that returns a tagged value (`{:error, :unavailable}`), a different error atom,
  re-raises, logs or reports, or that binds and uses the reason, is not flagged.

  **Swallow literals**: `[]`, `%{}`, `""`, `0`, `0.0`, `nil`, `false`, `true`, `:ok`, `MapSet.new()`,
  `{:ok, <one of those>}`, and a bare atom that does not name an error (`:none`, `:not_found`, `:absent`, …;
  `:error`, `:unavailable`, `:failed`, `:timeout`, … are error signals and are not flagged).

  **Where it looks**: the bodies of `def` / `defp` / `defmacro` / `defmacrop`, and every other node of a module
  body (Ash DSL `change fn …`, `after_action fn …`, validations) under the pseudo-function name `:__module__`.

  **The stated limit.** A reported fail-OPEN — a clause that reports the failure and then answers `true`
  ("allowed") — is not mechanically decidable from source and is NOT caught here: it is the reviewer's job
  (cookbook Recipe 11).

  ## Reviewed entries — pinned to a count AND a hash

  `reviewed` maps `{file, function} => {count, hash, reason}`: the function legitimately swallows exactly
  `count` clauses, and `hash` is the digest of those clauses' (and their enclosing definitions') NORMALISED source (metadata stripped, so it is stable
  across formatting and line moves, and changes when a clause is replaced OR anything else in the enclosing function,
  `try` body included, is edited: the hash covers each clause together with its whole definition). More clauses than pinned: the EXCESS
  counts as an ordinary swallow. A clause that was replaced (the hash no longer matches) is not covered at all.
  Fewer, or a changed hash: `reviewed_problems/3` names the stale pin. `reviewed_hash/4` computes the digest.

  ## The ratchet

  `scan/4` counts unreviewed swallows per file; `check/2` compares to a baseline map and fails when a file has
  MORE (or is not listed — a file absent from the baseline is allowed 0) or FEWER (shrink-only: the
  baseline must be lowered). `check_ceiling/3` adds the hard part: each root has a committed CEILING that the
  sum of its baseline must equal, so raising a baseline row means raising a visible, separately-tested number
  (and `SwallowLintTest` compares every ceiling with the one on the merge base: it can only go down).
  """

  @type reviewed :: %{{String.t(), atom()} => {pos_integer(), String.t(), String.t()}}
  @type site :: %{fun: atom(), line: integer() | nil, kind: :rescue | :error_arm, norm: String.t(), span: String.t()}

  @literals [[], 0, 0.0, "", nil, false, true, :ok]

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  # A bare atom naming a failure is an honest signal, not a claim of absence.
  @error_words ~w(error unavailable failed failure fail timeout refused denied forbidden unauthorized invalid
                  rejected halt halted blocked unreachable offline down closed expired not_configured
                  not_implemented unsupported exception crash crashed)

  @repo_calls ~w(all one one! get get! get_by get_by! insert insert! update update! delete delete! exists? query query!
                 transaction insert_all update_all delete_all aggregate stream)a

  @ash_calls ~w(read read! read_one read_one! get get! count count! exists? exists aggregate first first! sum sum!
                max min avg list list! load load! create create! update update! destroy destroy! bulk_create
                bulk_update bulk_destroy run_action run_action! calculate calculate! stream! stream)a

  # -- scan -------------------------------------------------------------------------

  @doc """
  Scan one source. `class` is `:rescue` or `:error_arm`; returns `[%{fun:, line:, kind:, norm:}]` in source order
  (`norm` is the clause's normalised source, the input of the reviewed hash). Reviewed entries are NOT filtered here.
  """
  @spec scan_source(String.t(), String.t(), :rescue | :error_arm) :: [site()]
  def scan_source(source, file \\ "nofile", class \\ :rescue) when class in [:rescue, :error_arm] do
    ast = Code.string_to_quoted!(source, file: file, columns: false)
    ctx = %{io_funs: io_functions(ast)}

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in @def_kinds ->
          {node, acc |> then(&tag_span(collect(class, fun_name(head), body, ctx, &1), &1, node))}

        {:defmodule, _meta, [_name, [do: block]]} = node, acc ->
          {node, collect_module_body(class, block, ctx, acc)}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.uniq() |> Enum.sort_by(&(&1.line || 0))
  end

  @doc """
  Unreviewed swallow count per file (zero-count files dropped). `files` are repo-relative paths under
  `root`; `reviewed` is subtracted per `{file, function}` up to its pinned count, and only while the pinned
  hash still matches the clauses.
  """
  @spec scan(Path.t(), [String.t()], reviewed(), :rescue | :error_arm) :: %{String.t() => pos_integer()}
  def scan(root, files, reviewed \\ %{}, class \\ :rescue) do
    files
    |> Enum.map(fn rel -> {rel, rel |> sites(root, class) |> unreviewed(rel, reviewed) |> length()} end)
    |> Enum.reject(fn {_rel, n} -> n == 0 end)
    |> Map.new()
  end

  @doc "Every `.ex` file under `trees` (repo-relative), as repo-relative paths."
  @spec files(Path.t(), [String.t()]) :: [String.t()]
  def files(root, trees) do
    for tree <- trees,
        path <- Path.wildcard(Path.join([root, tree, "**", "*.ex"])),
        do: Path.relative_to(path, root)
  end

  @doc """
  The digest a `reviewed` entry pins for the first `count` swallowing clauses of `fun` in `file`: SHA-256 of the
  sorted, metadata-free normalised source of those clauses (16 hex chars). Stable across formatting and line moves.
  """
  @spec reviewed_hash(Path.t(), String.t(), atom(), pos_integer(), :rescue | :error_arm) :: String.t()
  def reviewed_hash(root, file, fun, count, class \\ :rescue) do
    file |> sites(root, class) |> Enum.filter(&(&1.fun == fun)) |> Enum.take(count) |> hash_of()
  end

  # Each site hashes its clause AND the whole enclosing definition (`span`): editing the `try` body or the rest of the
  # function a reviewed clause protects changes the hash, not just rewriting the clause itself.
  defp hash_of(sites) do
    sites
    |> Enum.map(&(&1.span <> "\n==\n" <> &1.norm))
    |> Enum.sort()
    |> Enum.join("\n--\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp sites(rel, root, class), do: root |> Path.join(rel) |> File.read!() |> scan_source(rel, class)

  # Subtract each reviewed function's pinned clauses; the excess stays. A pin whose hash no longer matches the
  # clauses it covers (a REPLACED clause) covers nothing.
  defp unreviewed(sites, rel, reviewed) do
    covered =
      sites
      |> Enum.group_by(& &1.fun)
      |> Enum.flat_map(fn {fun, fun_sites} ->
        case Map.get(reviewed, {rel, fun}) do
          {pinned, hash, _reason} when is_integer(pinned) ->
            taken = Enum.take(fun_sites, pinned)
            if length(taken) == pinned and hash_of(taken) == hash, do: taken, else: []

          _ ->
            []
        end
      end)

    Enum.reject(sites, &(&1 in covered))
  end

  @doc """
  Problems with the `reviewed` pins: an entry without a reason or a hash, a file missing from `files`, a function whose
  clause count is no longer the pinned count (fewer: the pin is stale — lower or delete it; more is caught by
  `scan/4`, which counts the excess as unreviewed), or clauses whose normalised source no longer hashes to the pin (a
  clause was replaced: re-review it). `[]` when every pin is exact.
  """
  @spec reviewed_problems(Path.t(), [String.t()], reviewed(), :rescue | :error_arm) :: [String.t()]
  def reviewed_problems(root, files, reviewed, class \\ :rescue) do
    for {{file, fun}, entry} <- Enum.sort(reviewed),
        problem <- reviewed_problem(root, files, file, fun, entry, class),
        do: problem
  end

  defp reviewed_problem(root, files, file, fun, {pinned, hash, reason}, class) do
    cond do
      not (is_binary(reason) and reason != "") ->
        ["#{file} #{fun}: a reviewed entry needs its reason"]

      not (is_integer(pinned) and pinned > 0) ->
        ["#{file} #{fun}: a reviewed entry needs a positive pinned clause count"]

      not (is_binary(hash) and hash != "") ->
        ["#{file} #{fun}: a reviewed entry needs the hash of the reviewed clauses (Samen.Lint.Swallow.reviewed_hash/5)"]

      file not in files ->
        ["#{file} is reviewed but is not in the scanned tree (stale entry)"]

      true ->
        found_sites = file |> sites(root, class) |> Enum.filter(&(&1.fun == fun))
        found = length(found_sites)

        cond do
          found == 0 ->
            ["#{file}: no swallowing clause in #{fun} any more — delete the reviewed entry (its reason is stale)"]

          found < pinned ->
            ["#{file}: #{fun} has #{found} swallowing clause(s) but the reviewed entry pins #{pinned} — lower the pin"]

          found > pinned ->
            # `scan/4` counts the excess as unreviewed, so the ratchet fails with the file name too.
            ["#{file}: #{fun} has #{found} swallowing clause(s) but the reviewed entry pins #{pinned} — a new clause was added to a reviewed function"]

          hash_of(found_sites) != hash ->
            ["#{file}: #{fun}: the reviewed clause(s) were REPLACED (the normalised source no longer hashes to the pin) — re-review them and update the pin"]

          true ->
            []
        end
    end
  end

  @doc """
  Compare a `scan/4` result to a baseline map. `:ok`, or `{:error, [message]}` naming the file, both counts
  and what to do. `fix` is the app-specific advice appended to an over-baseline message.
  """
  @spec check(map(), map(), String.t()) :: :ok | {:error, [String.t()]}
  def check(counts, baseline, fix \\ "do NOT raise the baseline") do
    problems =
      for file <- Enum.uniq(Map.keys(counts) ++ Map.keys(baseline)),
          have = Map.get(counts, file, 0),
          allowed = Map.get(baseline, file, 0),
          have != allowed do
        if have > allowed do
          "#{file}: #{have} swallowing clause(s), baseline allows #{allowed} — a failed read or write must not " <>
            "turn into an empty result: #{fix}"
        else
          "#{file}: #{have} swallowing clause(s) left but the baseline still allows #{allowed} — " <>
            "lower it to #{have} (the ratchet only shrinks)"
        end
      end

    if problems == [], do: :ok, else: {:error, problems}
  end

  @doc """
  The HARD CEILING. `ceiling` maps each root (`"samen_core/lib"`) to a committed total; the sum of the `baseline`
  rows under that root must EQUAL it. A baseline row raised in a PR therefore fails here until the ceiling is
  raised too (a separate, named number, which `SwallowLintTest` also compares with the merge base), and a baseline
  lowered by a fix fails here until the ceiling follows it down. Every baseline file must sit under a ceiling root.
  """
  @spec check_ceiling(map(), %{String.t() => non_neg_integer()}, [String.t()]) :: :ok | {:error, [String.t()]}
  def check_ceiling(baseline, ceiling, roots) do
    rooted = fn root -> baseline |> Enum.filter(fn {file, _} -> String.starts_with?(file, root <> "/") end) |> Enum.map(&elem(&1, 1)) |> Enum.sum() end

    stray =
      for {file, _} <- baseline, not Enum.any?(roots, &String.starts_with?(file, &1 <> "/")),
          do: "#{file}: a baseline row outside every ceiling root (#{Enum.join(roots, ", ")})"

    totals =
      for root <- roots,
          have = rooted.(root),
          allowed = Map.get(ceiling, root, 0),
          have != allowed do
        if have > allowed do
          "#{root}: the baseline sums to #{have} but the committed ceiling is #{allowed} — the ceiling only goes down; " <>
            "convert a swallow instead of raising a baseline row"
        else
          "#{root}: the baseline sums to #{have} but the committed ceiling is still #{allowed} — lower the ceiling to #{have}"
        end
      end

    if stray ++ totals == [], do: :ok, else: {:error, stray ++ totals}
  end

  # -- AST: shared -----------------------------------------------------------------------

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: :__unknown__

  # A clause with its metadata stripped, printed: stable across formatting and line moves.
  defp normalise(ast) do
    ast
    |> Macro.prewalk(fn
      {a, _meta, c} -> {a, [], c}
      other -> other
    end)
    |> Macro.to_string()
  end

  defp site(fun, kind, {:->, meta, _} = clause), do: %{fun: fun, line: meta[:line], kind: kind, norm: normalise(clause), span: ""}

  # Stamp the sites a collector just added (the head of `acc` beyond `before`) with the normalised enclosing definition.
  defp tag_span(acc, before, enclosing) do
    {added, rest} = Enum.split(acc, length(acc) - length(before))
    span = if added == [], do: "", else: normalise(enclosing)
    Enum.map(added, &Map.put(&1, :span, span)) ++ rest
  end

  # -- AST: module bodies ----------------------------------------------------------------

  # Every node of a module body that is not itself a def (Ash DSL `change fn`, `after_action fn`, validations),
  # under the pseudo-function `:__module__`. Nested defs are pruned (the outer walk collects them under their own
  # names); a nested defmodule is left to the outer walk too.
  defp collect_module_body(class, block, ctx, acc) do
    stmts = block |> block_statements() |> Enum.map(&prune_defs/1) |> Enum.reject(&is_nil/1)
    Enum.reduce(stmts, acc, fn stmt, acc -> tag_span(collect(class, :__module__, stmt, ctx, acc), acc, stmt) end)
  end

  defp block_statements({:__block__, _, stmts}), do: stmts
  defp block_statements(nil), do: []
  defp block_statements(stmt), do: [stmt]

  defp prune_defs(stmt) do
    {pruned, _} =
      Macro.prewalk(stmt, nil, fn
        {kind, _, [_head | _]}, acc when kind in @def_kinds -> {nil, acc}
        {:defmodule, _, _}, acc -> {nil, acc}
        node, acc -> {node, acc}
      end)

    case pruned do
      {kind, _, _} when kind in @def_kinds -> nil
      other -> other
    end
  end

  # -- AST: rescue / catch -------------------------------------------------------------

  defp collect(:rescue, fun, body, _ctx, acc) do
    {_body, acc} =
      Macro.prewalk(body, acc, fn
        kw, acc when is_list(kw) ->
          acc =
            Enum.reduce(kw, acc, fn
              {key, clauses}, acc when key in [:rescue, :catch] and is_list(clauses) ->
                Enum.reduce(clauses, acc, &rescue_clause(fun, key, &1, &2))

              _other, acc ->
                acc
            end)

          {kw, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp collect(:error_arm, fun, body, ctx, acc) do
    if io_call?(body, ctx.io_funs), do: error_arms(fun, body, ctx, acc), else: acc
  end

  defp rescue_clause(fun, key, {:->, _meta, [patterns, body]} = clause, acc) do
    cond do
      catch_all?(key, patterns) and not handled?(body, bound_vars(patterns)) -> [site(fun, :rescue, clause) | acc]
      key == :rescue and typed?(patterns) and swallow_literal?(final_expr(body)) and not logged?(body) -> [site(fun, :rescue, clause) | acc]
      # `catch :exit, {:timeout, _} -> []`: a typed catch answering a swallow literal is the same lie as a typed rescue.
      key == :catch and swallow_literal?(final_expr(body)) and not logged?(body) -> [site(fun, :rescue, clause) | acc]
      true -> acc
    end
  end

  defp rescue_clause(_fun, _key, _other, acc), do: acc

  defp catch_all?(:rescue, [pattern]), do: variable?(pattern)

  defp catch_all?(:catch, patterns),
    do: patterns != [] and Enum.all?(patterns, &(variable?(&1) or &1 in [:exit, :throw, :error]))

  # `ArgumentError`, `e in ArgumentError`, `_ in [A, B]`
  defp typed?([{:__aliases__, _, _}]), do: true
  defp typed?([{:in, _, [_var, _types]}]), do: true
  defp typed?(_), do: false

  defp variable?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_), do: false

  defp bound_vars(patterns) do
    for {name, _, ctx} <- patterns, is_atom(name), is_atom(ctx), not underscored?(name), do: name
  end

  defp underscored?(name), do: name |> Atom.to_string() |> String.starts_with?("_")

  defp final_expr({:__block__, _, stmts}) when stmts != [], do: List.last(stmts)
  defp final_expr(body), do: body

  # Logged / reported / re-raised, or the bound exception REACHES the clause's final expression.
  defp handled?(body, vars), do: logged?(body) or reaches_final?(body, vars)

  defp logged?(body) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, _ -> {node, true}
        {{:., _, [{:__aliases__, _, aliases}, :report]}, _, _} = node, _ -> {node, List.last(aliases) in [:Guard, :Failure]}
        {:raise, _, _} = node, _ -> {node, true}
        {:reraise, _, _} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found?
  end

  # The bound variable (or one assigned from it, `msg = Exception.message(e)`) appears in the final expression.
  # `_ = e` assigns nothing, so it does not count as handling.
  defp reaches_final?(_body, []), do: false

  defp reaches_final?(body, vars) do
    stmts = case body do
      {:__block__, _, stmts} when stmts != [] -> stmts
      other -> [other]
    end

    {init, [last]} = Enum.split(stmts, -1)

    tainted =
      Enum.reduce(init, vars, fn
        {:=, _, [lhs, rhs]}, tainted ->
          if mentions?(rhs, tainted), do: Enum.uniq(tainted ++ bound_in(lhs)), else: tainted

        _other, tainted ->
          tainted
      end)

    mentions?(last, tainted)
  end

  defp mentions?(ast, vars) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        {name, _, ctx} = node, _ when is_atom(name) and is_atom(ctx) -> {node, name in vars}
        node, found -> {node, found}
      end)

    found?
  end

  defp bound_in(pattern) do
    {_, names} =
      Macro.prewalk(pattern, [], fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if underscored?(name), do: {node, acc}, else: {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # -- AST: `{:error, _} -> literal` ----------------------------------------------------

  # The functions of this file that perform Ash / Ecto / Repo I/O, directly or through another local function.
  defp io_functions(ast) do
    {_, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in @def_kinds -> {node, [{fun_name(head), body} | acc]}
        node, acc -> {node, acc}
      end)

    direct = for {name, body} <- defs, io_call?(body, MapSet.new()), into: MapSet.new(), do: name
    grow_io(defs, direct)
  end

  defp grow_io(defs, io) do
    grown =
      for {name, body} <- defs, local_call_into?(body, io), into: io, do: name

    if MapSet.size(grown) == MapSet.size(io), do: io, else: grow_io(defs, grown)
  end

  defp local_call_into?(body, io) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        {:&, _, [{:/, _, [{name, _, ctx}, _arity]}]} = node, _ when is_atom(name) and is_atom(ctx) -> {node, MapSet.member?(io, name)}
        {name, _, args} = node, _ when is_atom(name) and is_list(args) -> {node, MapSet.member?(io, name)}
        node, found -> {node, found}
      end)

    found?
  end

  # Does the expression call an Ash / Ecto / Repo read or write (or a local function that does)?
  defp io_call?(body, io_funs) do
    direct? =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} = node, _ -> {node, io_module?(aliases, fun)}
        {{:., _, [{recv, _, ctx}, fun]}, _, _} = node, _ when is_atom(recv) and is_atom(ctx) -> {node, repo_var?(recv, fun)}
        node, found -> {node, found}
      end)
      |> elem(1)

    direct? or local_call_into?(body, io_funs)
  end

  defp io_module?([:Ash], fun), do: fun in @ash_calls
  defp io_module?([:Ash | _], _fun), do: false
  defp io_module?([:Ecto, :Adapters, :SQL], _fun), do: true
  defp io_module?([:Ecto | _], _fun), do: false
  defp io_module?(aliases, _fun), do: List.last(aliases) == :Repo

  # `repo.all(...)`, `r.exists?(...)`: the conventional repo-variable receivers.
  defp repo_var?(recv, fun), do: recv in [:repo, :r, :rp] and fun in @repo_calls

  defp error_arms(fun, body, ctx, acc) do
    {_, acc} =
      Macro.prewalk(body, acc, fn
        {:->, _meta, [[pattern], arm_body]} = node, acc ->
          if error_pattern?(pattern) and swallow_arm?(arm_body) do
            {node, [site(fun, :error_arm, node) | acc]}
          else
            {node, acc}
          end

        {:case, _, [scrutinee, [do: clauses]]} = node, acc when is_list(clauses) ->
          {node, wildcard_arms(fun, io_call?(scrutinee, ctx.io_funs), clauses, acc)}

        {:with, _, args} = node, acc when is_list(args) ->
          {node, with_wildcard_arms(fun, args, ctx, acc)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `_ -> literal` arms of a case whose scrutinee is itself I/O.
  defp wildcard_arms(fun, true, clauses, acc) do
    Enum.reduce(clauses, acc, fn
      {:->, _, [[pattern], arm_body]} = clause, acc ->
        if wildcard?(pattern) and swallow_arm?(arm_body), do: [site(fun, :error_arm, clause) | acc], else: acc

      _other, acc ->
        acc
    end)
  end

  defp wildcard_arms(_fun, false, _clauses, acc), do: acc

  defp with_wildcard_arms(fun, args, ctx, acc) do
    {clauses, opts} = Enum.split_while(args, &(not is_list(&1)))
    io? = Enum.any?(clauses, &match?({:<-, _, [_, _]}, &1) and io_call?(elem(&1, 2) |> List.last(), ctx.io_funs))

    case opts do
      [kw | _] when is_list(kw) -> wildcard_arms(fun, io?, Keyword.get(kw, :else, []), acc)
      _ -> acc
    end
  end

  # The arm ANSWERS a swallow literal (its final expression, so `_ = 1; []` and `:telemetry.execute(…); []` count) and
  # neither logs, reports nor raises — the same test `rescue_clause/3` applies.
  defp swallow_arm?(body), do: swallow_literal?(final_expr(body)) and not logged?(body)

  defp wildcard?({:_, _, ctx}) when is_atom(ctx), do: true
  defp wildcard?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: underscored?(name)
  defp wildcard?(_), do: false

  # `{:error, _}` / `{:error, _reason}` (the error is discarded). A bound-and-used reason cannot reach a
  # literal-only body, so only discarded errors qualify.
  defp error_pattern?({:error, {name, _, ctx}}) when is_atom(name) and is_atom(ctx), do: underscored?(name)
  defp error_pattern?(_), do: false

  defp swallow_literal?({:__block__, _, [only]}), do: swallow_literal?(only)
  defp swallow_literal?({:%{}, _, []}), do: true
  defp swallow_literal?({{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, args}) when args in [[], [[]]], do: true
  defp swallow_literal?({:ok, inner}), do: plain_literal?(inner)
  defp swallow_literal?(value) when is_atom(value) and value not in [nil, true, false], do: not error_atom?(value)
  defp swallow_literal?(value), do: plain_literal?(value)

  defp plain_literal?({:__block__, _, [only]}), do: plain_literal?(only)
  defp plain_literal?({:%{}, _, []}), do: true
  defp plain_literal?({{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, args}) when args in [[], [[]]], do: true
  defp plain_literal?(value), do: value in @literals

  defp error_atom?(atom) do
    name = Atom.to_string(atom)
    Enum.any?(@error_words, &String.contains?(name, &1))
  end
end
