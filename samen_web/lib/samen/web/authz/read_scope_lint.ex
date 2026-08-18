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
    * its clause carries a genuine ORG/PK SCOPING filter — a narrowing call
      (`filter`, `filter_input`, or `for_read`, whether `Ash.Query.`-qualified or the
      bare imported form) whose OWN arguments reference `org_id`/`id` (the atom, or
      the `"org_id"`/`"id"` string key `filter_input` takes). Select-forcing and
      ordering calls (`ensure_selected`, `select`, `sort`, `distinct`, `load`,
      `limit`, …) NEVER count — `ensure_selected([:org_id])` forces `org_id` into the
      SELECT of every org's rows, it scopes nothing (the S15 defect this rule
      closed); nor does a filter on some OTHER field alone — the lint cannot prove a
      non-org/non-PK predicate bounds the read to one tenant, so it demands the
      sanction marker instead;
    * the read carries an explicit, greppable `# authz-scope:` SANCTION marker on or
      just above the read line — the principled exemption for reads that are safe for
      a reason a static org/PK check cannot see: a system-plane sweep (retention,
      digest fan-out, erasure), a pre-auth boot-path lookup keyed on a unique
      credential/token digest (sign-in, invite, API-key auth — org-less because the
      org is not KNOWN yet; the lookup IS the auth step), a webhook-ingest lookup
      keyed on a unique provider ref, or an FK-pinned cascade inside an already
      org-authorized parent write. The marker names WHY it is safe; the lint COUNTS
      every sanctioned read and reports the total, so a sanction is auditable, never
      a silent whitelist.

  A read with NONE of the above is FLAGGED: a bare, unnarrowed `authorize?: false`
  read — the exact reintroduction T127 warns about. The failure names
  `file:line — fun/arity` and tells the author to pin with an `org_id`/`id` filter
  (or, if the read is deliberately org-less, add the `# authz-scope:` marker).

  ## Granularity: a pin/marker justifies EXACTLY its own read (Phase-4 addendum R3/R4/R5)

  The pin and the sanction marker are bound to the INDIVIDUAL read, never to the
  whole clause — closing the three laundering paths the Phase-4 addendum recorded:

    * **R3 (clause-scoped pin/marker launder — the addendum's "most plausible future
      laundering path").** A clause may hold several `authorize?: false` reads. A pin is
      credited to a read only when the scoping construct is in THAT read's own value
      (its pipe chain, its own args, or a variable it reads whose binding carries the
      pin — see below); a filter attached to a SIBLING read never launders it. A
      `# authz-scope:` marker sanctions EXACTLY ONE read — the first governed read at or
      below the marker line, within the clause; a second org-less sibling needs its own
      marker. So `scoped = q |> filter(org_id==^o) |> Ash.read!(...); all = Ash.read!(r,
      authorize?: false)` flags `all` (the pin belongs to `scoped`), and one marker over
      two org-less reads sanctions one and flags the other.
    * **R4 (opts-variable smuggling).** `authorize?: false` reaches a read either
      inline OR via a locally-bound opts variable (`opts = [authorize?: false] ++ …;
      Ash.read(q, opts)`). The lint constant-propagates such a variable INSIDE the
      clause, so the smuggled read is SEEN (governed) and must be pinned/marked like any
      other — it can no longer slip past by hiding `authorize?: false` behind a name.
      The clause-crossing case (opts arriving as a function PARAMETER) is
      un-static-analyzable and is the bounded residual — but it necessarily surfaces as
      an inline `authorize?: false` literal at some CALL site inside the swept trees,
      where R5's relaxed matcher (below) governs it.
    * **R5 (non-`Ash` read wrappers).** The read-verb matcher recognizes the read funs
      on ANY module segment, not only a literal `Ash.` — so an aliased-`Ash` call
      (`alias Ash, as: A; A.read!(…)`) or a same-named wrapper (`ScopedReads.read!(q,
      authorize?: false)`) is governed too, never silently unswept. The bounded residual
      is a wrapper whose name is NOT a read verb (`Reads.page!/3`): fundamentally
      un-static-analyzable from the call site — closed structurally instead, since
      `Samen.Web.Reads.page!/3` RAISES on `authorize?: false` (T127) and every real
      `authorize?: false` read ultimately reaches a matched read verb in the swept
      source, where the clause-local rules above apply.

  ## Scope & posture

  The lint reads SOURCE only — it never executes a query, never touches a record,
  never resolves or reveals a field. It sweeps `samen_core/lib` + `samen_web/lib`
  (the framework planes where `OrgScope` is defined and inherited) AND the three
  vertical trees — `demo/lib`, `driftwood/lib`, `pawchart/lib` — where the exact
  same reintroduction shape can ship (the S15 gap: the verticals carried ~150
  `authorize?: false` sites no lint ever swept). It skips only the seed / fixture
  harnesses (`factory.ex`, `red_path.ex`) whose `authorize?: false` reads run under
  a system actor at setup time, not on a tenant request path. New modules and new
  reads are swept in automatically — an unpinned read cannot go green by simply not
  being named in a test.

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
  # `filter_input` takes STRING keys (`%{"org_id" => …}`) — the same pin, input-typed.
  @pin_strings ["org_id", "id"]
  @sanction_marker "authz-scope:"

  # Basenames skipped: seed / fixture harnesses whose authorize?: false reads run under
  # a system actor at setup, not a tenant request (no cross-tenant surface to leak).
  @skip_basenames ~w(factory.ex red_path.ex read_scope_lint.ex)

  @doc """
  The `.ex` source files under lint: everything beneath `samen_core/lib`,
  `samen_web/lib`, AND the three vertical trees (`demo/lib`, `driftwood/lib`,
  `pawchart/lib` — the S15 sweep extension; a tree absent from the checkout, e.g. in
  a generated app, simply globs to `[]`), minus the seed/fixture harnesses. Anchored
  on THIS file's compile-time path so the glob resolves wherever the suite runs from.
  """
  def source_files do
    # __ENV__.file = .../samen_web/lib/samen/web/authz/read_scope_lint.ex — climb to the
    # samen_web app root, then one more to the repo root that holds all the app trees.
    samen_web_root = __ENV__.file |> Path.dirname() |> Path.join("../../../..") |> Path.expand()
    repo_root = Path.expand(Path.join(samen_web_root, ".."))

    [
      Path.join(repo_root, "samen_core/lib/**/*.ex"),
      Path.join(repo_root, "samen_web/lib/**/*.ex"),
      Path.join(repo_root, "demo/lib/**/*.ex"),
      Path.join(repo_root, "driftwood/lib/**/*.ex"),
      Path.join(repo_root, "pawchart/lib/**/*.ex")
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
      # R4: opts variables locally bound to a keyword list carrying `authorize?: false`
      # — so a read whose `authorize?: false` is smuggled through a name is still SEEN.
      authz_vars = authorize_false_vars(body)
      reads = authz_reads(body, authz_vars)

      if reads == [] do
        {viol, gov, sanc}
      else
        # R3: pins/markers bind to the INDIVIDUAL read, never the whole clause.
        # `pinned_vars` = variables whose binding carries an org/PK scoping construct
        # (a cross-statement pin the read's own chain cannot show).
        pinned_vars = pinned_query_vars(body)
        clause_markers = clause_marker_lines(marker_lines, span)
        read_lines = reads |> Enum.map(fn {_f, rl, _ctx} -> rl end) |> Enum.sort()

        Enum.reduce(reads, {viol, gov, sanc}, fn {read_fun, read_line, ctx}, {v, g, s} ->
          cond do
            read_fun in @by_id_funs or read_fun in @aggregate_funs or
                read_narrowed?(ctx, pinned_vars) ->
              {v, g + 1, s}

            marker_binds?(clause_markers, read_lines, read_line) ->
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

  # Every governed read call in `body`, as `{read_fun, read_line, ctx}`. A read is
  # governed when it names a read fun AND its OWN args carry `authorize?: false` —
  # inline, spread (`[authorize?: false] ++ opts`), OR through a locally-bound opts
  # variable in `authz_vars` (R4). `ctx` is the read's OWN VALUE for the per-read pin
  # check (R3): the enclosing pipe when the read is a pipe RHS (so its upstream
  # `filter`/`for_read` stages count), else the bare call node (so a filter on a SIBLING
  # read never launders it).
  #
  # R5: the read verb is matched on ANY `Module.` segment, not only a literal `Ash.` —
  # an aliased-Ash call or a same-named wrapper (`ScopedReads.read!(…)`) is governed too,
  # never silently unswept. (A wrapper whose NAME is not a read verb is the bounded
  # residual, closed structurally — see the moduledoc.)
  defp authz_reads(body, authz_vars) do
    # Map read-call line -> enclosing pipe node, for reads that are a pipe RHS.
    pipe_ctx =
      body
      |> reduce_prewalk(%{}, fn
        {:|>, _, [_lhs, rhs]} = pipe, acc ->
          case read_call(rhs, authz_vars) do
            {_fun, line} when is_integer(line) -> Map.put_new(acc, line, pipe)
            _ -> acc
          end

        _node, acc ->
          acc
      end)

    body
    |> reduce_prewalk([], fn node, acc ->
      case read_call(node, authz_vars) do
        {fun, line} -> [{fun, line, Map.get(pipe_ctx, line, node)} | acc]
        nil -> acc
      end
    end)
    |> Enum.reverse()
  end

  # `{read_fun, line}` when `node` is a governed read CALL, else nil. Matches a
  # `Module.<read_fun>(args)` call (any module segment — R5) whose args carry
  # `authorize?: false` inline/spread or via a variable in `authz_vars` (R4).
  defp read_call({{:., _, [{:__aliases__, _, [_ | _]}, fun]}, meta, args}, authz_vars)
       when fun in @read_funs and is_list(args) do
    if authorize_off?(args, authz_vars), do: {fun, meta[:line]}, else: nil
  end

  defp read_call(_node, _authz_vars), do: nil

  # Variables locally bound to a value whose AST carries `authorize?: false` (R4): the
  # `opts = [authorize?: false] ++ …` smuggle. Fixpoint so `a = [authorize?: false]; b =
  # a` also counts. Keyed on the bound value only — never widened past the clause.
  defp authorize_false_vars(body) do
    bindings = collect_bindings(body)

    Enum.reduce(1..3, MapSet.new(), fn _i, acc ->
      Enum.reduce(bindings, acc, fn {name, rhs}, a ->
        if authorize_off?([rhs], a), do: MapSet.put(a, name), else: a
      end)
    end)
  end

  # `authorize?: false` reachable from a call's args: the literal pair anywhere in the
  # arg AST (bare opt or `[authorize?: false] ++ opts`), OR a bare variable reference
  # whose name is a known authorize-false var (R4).
  defp authorize_off?(args, authz_vars) do
    walk_any?(args, fn
      {:authorize?, false} -> true
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> MapSet.member?(authz_vars, name)
      _ -> false
    end)
  end

  # Variables whose binding carries an org/PK SCOPING construct (R3 cross-statement pin:
  # `q = Resource |> Ash.Query.filter(org_id == ^o); Ash.read(q, …)`). A read that reads
  # such a variable is credited the pin; a read that does NOT reference it is not.
  # Fixpoint so `a = filter(...); b = a |> …` propagates.
  defp pinned_query_vars(body) do
    bindings = collect_bindings(body)

    Enum.reduce(1..3, MapSet.new(), fn _i, acc ->
      Enum.reduce(bindings, acc, fn {name, rhs}, a ->
        if read_narrowed?(rhs, a), do: MapSet.put(a, name), else: a
      end)
    end)
  end

  # `{var_name, rhs_ast}` for every simple `var = rhs` binding in `body`.
  defp collect_bindings(body) do
    body
    |> reduce_prewalk([], fn
      {:=, _, [{name, _, ctx}, rhs]}, acc when is_atom(name) and is_atom(ctx) ->
        [{name, rhs} | acc]

      _node, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  # A read's OWN value (`ctx`) is NARROWED when it carries a genuine SCOPING construct:
  # a narrowing call (`filter`/`filter_input`/`for_read` — `Ash.Query.`-qualified or the
  # bare imported form) whose OWN args reference the tenant/PK pin (`org_id`/`id`), OR a
  # reference to a `pinned_var` (a variable whose binding carries such a pin — R3
  # cross-statement pin). Because `ctx` is the read's own value (its pipe chain / args),
  # a pin on a SIBLING read is invisible here and cannot launder this read.
  #
  # S15 (luminary panel-2) closed here: the pre-S15 rule ALSO accepted (a) any
  # filter/for_read call regardless of what it filtered on, and (b) an `org_id`/`id`
  # mention inside ANY `Ash.Query.*` call — so `Ash.Query.ensure_selected([:org_id])`
  # (select-FORCING: it puts org_id in the SELECT of every org's rows and scopes
  # NOTHING) counted as an org pin. The pin atoms must sit inside a call that actually
  # CONSTRAINS the row set; everything else needs the `# authz-scope:` sanction marker.
  defp read_narrowed?(ctx, pinned_vars) do
    walk_any?(ctx, fn
      {{:., _, [{:__aliases__, _, [_ | _] = segs}, fun]}, _, args}
      when fun in @narrowing_funs and is_list(args) ->
        List.last(segs) == :Query and args_reference_pin?(args)

      {fun, _, args} when fun in @narrowing_funs and is_list(args) ->
        args_reference_pin?(args)

      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        MapSet.member?(pinned_vars, name)

      _ ->
        false
    end)
  end

  defp args_reference_pin?(args) do
    walk_any?(args, fn
      atom when is_atom(atom) -> atom in @pin_atoms
      str when is_binary(str) -> str in @pin_strings
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

  # The sorted `# authz-scope:` marker lines lying within a clause's raw-source span.
  defp clause_marker_lines(marker_lines, {clause_start, clause_end}) do
    marker_lines
    |> Enum.filter(fn n -> n >= clause_start and n <= clause_end end)
    |> Enum.sort()
  end

  # R3 (marker granularity): a marker binds to EXACTLY ONE read — the first governed
  # read at or below the marker line. `read_line` is sanctioned iff a marker sits in its
  # immediate preceding gap `(prev_read, read_line]`, where `prev_read` is the nearest
  # governed read strictly above it (or 0). A marker already "spent" on an earlier read
  # cannot reach a later sibling, and a marker below a read cannot reach back up to it —
  # so one marker over two org-less reads sanctions one and leaves the other FLAGGED.
  defp marker_binds?(clause_markers, read_lines, read_line) do
    prev_read =
      read_lines
      |> Enum.filter(&(&1 < read_line))
      |> Enum.max(fn -> 0 end)

    Enum.any?(clause_markers, fn m -> m > prev_read and m <= read_line end)
  end

  defp walk_any?(ast, pred) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn node, found -> {node, found or pred.(node)} end)

    found
  end

  # `Macro.prewalk/3` that only threads an accumulator (node is never rewritten).
  defp reduce_prewalk(ast, acc, fun) do
    {_ast, acc} = Macro.prewalk(ast, acc, fn node, a -> {node, fun.(node, a)} end)
    acc
  end
end
