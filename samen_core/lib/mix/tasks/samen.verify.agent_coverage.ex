defmodule Mix.Tasks.Samen.Verify.AgentCoverage do
  @shortdoc "ADR-047 §9#6 gate: the agent loop is self-defending — F-4 raw-spawn AST lock + coverage floor."

  @moduledoc """
  `mix samen.verify.agent_coverage` — the ADR-047 §9#6 coverage gate (batch **A7**, the
  final batch). Where `mix samen.verify.ai_prompt_masking` means *"INV-7 holds
  structurally"* (and gains the two agent-tool INV-7 checks (d)/(e) at A7), THIS task means
  *"the agent loop A1–A6 built is self-defending and cannot be silently reopened."* The
  split is operator decision §9#6 (TAKEN): mixing DX-coverage assertions into the security
  gate makes a red `ai_prompt_masking` ambiguous, which the thing a security gate must never
  be.

  It mirrors the house verifier shape (`run/1` → `Samen.Verifier.halt_if_violations/2`;
  `violations/1` callable without halting for the anti-tautology test), and is wired into
  the ROOT `ci.sh` (run from `samen_core`, scanning the whole umbrella tree — the
  `Samen.AI.ChokepointAntiBypassProbeTest` technique).

  ## What it asserts

    * **(1) THE F-4 RAW-SPAWN AST LOCK (ADR-047 §10a row 19, the A6 verifier's R-A6-3).**
      NO module that exports `tool_schema/0` (i.e. no agent-callable tool/action) may call
      `Samen.AI.Agent.start/…` or `Samen.AI.Agent.run/…` — the two loop-entry primitives.
      A6 found this property already-true of the shipped code and proved (live) that the
      raw-`spawn/1` recursion-marker escape is defence-in-depth, unreachable from tenant
      data. This gate LOCKS IT IN by static AST scan so a future edit cannot reopen the
      raw-spawn recursion escape: a tool that cannot even name `Agent.start/run` cannot
      re-enter the loop, regardless of which spawn primitive it reaches for. This is the
      single most load-bearing assertion in this task, and its positive control (a fixture
      tool that DOES call `Agent.start` MUST flip the scan) is the anti-tautology proof.

      **Alias resolution (UXD-05).** A `List.last(parts) == :Agent` test is blind to every
      NAME-BINDING form that gives the kernel a different spelling, so `alias_env/1` builds
      the file's ALIAS ENVIRONMENT and `resolves_to_kernel?/3` applies Elixir's own
      resolution rule — head-segment substitution — to every module reference. WHAT THIS
      CLOSES, in all five call shapes (direct-call, `apply/3`, `Kernel.apply/3`,
      `:erlang.apply/3`, pipe): a rename of the kernel itself (`alias Samen.AI.Agent, as: A`);
      a rename of ANY PREFIX segment at any depth (`alias Samen.AI, as: A` then
      `A.Agent.start/…`, or `alias Samen, as: S` then `S.AI.Agent.start/…`); a chain of
      either through further `as:` hops of any depth, in either declaration order; the brace
      form (`alias Samen.AI.{Agent, …}`, including on a renamed prefix); an alias declared
      inside a function body rather than at the top of the module; a name declared twice
      (shadowing — BOTH right-hand sides count); Elixir's OTHER alias-creating form,
      `require Samen.AI.Agent, as: A` (and the prefix form `require Samen.AI, as: A`),
      including when it seeds a further `alias`/`require` chain — added at UXD-05 attempt 4,
      `require_bindings/1`; an ATOM alias target, `alias :"Elixir.Samen.AI.Agent", as: A`,
      which `Code.string_to_quoted/2` yields with no `__aliases__` wrapper — also attempt 4,
      the atom clause of `alias_bindings/1`; and a `__MODULE__`-relative or otherwise
      statically unresolvable prefix, which is re-tested on its literal suffix alone. The
      raw, unexpanded reference is tested too, so this check is a strict SUPERSET of the
      pre-fix literal one. See `resolves_to_kernel?/3` for the termination argument — no
      alias cycle, and no self-growing alias such as `alias A.B, as: A`, can hang the scan.

      **KNOWN RESIDUALS — DOCUMENTED, NOT CLOSED.** This lock is a static AST scan of one
      file at a time. It does NOT catch, and does not claim to:

        1. **Dynamic module construction.** `mod = Module.concat(Samen.AI, Agent);
           apply(mod, :start, [...])`. No `__aliases__` node and no atom literal names the
           target at the call site, so there is nothing static to resolve — a DISTINCT
           vulnerability class from an alias rename (which is a compile-time textual
           substitution the AST still names). Closing it needs data-flow/taint tracking and
           should be scoped as its own item, not folded in here silently.
        2. **The unparsable-source fallback.** When `Code.string_to_quoted/2` fails, the
           scan degrades to `reentry_regex_fallback?/1`, a hardcoded literal-name regex with
           NO alias tracking at all: every rename above evades that branch. It is reached
           only by source that does not compile.
        3. **Indirection through another module or a macro.** A reference the kernel gains
           only after macro expansion, or a call routed through a helper module in a
           different file, is invisible to a per-file pre-expansion scan.
        4. **MODULE-ATTRIBUTE INDIRECTION** (UXD-05 attempt 4, named here because it was
           found live and silent). `@k Samen.AI.Agent` followed by `@k.start(...)` or
           `apply(@k, :start, [...])` INSIDE a `tool_schema/0` module is a working call
           that this lock DOES NOT FLAG. A module attribute is not an alias: it is a
           compile-time binding held in the module's own attribute table, so it never
           enters `alias_env/1`, and the call site's target is an `{:@, _, _}` node that
           `agent_kernel_alias?/2` has no clause for. Resolving it means tracking attribute
           assignment and re-binding (attributes may be reassigned, accumulated, or set
           from another attribute), i.e. the same data-flow analysis residual 1 needs —
           deliberately NOT folded in here. This is a STATED, TESTED limit: the negative
           control is `"KNOWN RESIDUAL (module-attribute indirection)"` in
           `test/ai/agent_coverage_verifier_test.exs`.

      Residuals 1 and 4 are pinned by negative-control tests, and a further test asserts
      this paragraph is still present in this source, so deleting any disclosure above
      turns it red (`test/ai/agent_coverage_verifier_test.exs`, the "KNOWN RESIDUAL" tests).

      **Unqualified `import`.** `import Samen.AI.Agent` binds `start/…` and `run/…` as bare
      names, which no qualified-call clause can see. `imported_kernel_reentry?/2` closes
      that: when a file imports the kernel (resolved through the same alias environment), a
      bare `start(…)`/`run(…)` call counts as reentry. `def`/`defp` heads are stripped first
      so a module's own `def start(…)` definition is never mistaken for a call.

    * **(2) every opted-in tool declares BOTH callbacks and carries a test** (ADR-047 §7.2
      check 2). Every kind in `Samen.Automation.Action.tool_kinds()` exports `tool_schema/0`
      AND `effect/0`, and at least one test file names the kind.

    * **(3) the agent-run resource carries a retention `:shred` spec** (ADR-047 §7.4 /
      §9#4) — erasure reach is a coverage FACT, not a hope. `Samen.Erasure.default_specs/1`
      must derive a `:shred` retention arm for `Samen.AI.Agent.Run`.

    * **(4) NON-VACUITY FLOOR** (ADR-047 §7.2 check 4; the ADR-046 E7 lesson — *a gate that
      discovers nothing verifies nothing*). Discovery MUST find ≥1 agent (a `use
      Samen.AI.Agent` module in the tree) and ≥1 opted-in tool, else FAIL.

    * **(5) every discovered agent ships an `AgentCase` proof** (ADR-047 §7.2 check 1) — a
      test file that both names the agent module and `use`s `Samen.AgentCase`.

    * **(6) THE TREE-WIDE LEVERAGE GUARD** (the A6 verifier's R-A6-1). The shipped
      driftwood leverage guard read ONE file; it could not catch framework agent behaviour
      re-implemented in a DIFFERENT vertical module — the exact evasion the guard forbids.
      This folds the tree-wide form in: in every vertical (`driftwood`/`pawchart`/`demo`),
      the only `lib/` files that may reference the `Samen.AI.Agent` kernel are the agent
      DEFINITION modules (`use Samen.AI.Agent`) and the ROUTER (`samen_ai_routes`).

  ## Scope of the scan

  The AST/text scan walks every app's `lib/` (the anti-bypass probe's `@app_lib_globs`),
  never `test/` or `deps/` — a test fixture that calls `Agent.start` from a
  `tool_schema/0` module is legitimate proof material, not a shipped hole.
  """

  use Mix.Task

  @task_name "samen.verify.agent_coverage"

