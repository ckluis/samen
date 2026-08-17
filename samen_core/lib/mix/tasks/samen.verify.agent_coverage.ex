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
      {:ok, ast} -> ast_any?(ast, &agent_reentry_call?/1)
      {:error, _} -> Regex.match?(~r/(?:Samen\.AI\.)?Agent\.(?:start|run)\s*\(/, source)
    end
  end

  # `def tool_schema` / `def tool_schema()` (arity 0), incl. `@impl true def tool_schema, do:`.
  defp tool_schema_def?({def_kw, _, [{:tool_schema, _, args} | _]})
       when def_kw in [:def, :defp] and (is_nil(args) or args == []),
       do: true

  defp tool_schema_def?(_), do: false

  # A remote call to `<alias>.start(...)` / `<alias>.run(...)` where <alias> names the agent
  # kernel — fully-qualified `Samen.AI.Agent` OR an aliased `Agent`. Matches any arity (the
  # F-4 obligation is start/run "at all"), never a bare local `run(...)`.
  defp agent_reentry_call?({{:., _, [alias_ast, fun]}, _, args})
       when fun in [:start, :run] and is_list(args),
       do: agent_kernel_alias?(alias_ast)

  defp agent_reentry_call?(_), do: false

  defp agent_kernel_alias?({:__aliases__, _, parts}) when is_list(parts) do
    # Fully-qualified `Samen.AI.Agent`, or an aliased `Agent` — but NOT a sub-module such
    # as `Agent.Run`/`Agent.Breaker` (those end in the sub-segment, not `:Agent`).
    List.last(parts) == :Agent and (parts == [:Agent] or Enum.take(parts, -2) == [:AI, :Agent])
  end

  defp agent_kernel_alias?(_), do: false

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
