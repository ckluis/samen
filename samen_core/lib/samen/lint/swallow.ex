defmodule Samen.Lint.Swallow do
  @moduledoc """
  The pure SWALLOW scanner behind both ratchets: `Samen.Lint.KernelSwallow` (samen_core/lib) and
  `Samen.Web.Reads.SwallowLint` (samen_web / driftwood / pawchart). ONE implementation; each app owns
  only its configuration (roots, baselines, reviewed entries). It reads SOURCE only — it never compiles,
  runs or inspects a value — and has no dependency beyond the standard library.

  ## Two classes of swallow

  **`:rescue`** — a `rescue` / `catch` clause whose pattern is a CATCH-ALL (`_`, `_e`, `e`, or
  `_kind, _reason`) and whose body does NOT

    * log (`Logger.*`) or report (`Failure.report/3,5`, `Guard.report/3`),
    * re-raise (`raise` / `reraise`), or
    * hand the exception on (it references the variable the clause bound: `e -> {:error, e}`).

  A TYPED clause (`rescue ArgumentError -> …`) is not a swallow: the author named what can go wrong.

  **`:error_arm`** — the non-rescue form: inside a function that calls an Ash / Ecto / Repo read or
  write, a `case` / `with … else` / `fn` arm `{:error, _} -> <literal>` where the literal is an empty or
  zero value (`[]`, `%{}`, `""`, `0`, `0.0`, `nil`, `false`, `true`, `:ok`) and the error is NOT used — the
  same lie as `rescue _ -> []`, without the exception. An arm that returns a tagged value
  (`{:error, :unavailable}`), re-raises, logs or reports, or that binds and uses the reason, is not flagged.

  ## Reviewed entries — pinned to a count

  `reviewed` maps `{file, function} => {count, reason}`: the function legitimately swallows exactly
  `count` clauses. More clauses than pinned: the EXCESS counts as an ordinary swallow (so a new clause
  added to an already-reviewed function fails the ratchet). Fewer: `reviewed_problems/3` names the stale pin.

  ## The ratchet

  `scan/4` counts unreviewed swallows per file; `check/2` compares to a baseline map and fails when a file has
  MORE (or is not listed — a file absent from the baseline is allowed 0) or FEWER (shrink-only: the
  baseline must be lowered).
  """

  @type reviewed :: %{{String.t(), atom()} => {pos_integer(), String.t()}}
  @type site :: %{fun: atom(), line: integer() | nil, kind: :rescue | :error_arm}

  @literals [[], 0, 0.0, "", nil, false, true, :ok]

  @repo_calls ~w(all one one! get get! get_by get_by! insert insert! update update! delete delete! exists? query query!
                 transaction insert_all update_all delete_all aggregate stream)a

  @ash_calls ~w(read read! read_one read_one! get get! count count! exists? exists aggregate first first! sum sum!
                max min avg list list! load load! create create! update update! destroy destroy! bulk_create
                bulk_update bulk_destroy run_action run_action! calculate calculate! stream! stream)a

  # -- scan -------------------------------------------------------------------------

  @doc """
  Scan one source. `class` is `:rescue` or `:error_arm`; returns `[%{fun:, line:, kind:}]` in source order.
  Reviewed entries are NOT filtered here.
  """
  @spec scan_source(String.t(), String.t(), :rescue | :error_arm) :: [site()]
  def scan_source(source, file \\ "nofile", class \\ :rescue) when class in [:rescue, :error_arm] do
    ast = Code.string_to_quoted!(source, file: file, columns: false)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, collect(class, fun_name(head), body, acc)}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.uniq()
  end

  @doc """
  Unreviewed swallow count per file (zero-count files dropped). `files` are repo-relative paths under
  `root`; `reviewed` is subtracted per `{file, function}` up to its pinned count.
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

  defp sites(rel, root, class), do: root |> Path.join(rel) |> File.read!() |> scan_source(rel, class)

  # Subtract each reviewed function's pinned count; the excess stays.
  defp unreviewed(sites, rel, reviewed) do
    {kept, _budget} =
      Enum.reduce(sites, {[], %{}}, fn site, {kept, used} ->
        case Map.get(reviewed, {rel, site.fun}) do
          {pinned, _reason} ->
            n = Map.get(used, site.fun, 0)
            if n < pinned, do: {kept, Map.put(used, site.fun, n + 1)}, else: {[site | kept], used}

          nil ->
            {[site | kept], used}
        end
      end)

    Enum.reverse(kept)
  end

  @doc """
  Problems with the `reviewed` pins: an entry without a reason, a file missing from `files`, or a function whose
  clause count is no longer the pinned count (fewer: the pin is stale — lower or delete it; more is caught by
  `scan/4`, which counts the excess as unreviewed). `[]` when every pin is exact.
  """
  @spec reviewed_problems(Path.t(), [String.t()], reviewed(), :rescue | :error_arm) :: [String.t()]
  def reviewed_problems(root, files, reviewed, class \\ :rescue) do
    for {{file, fun} = key, {pinned, reason}} <- Enum.sort(reviewed),
        problem <- reviewed_problem(root, files, key, file, fun, pinned, reason, class),
        do: problem
  end

  defp reviewed_problem(root, files, _key, file, fun, pinned, reason, class) do
    cond do
      not (is_binary(reason) and reason != "") ->
        ["#{file} #{fun}: a reviewed entry needs its reason"]

      not (is_integer(pinned) and pinned > 0) ->
        ["#{file} #{fun}: a reviewed entry needs a positive pinned clause count"]

      file not in files ->
        ["#{file} is reviewed but is not in the scanned tree (stale entry)"]

      true ->
        found = file |> sites(root, class) |> Enum.count(&(&1.fun == fun))

        cond do
          found == pinned ->
            []

          found == 0 ->
            ["#{file}: no swallowing clause in #{fun} any more — delete the reviewed entry (its reason is stale)"]

          found < pinned ->
            ["#{file}: #{fun} has #{found} swallowing clause(s) but the reviewed entry pins #{pinned} — lower the pin"]

          true ->
            # found > pinned: `scan/4` counts the excess as unreviewed, so the ratchet fails with the file name too.
            ["#{file}: #{fun} has #{found} swallowing clause(s) but the reviewed entry pins #{pinned} — a new clause was added to a reviewed function"]
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

  # -- AST: rescue / catch -------------------------------------------------------------

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: :__unknown__

  defp collect(:rescue, fun, body, acc) do
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

  defp collect(:error_arm, fun, body, acc) do
    if io_call?(body), do: error_arms(fun, body, acc), else: acc
  end

  defp rescue_clause(fun, key, {:->, meta, [patterns, body]}, acc) do
    if catch_all?(key, patterns) and not handled?(body, bound_vars(patterns)) do
      [%{fun: fun, line: meta[:line], kind: :rescue} | acc]
    else
      acc
    end
  end

  defp rescue_clause(_fun, _key, _other, acc), do: acc

  defp catch_all?(:rescue, [pattern]), do: variable?(pattern)

  defp catch_all?(:catch, patterns),
    do: patterns != [] and Enum.all?(patterns, &(variable?(&1) or &1 in [:exit, :throw, :error]))

  defp variable?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_), do: false

  defp bound_vars(patterns) do
    for {name, _, ctx} <- patterns, is_atom(name), is_atom(ctx), not underscored?(name), do: name
  end

  defp underscored?(name), do: name |> Atom.to_string() |> String.starts_with?("_")

  # Logged / reported / re-raised, or the bound exception is used (handed on to the caller).
  defp handled?(body, vars) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, _ -> {node, true}
        {{:., _, [{:__aliases__, _, aliases}, :report]}, _, _} = node, _ -> {node, List.last(aliases) in [:Guard, :Failure]}
        {:raise, _, _} = node, _ -> {node, true}
        {:reraise, _, _} = node, _ -> {node, true}
        {name, _, ctx} = node, _ when is_atom(name) and is_atom(ctx) -> {node, name in vars}
        node, found -> {node, found}
      end)

    found?
  end

  # -- AST: `{:error, _} -> literal` ----------------------------------------------------

  # Does the function body call an Ash / Ecto / Repo read or write?
  defp io_call?(body) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} = node, _ -> {node, io_module?(aliases, fun)}
        {{:., _, [{recv, _, ctx}, fun]}, _, _} = node, _ when is_atom(recv) and is_atom(ctx) -> {node, repo_var?(recv, fun)}
        node, found -> {node, found}
      end)

    found?
  end

  defp io_module?([:Ash], fun), do: fun in @ash_calls
  defp io_module?([:Ash | _], _fun), do: false
  defp io_module?([:Ecto, :Adapters, :SQL], _fun), do: true
  defp io_module?([:Ecto | _], _fun), do: false
  defp io_module?(aliases, _fun), do: List.last(aliases) == :Repo

  # `repo.all(...)`, `r.exists?(...)`: the conventional repo-variable receivers.
  defp repo_var?(recv, fun), do: recv in [:repo, :r, :rp] and fun in @repo_calls

  defp error_arms(fun, body, acc) do
    {_, acc} =
      Macro.prewalk(body, acc, fn
        {:->, meta, [[pattern], arm_body]} = node, acc ->
          if error_pattern?(pattern) and literal?(arm_body) do
            {node, [%{fun: fun, line: meta[:line], kind: :error_arm} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `{:error, _}` / `{:error, _reason}` (the error is discarded). A bound-and-used reason cannot reach a
  # literal-only body, so only discarded errors qualify.
  defp error_pattern?({:error, {name, _, ctx}}) when is_atom(name) and is_atom(ctx), do: underscored?(name)
  defp error_pattern?(_), do: false

  defp literal?({:__block__, _, [only]}), do: literal?(only)
  defp literal?({:%{}, _, []}), do: true
  defp literal?(value), do: value in @literals
end