# Every app's `lib/` (the anti-bypass probe's scope). Globbed (`*/lib`, `spikes/*/lib`)
  # rather than named so this source carries NO vendor-adapter substring (the INV-4
  # vendor-free lib scan) and a new app is covered automatically.
  @app_lib_globs ~w(*/lib spikes/*/lib)

  @verticals ~w(driftwood pawchart demo)

  @agent_run_resource Samen.AI.Agent.Run

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _} = OptionParser.parse(args, strict: [root: :string])
    Samen.Verifier.halt_if_violations(@task_name, violations(opts))
  end

  @doc "The full violation list (human-readable strings) without halting — the test seam."
  @spec violations(keyword()) :: [String.t()]
  def violations(opts \\ []) do
    root = repo_root(opts)
    lib_paths = lib_paths(root)
    agent_files = discover_agent_files(lib_paths)
    tool_kinds = tool_kinds()

    floor_violations(agent_files, tool_kinds) ++
      spawn_lock_violations(lib_paths, root) ++
      tool_callback_violations(tool_kinds, root) ++
      retention_violations() ++
      agent_test_violations(agent_files, root) ++
      agent_tools_subset_violations(agent_files) ++
      leverage_violations(root)
  end

  # --- agent tools ⊆ opted-in registry (ADR-047 §7.2 check (e) / §5.1 arms 1-3) ----------
  # Parsed from each agent's `use Samen.AI.Agent, tools: [...]` in lib/ SOURCE (never the
  # runtime module set — that would sweep in deliberately-adversarial test fixtures), so a
  # SHIPPED agent declaring a tool the four-way intersection would reject is caught statically.

  @doc "Agents whose declared `tools:` include a non-opted-in kind (public for the test)."
  @spec agent_tools_subset_violations([{String.t(), String.t()}]) :: [String.t()]
  def agent_tools_subset_violations(agent_files) do
    opted_in = MapSet.new(tool_kinds())

    for {path, module} <- agent_files,
        tool <- agent_declared_tools(File.read!(path)),
        not MapSet.member?(opted_in, tool) do
      "the agent #{module} declares tool #{inspect(tool)} which is NOT an opted-in registry " <>
        "action — an agent's `tools:` must be a subset of the opted-in tools (ADR-047 §5.1)."
    end
  end

  @doc "The `tools:` list declared in a `use Samen.AI.Agent, …` source (AST), or `[]`."
  @spec agent_declared_tools(String.t()) :: [String.t()]
  def agent_declared_tools(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, emit_warnings: false),
         opts when is_list(opts) <- agent_use_opts(ast),
         tools when is_list(tools) <- Keyword.get(opts, :tools) do
      Enum.filter(tools, &is_binary/1)
    else
      _ -> []
    end
  end

  defp agent_use_opts(ast) do
    {_ast, opts} =
      Macro.prewalk(ast, nil, fn
        {:use, _, [alias_ast, opts]} = node, nil ->
          if exact_agent_alias?(alias_ast) and Keyword.keyword?(opts), do: {node, opts}, else: {node, nil}

        node, acc ->
          {node, acc}
      end)

    opts
  end

  # --- (1) THE F-4 RAW-SPAWN AST LOCK ----------------------------------------------------

  @doc """
  Files under `lib/` that BOTH export `tool_schema/0` AND call `Samen.AI.Agent.start/…`
  or `Samen.AI.Agent.run/…` — the raw-spawn recursion escape reopened. Public so the
  positive-control test can feed it a rogue path.
  """
  @spec spawn_lock_violations([String.t()], String.t()) :: [String.t()]
  def spawn_lock_violations(lib_paths, root) do
    for path <- lib_paths,
        File.regular?(path),
        source = File.read!(path),
        source_defines_tool_schema?(source),
        source_reenters_loop?(source) do
      "#{rel(path, root)}: a `tool_schema/0`-exporting module (an agent-callable tool) " <>
        "calls `Samen.AI.Agent.start/run` — this reopens the raw-spawn recursion escape " <>
        "the F-4 static lock forbids (ADR-047 §10a row 19). A tool may never re-enter the " <>
        "agent loop."
    end
  end

  @doc "Does `source` define a `tool_schema/0` (an agent-tool opt-in)? (AST, text fallback.)"
  @spec source_defines_tool_schema?(String.t()) :: boolean()
  def source_defines_tool_schema?(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} -> ast_any?(ast, &tool_schema_def?/1)
      {:error, _} -> Regex.match?(~r/^\s*def\s+tool_schema\b/m, source)
    end
  end

  @doc "Does `source` call `Samen.AI.Agent.start/…` or `.run/…`? (AST, text fallback.)"
  @spec source_reenters_loop?(String.t()) :: boolean()
  def source_reenters_loop?(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} ->
        # UXD-05: a bare `List.last(parts) == :Agent` test is blind to every `alias` form
        # that gives the kernel a different spelling. Rather than special-casing shapes one
        # at a time (attempt 1 closed `alias Samen.AI.Agent, as: A`; attempt 2 closed
        # `alias A, as: B` chains; each was then evaded by the next shape), build the file's
        # ALIAS ENVIRONMENT once and apply Elixir's own resolution rule — head-segment
        # substitution — to every module reference. See `alias_env/1`.
        env = alias_env(ast)
        ast_any?(ast, &agent_reentry_call?(&1, env)) or imported_kernel_reentry?(ast, env)

      {:error, _} ->
        reentry_regex_fallback?(source)
    end
  end

  # --- the alias environment (UXD-05, attempt 3) -----------------------------------------
  #
  # THE RULE, not a pattern for the last bug. In Elixir every `alias` form binds a single
  # atom (its FIRST segment when used) to a list of parts, and a module reference
  # `[Head | Rest]` resolves by replacing `Head` with its binding and re-resolving:
  #
  #   * `alias P.Q.R`          -> binds `R`  to `[:P, :Q, :R]`  (implicit `as:` = last segment)
  #   * `alias P.Q.R, as: X`   -> binds `X`  to `[:P, :Q, :R]`
  #   * `alias P.Q.{R, S}`     -> binds `R`  to `[:P, :Q, :R]` and `S` to `[:P, :Q, :S]`
  #
  # The right-hand side is stored UNEXPANDED and expanded on lookup, so the environment is
  # order-independent by construction (a rename may legally be written above the alias it
  # renames) and a PREFIX rename resolves at any depth: `alias Samen.AI, as: A` binds `A` to
  # `[:Samen, :AI]`, so the reference `A.Agent` resolves to `[:Samen, :AI, :Agent]` — the
  # case that evaded attempts 1 and 2 in all five call shapes, and the case a further
  # `alias A.Agent, as: B` was built on.
  #
  # A name declared twice (shadowing) keeps BOTH right-hand sides and a reference counts as
  # the kernel if EITHER resolves there — a static security scan over-approximates on
  # purpose. For the same reason `resolves_to_kernel?/3` tests the raw, unexpanded parts as
  # well, which makes this check a strict SUPERSET of the pre-fix literal one: it can flag
  # strictly more than before, never less.
  defp alias_env(ast) do
    {_ast, bindings} =
      Macro.prewalk(ast, [], fn
        {:alias, _, args} = node, acc when is_list(args) -> {node, alias_bindings(args) ++ acc}
        {:require, _, args} = node, acc when is_list(args) -> {node, require_bindings(args) ++ acc}
        node, acc -> {node, acc}
      end)

    Enum.reduce(bindings, %{}, fn {name, parts}, acc ->
      Map.update(acc, name, [parts], &Enum.uniq([parts | &1]))
    end)
  end

  # `alias P.Q.{R, S}` — the brace form, one binding per child on the shared prefix. The
  # prefix itself may be a renamed alias (`alias A.{Agent}`); it is stored unexpanded and
  # resolved on lookup like any other right-hand side.
  defp alias_bindings([{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, children}])
       when is_list(prefix) and is_list(children) do
    for {:__aliases__, _, child} <- children,
        is_list(child),
        name = List.last(child),
        is_atom(name),
        do: {name, prefix ++ child}
  end

  # `alias P.Q.R, as: X`. Any other option list (`warn: false`) carries no rename, so it
  # falls back to the implicit-`as:` binding below.
  defp alias_bindings([{:__aliases__, _, parts} = target, opts])
       when is_list(parts) and is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [name]} when is_atom(name) -> [{name, parts}]
      _ -> alias_bindings([target])
    end
  end

  # `alias P.Q.R` — Elixir's implicit `as:` is the LAST segment.
  defp alias_bindings([{:__aliases__, _, parts}]) when is_list(parts) do
    case List.last(parts) do
      name when is_atom(name) -> [{name, parts}]
      _ -> []
    end
  end

  # `alias :"Elixir.P.Q.R", as: X` — an ATOM alias target. Legal Elixir (it is how you
  # alias an Erlang module, and `:"Elixir.Foo"` is the same atom `Foo` compiles to), and
  # `Code.string_to_quoted/2` yields the bare atom with NO `__aliases__` wrapper, so the
  # `__aliases__` clauses above never see it. UXD-05 attempt 4: this was a live evasion —
  # `alias :"Elixir.Samen.AI.Agent", as: A` then `A.start(...)` scored 0 violations at the
  # gate. Mirrors the atom clause of `agent_kernel_alias?/2`. A non-Elixir atom (`:lists`)
  # makes `Module.split/1` raise; that binds nothing, which is correct.
  defp alias_bindings([mod, opts]) when is_atom(mod) and is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [name]} when is_atom(name) -> [{name, atom_module_parts(mod)}]
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  defp alias_bindings(_), do: []

  # `require P.Q.R, as: X` — Elixir's OTHER alias-creating form, and the UXD-05 attempt-4
  # evasion V11 proved at the gate (`_orch/verify/T11-verdict-attempt3.json`, cases N1–N4):
  # `require Samen.AI.Agent, as: A` followed by `A.start(...)` returned 0 violations while
  # a byte-identical `alias`-written control returned 1. ONLY an explicit `as:` binds — a
  # bare `require P.Q.R` creates NO alias in Elixir, so it must contribute NO binding, or
  # this scan would start flagging ordinary `require`s. With the `as:` present the target
  # shape is identical to `alias`'s, so `alias_bindings/1` does the rest (including the
  # atom-target clause above), and a require-seeded name feeds head substitution like any
  # other binding — `require Samen.AI, as: A` then `alias A.Agent, as: B` resolves.
  defp require_bindings([_target, opts] = args) when is_list(opts) do
    if Keyword.has_key?(opts, :as), do: alias_bindings(args), else: []
  end

  defp require_bindings(_), do: []

  # An Elixir module atom (`:"Elixir.Samen.AI.Agent"`) as alias-environment parts.
  defp atom_module_parts(mod) when is_atom(mod) do
    mod |> Module.split() |> Enum.map(&String.to_atom/1)
  end

  # Does `parts` name the agent kernel under `env`? Head-segment substitution, short-circuit.
  #
  # TERMINATION, without a depth cap and without a fixed-point iteration: a substitution
  # only happens for a head that is NOT already in `visited`, and it adds that head to
  # `visited`. `visited` therefore grows strictly along every path and is bounded by
  # `map_size(env)`, so no path exceeds `map_size(env)` substitutions. That covers every
  # cyclic shape uniformly — a plain cycle (`alias A, as: B` / `alias B, as: A`), a cycle
  # that does bottom out at the kernel, and the SELF-GROWING form `alias A.B, as: A` whose
  # expansion never repeats a value and would defeat a value-based `seen` set.
  defp resolves_to_kernel?(parts, env, visited) when is_list(parts) do
    agent_module_parts?(parts) or resolve_head(parts, env, visited)
  end

  defp resolve_head([head | rest], env, visited) when is_atom(head) do
    case Map.get(env, head) do
      nil ->
        false

      candidates ->
        if MapSet.member?(visited, head) do
          false
        else
          seen = MapSet.put(visited, head)
          Enum.any?(candidates, &resolves_to_kernel?(&1 ++ rest, env, seen))
        end
    end
  end

  # A head no static analysis can resolve — `__MODULE__.Agent`, an `unquote(...)` fragment.
  # The reference is re-tested on its literal SUFFIX alone, i.e. exactly as conservatively
  # as a bare `Agent` written with no alias at all (which this gate already flags).
  # `rest` is strictly shorter than the input, so this recursion terminates too.
  defp resolve_head([_unresolvable | rest], env, visited), do: resolves_to_kernel?(rest, env, visited)

  defp resolve_head(_, _env, _visited), do: false

  # `import Samen.AI.Agent` binds `start/…` and `run/…` as UNQUALIFIED names — a
  # name-binding construct that is not an alias, so none of the qualified-call clauses
  # below can see the resulting `start(ctx, [])`. Fires only when the file actually imports
  # the kernel (resolved through the same alias environment, so `alias Samen.AI, as: A` +
  # `import A.Agent` is caught), and the scan runs over an AST whose `def`/`defp` HEADS have
  # been stripped so a module's own `def start(...)` definition is never mistaken for a call.
  defp imported_kernel_reentry?(ast, env) do
    imports_kernel?(ast, env) and ast_any?(strip_def_heads(ast), &bare_reentry_call?/1)
  end

  defp imports_kernel?(ast, env) do
    ast_any?(ast, fn
      {:import, _, [target | _]} -> agent_kernel_alias?(target, env)
      _ -> false
    end)
  end

  defp bare_reentry_call?({fun, _, args}) when fun in [:start, :run] and is_list(args), do: true
  defp bare_reentry_call?(_), do: false

  defp strip_def_heads(ast) do
    Macro.prewalk(ast, fn
      {def_kw, meta, [_head | rest]} when def_kw in [:def, :defp, :defmacro, :defmacrop] ->
        {def_kw, meta, [nil | rest]}

      node ->
        node
    end)
  end

  # Text fallback for the unparsable-source path. Kept in sync with the AST branch below:
  # a direct `Agent.start/run(...)` call, OR an `apply/3` indirection (bare `apply`,
  # `Kernel.apply`, `:erlang.apply`, or the pipe form `Agent |> apply(:start, ...)`) naming
  # the agent kernel and `:start`/`:run` literally.
  defp reentry_regex_fallback?(source) do
    Regex.match?(~r/(?:Samen\.AI\.)?Agent\.(?:start|run)\s*\(/, source) or
      Regex.match?(
        ~r/(?:Kernel\.|:erlang\.)?apply\s*\(\s*(?:Samen\.AI\.)?Agent\s*,\s*:(?:start|run)\b/,
        source
      ) or
      Regex.match?(
        ~r/(?:Samen\.AI\.)?Agent\s*\|>\s*apply\s*\(\s*:(?:start|run)\b/,
        source
      )
  end

  # `def tool_schema` / `def tool_schema()` (arity 0), incl. `@impl true def tool_schema, do:`.
  defp tool_schema_def?({def_kw, _, [{:tool_schema, _, args} | _]})
       when def_kw in [:def, :defp] and (is_nil(args) or args == []),
       do: true

  defp tool_schema_def?(_), do: false

  # A remote call to `<alias>.start(...)` / `<alias>.run(...)` where <alias> names the agent
  # kernel — fully-qualified `Samen.AI.Agent` OR an aliased `Agent` OR any reference that
  # resolves there under `env` (from `alias_env/1`). Matches any arity (the F-4
  # obligation is start/run "at all"), never a bare local `run(...)`.
  defp agent_reentry_call?({{:., _, [alias_ast, fun]}, _, args}, env)
       when fun in [:start, :run] and is_list(args),
       do: agent_kernel_alias?(alias_ast, env)

  # `apply(<alias>, :start | :run, <args>)` — the bare (auto-imported `Kernel.apply/3`)
  # indirection. Deliberately NOT constrained to a literal-list 3rd argument: a variable or
  # an expression there (`apply(Samen.AI.Agent, :start, build_args())`) is still a real
  # reentry attempt, only the *target* (module + fun name) needs to be statically visible.
  defp agent_reentry_call?({:apply, _, [alias_ast, fun, _args]}, env)
       when fun in [:start, :run],
       do: agent_kernel_alias?(alias_ast, env)

  # `Kernel.apply(<alias>, :start | :run, <args>)` — the fully-qualified spelling of the
  # same indirection.
  defp agent_reentry_call?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [alias_ast, fun, _args]},
         env
       )
       when fun in [:start, :run],
       do: agent_kernel_alias?(alias_ast, env)

  # `:erlang.apply(<alias>, :start | :run, <args>)` — the BEAM-primitive spelling.
  defp agent_reentry_call?({{:., _, [:erlang, :apply]}, _, [alias_ast, fun, _args]}, env)
       when fun in [:start, :run],
       do: agent_kernel_alias?(alias_ast, env)

  # `<alias> |> apply(:start | :run, <args>)` — the pipe-operator spelling of `apply/3`
  # (the piped-in term becomes apply's 1st argument, i.e. the module).
  defp agent_reentry_call?({:|>, _, [alias_ast, {:apply, _, [fun, _args]}]}, env)
       when fun in [:start, :run],
       do: agent_kernel_alias?(alias_ast, env)

  defp agent_reentry_call?(_, _env), do: false

  defp agent_kernel_alias?({:__aliases__, _, parts}, env) when is_list(parts) do
    # Fully-qualified `Samen.AI.Agent`, or an aliased `Agent` — but NOT a sub-module such
    # as `Agent.Run`/`Agent.Breaker` (those end in the sub-segment, not `:Agent`) — OR any
    # reference that RESOLVES there under this file's own alias environment, at any depth
    # and whichever segment was renamed (UXD-05, attempt 3; see `alias_env/1`).
    resolves_to_kernel?(parts, env, MapSet.new())
  end

  # A bare module-atom literal target, e.g. `apply(:"Elixir.Samen.AI.Agent", :start, [])` —
  # `Code.string_to_quoted/2` resolves that quoted-atom syntax straight to the atom, with no
  # `__aliases__` wrapper. Mirrors the same "fully-qualified Agent, or bare Agent" heuristic
  # as the `__aliases__` clause above. (No rename to check here: a bare atom literal is
  # never subject to `alias ..., as:` resolution.)
  defp agent_kernel_alias?(mod, _env) when is_atom(mod) and mod not in [nil, true, false] do
    parts = mod |> Module.split() |> Enum.map(&String.to_atom/1)
    agent_module_parts?(parts)
  rescue
    ArgumentError -> false
  end

  defp agent_kernel_alias?(_, _env), do: false

  # Shared "is this the agent kernel, fully-qualified or as bare `Agent`" predicate — used
  # both by `agent_kernel_alias?/2` above and by `resolves_to_kernel?/3` at every step of
  # head-segment substitution.
  defp agent_module_parts?(parts) when is_list(parts) do
    List.last(parts) == :Agent and (parts == [:Agent] or Enum.take(parts, -2) == [:AI, :Agent])
  end

  # --- (4) NON-VACUITY FLOOR -------------------------------------------------------------

  defp floor_violations(agent_files, tool_kinds) do
    agent =
      if agent_files == [] do
        ["NON-VACUITY: discovery found ZERO `use Samen.AI.Agent` modules under any app " <>
           "lib/ — a coverage gate that discovers nothing verifies nothing (ADR-047 §7.2 " <>
           "check 4 / ADR-046 E7)."]
      else
        []
      end

    tool =
      if tool_kinds == [] do
        ["NON-VACUITY: `Samen.Automation.Action.tool_kinds/0` is empty — no opted-in agent " <>
           "tool exists, so every tool assertion below is vacuous (ADR-047 §7.2 check 4)."]
      else
        []
      end

    agent ++ tool
  end

  # --- (2) every opted-in tool declares both callbacks and carries a test ----------------

  defp tool_callback_violations(tool_kinds, root) do
    test_blob = test_blob(root)

    for kind <- tool_kinds, violation <- tool_kind_violations(kind, test_blob), do: violation
  end

  defp tool_kind_violations(kind, test_blob) do
    mod = Samen.Automation.Action.module_for(kind)

    cond do
      is_nil(mod) ->
        ["opted-in tool #{inspect(kind)} resolves to no module in the registry."]

      not exports?(mod, :tool_schema, 0) ->
        ["opted-in tool #{inspect(kind)} (#{inspect(mod)}) does not export `tool_schema/0`."]

      not exports?(mod, :effect, 0) ->
        ["opted-in tool #{inspect(kind)} (#{inspect(mod)}) does not export `effect/0` — " <>
           "an action that forgets `effect/0` defaults to `:write` (approval-gated), but a " <>
           "SHIPPED tool must declare its class explicitly (ADR-047 §5.1)."]

      not String.contains?(test_blob, kind) ->
        ["opted-in tool #{inspect(kind)} carries NO test (no test file names the kind " <>
           "#{inspect(kind)}) — an untested tool is coverage the gate cannot claim " <>
           "(ADR-047 §7.2 check 2)."]

      true ->
        []
    end
  end

  # --- (3) the agent-run resource carries a retention :shred spec ------------------------

  defp retention_violations do
    specs = safe(fn -> Samen.Erasure.default_specs()[:retention_specs] || [] end, [])

    covered? =
      Enum.any?(specs, fn spec ->
        Map.get(spec, :resource) == @agent_run_resource and Map.get(spec, :action) == :shred
      end)

    if covered? do
      []
    else
      ["the agent-run resource #{inspect(@agent_run_resource)} has NO derived `:shred` " <>
         "retention spec (`Samen.Erasure.default_specs/1`) — a durable transcript is tenant " <>
         "data at rest whose erasure reach must be a coverage fact (ADR-047 §7.4 / §9#4)."]
    end
  end

  # --- (5) every discovered agent ships an AgentCase proof -------------------------------

  defp agent_test_violations(agent_files, root) do
    agentcase_test_files = agentcase_test_files(root)

    for {path, module} <- agent_files,
        not Enum.any?(agentcase_test_files, &String.contains?(&1, module)) do
      "the agent #{module} (#{rel(path, root)}) ships NO `Samen.AgentCase` proof — no test " <>
        "file both `use`s `Samen.AgentCase` and names #{module} (ADR-047 §7.2 check 1)."
    end
  end

  defp agentcase_test_files(root) do
    for path <- test_paths(root),
        File.regular?(path),
        source = File.read!(path),
        String.contains?(source, "use Samen.AgentCase"),
        do: source
  end

  # --- (6) the tree-wide leverage guard --------------------------------------------------

  defp leverage_violations(root) do
    for vertical <- @verticals,
        dir = Path.join([root, vertical, "lib"]),
        File.dir?(dir),
        path <- Path.wildcard(Path.join(dir, "**/*.ex")),
        File.regular?(path),
        source = File.read!(path),
        not defines_agent?(source),
        not router_module?(source),
        references_agent_kernel?(source) do
      "#{rel(path, root)}: a vertical `lib/` file references the `Samen.AI.Agent` kernel " <>
        "but is NEITHER an agent definition (`use Samen.AI.Agent`) NOR a router " <>
        "(`samen_ai_routes`) — re-implementing framework agent behaviour in the vertical is " <>
        "exactly what the leverage guard forbids (ADR-047 §2#7, the A6 verifier's R-A6-1)."
    end
  end

  # A genuine CODE reference (not a docstring/comment) to the agent kernel or one of its
  # submodules — via AST, so a moduledoc mention never false-flags. `Samen.AI.Agent`,
  # `Samen.AI.Agent.Run`, etc. all carry the `[:AI, :Agent]` subsequence in their alias.
  defp references_agent_kernel?(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} -> ast_any?(ast, &kernel_alias_ref?/1)
      {:error, _} -> false
    end
  end

  defp kernel_alias_ref?({:__aliases__, _, parts}) when is_list(parts),
    do: subsequence?(parts, [:AI, :Agent])

  defp kernel_alias_ref?(_), do: false

  defp subsequence?(parts, [a, b]) do
    parts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == [a, b]))
  end

  defp router_module?(source), do: String.contains?(source, "samen_ai_routes")

  # Does `source` genuinely `use Samen.AI.Agent` (AST — a use-call, never a docstring
  # mention)? Text fallback: a code line that STARTS with `use Samen.AI.Agent`.
  defp defines_agent?(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} -> ast_any?(ast, &agent_use_call?/1)
      {:error, _} -> Enum.any?(code_lines(source), &String.starts_with?(&1, "use Samen.AI.Agent"))
    end
  end

  # `use Samen.AI.Agent, ...` — a use-call whose FIRST arg names exactly Samen.AI.Agent
  # (the kernel, not a submodule).
  defp agent_use_call?({:use, _, [alias_ast | _]}), do: exact_agent_alias?(alias_ast)
  defp agent_use_call?(_), do: false

  defp exact_agent_alias?({:__aliases__, _, parts}) when is_list(parts),
    do: Enum.take(parts, -2) == [:AI, :Agent]

  defp exact_agent_alias?(_), do: false

  # --- discovery -------------------------------------------------------------------------

  # [{path, "Fully.Qualified.Module"}] for every `use Samen.AI.Agent` module under lib/.
  defp discover_agent_files(lib_paths) do
    for path <- lib_paths,
        File.regular?(path),
        source = File.read!(path),
        defines_agent?(source),
        module = module_name(source),
        not is_nil(module) do
      {path, module}
    end
  end

  defp module_name(source) do
    case Regex.run(~r/^\s*defmodule\s+([A-Z][\w.]*)\s+do/m, source) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp tool_kinds do
    safe(fn -> Samen.Automation.Action.tool_kinds() end, [])
  end

  # --- path helpers ----------------------------------------------------------------------

  defp lib_paths(root) do
    @app_lib_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join(dir, "**/*.ex")) end)
  end

  defp test_paths(root) do
    Path.wildcard(Path.join(root, "*/test/**/*.exs")) ++
      Path.wildcard(Path.join(root, "*/test/**/*.ex"))
  end

  # One concatenated blob of every test source in the tree — for the cheap "a test names
  # this kind" membership check.
  defp test_blob(root) do
    test_paths(root)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp repo_root(opts) do
    case opts[:root] do
      r when is_binary(r) ->
        Path.expand(r)

      _ ->
        cwd = File.cwd!()

        cond do
          File.dir?(Path.join(cwd, "samen_core/lib")) -> cwd
          File.dir?(Path.join([cwd, "..", "samen_core/lib"])) -> Path.expand("..", cwd)
          true -> cwd
        end
    end
  end

  defp rel(path, root), do: Path.relative_to(path, root)

  # --- AST / source helpers --------------------------------------------------------------

  defp ast_any?(ast, pred) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn node, acc ->
        {node, acc or pred.(node)}
      end)

    found
  end

  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
