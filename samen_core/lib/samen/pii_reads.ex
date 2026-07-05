defmodule Samen.PiiReads do
  @moduledoc """
  `pii_reads` AST verifier — production C3 (plan §C, T1.8b; ported from the S0.7
  spike and hardened per Gate-0 fix task #6).

  ## What it is

  A dataflow *match* (NOT a sound taint proof — doc §runs 4a) over Elixir source.
  It flags a **direct** flow of a vault-declared PII value into a `Logger` / span /
  sink call that sits **outside** a declared `:reveal` action, while never flagging
  the `pii do` / `pii_attribute` **declaration** sites themselves.

  The layered design the plan cites (C3 + J2):

    * **Direct leak → AST (this module).** `Logger.info("ssn=\#{c.pii_pat_dob}")`
      is a syntactic flow of a pii field into a sink argument — caught here.
    * **Laundered leak → sink schema allow-list (J2, Phase 2).** If the pii value
      is passed through a helper first (`log_it(c.pii_pat_dob)`), a pure AST match
      at the sink sees an opaque local, not a pii field — an **expected miss**
      here, caught by the build-time wide-event/span schema allow-list (plan J2,
      T2.7). When a helper-hop of a pii read is cheaply detectable this module
      emits a `:laundered_hint` diagnostic citing J2 (NOT a failing finding — it
      never changes the exit code; it is documentation so the honest boundary is
      visible in output).

  ## What changed from the S0.7 spike (Gate-0 fix task #6)

    a. **Reveal-scope keys on the REAL Ash `:reveal` action**, not a lexical
       `reveal`-name prefix. Suppression happens ONLY inside
       `action :name do … end` where `:name` is a **declared** reveal action
       (`reveal :name` in the resource's `pii do` block, resolved via
       `Samen.PiiReads.Registry` ← `Samen.Pii.Info.reveal_actions/1`). A
       `def reveal_report/1` — or an `action :reveal_report` that was never
       declared — is NOT a reveal boundary; its sinks are flagged. This closes the
       spike's `reveal_*` false-negative evasion (now a red-path corpus case).

    b. **Aliased sink modules are resolved from module context.** `alias Logger,
       as: L` in a module makes `L.info(...)` resolve to `Logger.info(...)` and be
       treated as a sink. Same for `alias OpenTelemetry.Span, as: Span` etc.

    c. **The PII registry is real** — `Samen.PiiReads.Registry` introspects
       `Samen.Pii.Info` over every configured resource's `pii do` block (logical
       AND storage names), never a hand-written seed set.

    d. **Laundered flows remain documented expected-misses** (J2 is Phase 2). A
       cheaply-detectable helper hop emits a `:laundered_hint` citing J2.

  ## Fail-closed

  `scan_sources/2` returns every finding it can see; the harness exits non-zero
  when any `:direct_leak` or `:parse_error` finding is present. A seeded direct
  leak MUST produce exit 1; a clean corpus MUST produce exit 0. Unparseable
  source is a `:parse_error` finding (never silently skipped). `:laundered_hint`
  findings NEVER affect the exit code.
  """

  alias Samen.PiiReads.Registry

  @type finding ::
          %{
            kind: :direct_leak,
            file: String.t(),
            line: non_neg_integer(),
            module: module() | nil,
            sink: String.t(),
            pii: [atom()],
            scope: :out_of_reveal
          }
          | %{kind: :parse_error, file: String.t(), line: non_neg_integer(), message: String.t()}
          | %{
              kind: :laundered_hint,
              file: String.t(),
              line: non_neg_integer(),
              module: module() | nil,
              pii: [atom()],
              helper: atom(),
              note: String.t()
            }

  # Module-qualified sinks, keyed by the fully-resolved module atom. The walker
  # resolves an alias (`alias Logger, as: L`) back to the real module before this
  # lookup, so `L.info` and `Logger.info` are the same sink.
  @sink_module_calls %{
    Logger => [
      :debug,
      :info,
      :warn,
      :warning,
      :error,
      :notice,
      :critical,
      :alert,
      :emergency,
      :log,
      :metadata
    ],
    IO => [:puts, :inspect, :write, :warn],
    IO.ANSI => [],
    OpenTelemetry.Tracer => [:set_attribute, :set_attributes, :add_event],
    OpenTelemetry.Span => [:set_attribute, :set_attributes, :add_event]
  }

  # Short aliases that are conventionally the OTel span/tracer modules even
  # without an explicit `alias` in the file (the corpus uses bare `Tracer` /
  # `Span`). Treated as sinks by their leaf name when not otherwise aliased.
  @otel_leaf_sinks %{
    Tracer => [:set_attribute, :set_attributes, :add_event],
    Span => [:set_attribute, :set_attributes, :add_event]
  }

  # Bare-function sinks (no module prefix). Suffix `_sink` matches any name.
  @bare_sink_fns [:emit_event, :emit, :record_event, :publish_event, :ship_event]

  @doc """
  Scan a list of `{file_path, source_string}` pairs. Returns `{:ok, findings}`.

  `registry` is a `Samen.PiiReads.Registry` (defaults to one built from the
  configured `:ash_domains`). Tests inject a fixed registry.
  """
  @spec scan_sources([{String.t(), String.t()}], Registry.t()) :: {:ok, [finding()]}
  def scan_sources(pairs, registry \\ Registry.build()) when is_list(pairs) do
    findings = Enum.flat_map(pairs, fn {file, src} -> scan_source(file, src, registry) end)
    {:ok, findings}
  end

  @doc "Scan every `.ex`/`.exs` file under `dir` (recursively)."
  @spec scan_dir(String.t(), Registry.t()) :: {:ok, [finding()]}
  def scan_dir(dir, registry \\ Registry.build()) do
    dir
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.map(fn path -> {path, File.read!(path)} end)
    |> scan_sources(registry)
  end

  @spec scan_source(String.t(), String.t(), Registry.t()) :: [finding()]
  def scan_source(file, src, registry \\ Registry.build()) do
    case Code.string_to_quoted(src, columns: true, token_metadata: true) do
      {:ok, ast} ->
        walk(file, ast, registry)

      {:error, {meta, msg, token}} ->
        [
          %{
            kind: :parse_error,
            file: file,
            line: line_of(meta),
            message: "#{inspect(msg)} #{inspect(token)}"
          }
        ]
    end
  end

  # ---- the walk ----------------------------------------------------------
  #
  # State carried through the walk:
  #   * file      — for diagnostics
  #   * registry  — the real PII + reveal-action registry
  #   * module    — the module currently being defined (from `defmodule`), or nil
  #   * aliases   — %{alias_atom => real_module}, from `alias` statements in scope
  #   * reveal?   — true inside a declared reveal action's body
  #   * helpers   — the set of local helper fn names defined in the current module
  #                 (for cheap laundered-hint detection)

  defp walk(file, ast, registry) do
    ctx = %{
      file: file,
      registry: registry,
      module: nil,
      aliases: %{},
      reveal?: false
    }

    # helpers = nil at the top level (only meaningful inside a module body).
    {_ctx, acc} = do_walk(ast, ctx, [], nil)
    Enum.reverse(acc)
  end

  # `defmodule Name do … end` — set the enclosing module, collect its aliases
  # and local helper names first (a single pre-pass), then walk the body with
  # that context. A nested/sibling defmodule shadows for its own subtree. Handled
  # in the 4-arity chain so it fires uniformly whether the file has one module or
  # many (a multi-module file's top level is a `__block__` of defmodules — each
  # must reset module/aliases/helpers, not inherit the previous sibling's).
  defp do_walk({:defmodule, _meta, [name_ast, [do: body]]}, ctx, acc, _helpers) do
    module = module_from_alias(name_ast, ctx)
    aliases = collect_aliases(body, ctx.aliases)
    helpers = collect_local_fns(body)

    inner_ctx = %{ctx | module: module, aliases: aliases, reveal?: false}
    {_inner, acc} = do_walk(body, inner_ctx, acc, helpers)
    {ctx, acc}
  end

  # `pii do … end` — declaration block. Never a sink; skip entirely so the
  # pii_attribute declaration sites are structurally excluded.
  defp do_walk({:pii, _meta, _args}, ctx, acc, _helpers), do: {ctx, acc}

  # `alias …` — already collected in the module pre-pass; do not descend.
  defp do_walk({:alias, _meta, _args}, ctx, acc, _helpers), do: {ctx, acc}

  # `action :name do … end` — Ash action. Suppress sinks in the body ONLY if
  # `:name` is a DECLARED reveal action for the enclosing resource module. This
  # is the Gate-0 fix: no lexical name matching. `action :reveal_report do …`
  # where `:reveal_report` was never `reveal :reveal_report` is NOT suppressed.
  defp do_walk({:action, _meta, [name | rest]} = _node, ctx, acc, helpers)
       when is_atom(name) do
    reveal? = Registry.reveal_action?(ctx.registry, ctx.module, name)
    {_c, acc} = do_walk(rest, %{ctx | reveal?: reveal?}, acc, helpers)
    {ctx, acc}
  end

  # A call node — check if it's a sink, then keep descending.
  defp do_walk({_form, meta, args} = node, ctx, acc, helpers)
       when is_list(args) or is_atom(args) do
    acc =
      case sink_call(node, ctx) do
        {:sink, sink_name} -> maybe_flag(node, meta, sink_name, args, ctx, acc, helpers)
        :no -> maybe_hint(node, meta, args, ctx, acc, helpers)
      end

    {_c, acc} = do_walk(args_of(node), ctx, acc, helpers)
    {ctx, acc}
  end

  # 2-tuples, lists, and other containers: descend.
  defp do_walk({a, b}, ctx, acc, helpers) do
    {_c, acc} = do_walk(a, ctx, acc, helpers)
    do_walk(b, ctx, acc, helpers)
  end

  defp do_walk(list, ctx, acc, helpers) when is_list(list) do
    acc = Enum.reduce(list, acc, fn el, a -> elem(do_walk(el, ctx, a, helpers), 1) end)
    {ctx, acc}
  end

  defp do_walk(_leaf, ctx, acc, _helpers), do: {ctx, acc}

  defp args_of({_form, _meta, args}) when is_list(args), do: args
  defp args_of(_), do: []

  # ---- alias resolution -------------------------------------------------

  # Collect `alias Foo.Bar` and `alias Foo.Bar, as: B` from a module body into a
  # map of alias_atom => real_module. `alias Foo.{A, B}` is expanded.
  defp collect_aliases(body, initial) do
    body
    |> block_children()
    |> Enum.reduce(initial, fn node, acc ->
      case node do
        {:alias, _meta, args} -> merge_alias(args, acc)
        _ -> acc
      end
    end)
  end

  # `alias Logger, as: L`
  defp merge_alias([{:__aliases__, _, parts}, opts], acc) when is_list(opts) do
    real = Module.concat(parts)

    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as_atom]} -> Map.put(acc, as_atom, real)
      _ -> Map.put(acc, List.last(parts), real)
    end
  end

  # `alias Foo.Bar` (default: last segment is the alias atom)
  defp merge_alias([{:__aliases__, _, parts}], acc) do
    Map.put(acc, List.last(parts), Module.concat(parts))
  end

  # `alias Foo.{Bar, Baz}` — multi-alias
  defp merge_alias([{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}], acc) do
    Enum.reduce(children, acc, fn {:__aliases__, _, parts}, a ->
      full = base ++ parts
      Map.put(a, List.last(parts), Module.concat(full))
    end)
  end

  defp merge_alias(_other, acc), do: acc

  # ---- module name from defmodule / __aliases__ -------------------------

  defp module_from_alias({:__aliases__, _, parts}, _ctx) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp module_from_alias(atom, _ctx) when is_atom(atom), do: atom
  defp module_from_alias(_, _ctx), do: nil

  # ---- local helper fn collection (for laundered hints) -----------------

  defp collect_local_fns(body) do
    body
    |> block_children()
    |> Enum.flat_map(fn
      {kw, _meta, [head | _]} when kw in [:def, :defp] -> List.wrap(fn_name(head))
      _ -> []
    end)
    |> MapSet.new()
  end

  defp fn_name({:when, _, [inner | _]}), do: fn_name(inner)
  defp fn_name({name, _, _}) when is_atom(name), do: name
  defp fn_name(_), do: nil

  defp block_children({:__block__, _, children}), do: children
  defp block_children(other) when is_list(other), do: other
  defp block_children(other), do: [other]

  # ---- sink classification ----------------------------------------------

  # Module-qualified sink: `Logger.info(...)`, `L.info(...)` (aliased), etc.
  defp sink_call({{:., _, [mod_ast, fun]}, _meta, _args}, ctx) when is_atom(fun) do
    with {:ok, mod} <- module_of(mod_ast, ctx),
         label when is_binary(label) <- lookup_module_sink(mod, fun) do
      {:sink, "#{label}.#{fun}"}
    else
      _ -> :no
    end
  end

  # Bare-function sink: `emit_event(...)`, `foo_sink(...)`.
  defp sink_call({fun, _meta, args}, _ctx)
       when is_atom(fun) and (is_list(args) or is_atom(args)) do
    s = Atom.to_string(fun)

    cond do
      fun in @bare_sink_fns -> {:sink, s}
      String.ends_with?(s, "_sink") -> {:sink, s}
      true -> :no
    end
  end

  defp sink_call(_, _ctx), do: :no

  defp lookup_module_sink(mod, fun) do
    case Map.get(@sink_module_calls, mod) do
      funs when is_list(funs) ->
        if fun in funs, do: inspect(mod), else: nil

      nil ->
        # Fall back to the OTel leaf-name sinks (bare `Tracer`/`Span`).
        case Map.get(@otel_leaf_sinks, mod) do
          funs when is_list(funs) -> if fun in funs, do: inspect(mod), else: nil
          nil -> nil
        end
    end
  end

  # Resolve a module AST to a real module atom, honoring the current aliases.
  #   * `{:__aliases__, _, [L]}` with `alias Logger, as: L` in scope -> Logger
  #   * `{:__aliases__, _, [Logger]}` -> Logger
  #   * `{:__aliases__, _, [OpenTelemetry, Span]}` -> OpenTelemetry.Span
  #   * a bare atom module -> itself
  defp module_of({:__aliases__, _, [single]}, ctx) when is_atom(single) do
    case Map.get(ctx.aliases, single) do
      nil -> {:ok, Module.concat([single])}
      real -> {:ok, real}
    end
  end

  defp module_of({:__aliases__, _, parts}, ctx) when is_list(parts) do
    # Multi-segment: an alias may still rebind the FIRST segment
    # (`alias OpenTelemetry, as: O` then `O.Span`). Resolve the head if aliased.
    case parts do
      [head | rest] when rest != [] ->
        case Map.get(ctx.aliases, head) do
          nil -> {:ok, Module.concat(parts)}
          real -> {:ok, Module.concat([real | rest])}
        end

      _ ->
        {:ok, Module.concat(parts)}
    end
  end

  defp module_of(mod, _ctx) when is_atom(mod), do: {:ok, mod}
  defp module_of(_, _ctx), do: :error

  # ---- taint check on sink arguments ------------------------------------

  defp maybe_flag(_node, meta, sink_name, args, ctx, acc, _helpers) do
    pii = tainted_pii_in(args, ctx.registry)

    cond do
      pii == [] ->
        acc

      ctx.reveal? ->
        # Inside a DECLARED :reveal action — allowed by design. Not a finding.
        acc

      true ->
        finding = %{
          kind: :direct_leak,
          file: ctx.file,
          line: line_of(meta),
          module: ctx.module,
          sink: sink_name,
          pii: pii,
          scope: :out_of_reveal
        }

        [finding | acc]
    end
  end

  # Cheap laundered-hint: a call to a KNOWN local helper (`helpers` set) whose
  # arguments contain a direct pii read. This is NOT a leak here (the helper may
  # not sink it, and even if it does the AST layer cannot prove it) — it is an
  # advisory citing J2 so the honest boundary is visible in output. Never
  # affects the exit code.
  defp maybe_hint(_node, _meta, _args, _ctx, acc, nil), do: acc

  defp maybe_hint({fun, meta, args}, _meta2, _args2, ctx, acc, helpers)
       when is_atom(fun) and is_list(args) do
    with true <- MapSet.member?(helpers, fun),
         [_ | _] = pii <- tainted_pii_in(args, ctx.registry) do
      hint = %{
        kind: :laundered_hint,
        file: ctx.file,
        line: line_of(meta),
        module: ctx.module,
        pii: pii,
        helper: fun,
        note:
          "pii read passed to local helper #{fun}/#{length(args)} — a laundered flow " <>
            "the AST layer cannot prove; caught by the J2 sink-schema allow-list (Phase 2, T2.7)."
      }

      [hint | acc]
    else
      _ -> acc
    end
  end

  defp maybe_hint(_node, _meta, _args, _ctx, acc, _helpers), do: acc

  # Prewalk each argument expression collecting any pii-attribute reads.
  @spec tainted_pii_in(term(), Registry.t()) :: [atom()]
  defp tainted_pii_in(args, registry) do
    {_ast, found} =
      Macro.prewalk(args, [], fn node, found ->
        case pii_read(node, registry) do
          {:pii, name} -> {node, [name | found]}
          :no -> {node, found}
        end
      end)

    found |> Enum.uniq() |> Enum.sort()
  end

  # Field read: `expr.per_full_name`
  defp pii_read({{:., _, [_base, field]}, _meta, []}, registry) when is_atom(field) do
    if Registry.pii_attribute?(registry, field), do: {:pii, field}, else: :no
  end

  # `Map.get(x, :pii_ssn)` / `Keyword.get(kw, :full_name)` — 2-arg fetch whose
  # 2nd arg is a pii key atom.
  defp pii_read({{:., _, [_mod, getter]}, _meta, [_container, key]}, registry)
       when getter in [:get, :fetch, :fetch!, :get!] and is_atom(key) do
    if Registry.pii_attribute?(registry, key), do: {:pii, key}, else: :no
  end

  # Access syntax: `x[:pii_ssn]`
  defp pii_read({{:., _, [Access, :get]}, _meta, [_container, key]}, registry)
       when is_atom(key) do
    if Registry.pii_attribute?(registry, key), do: {:pii, key}, else: :no
  end

  # Bare variable whose *name* is a pii attribute: `full_name` bound var.
  defp pii_read({name, _meta, ctx}, registry) when is_atom(name) and is_atom(ctx) do
    if Registry.pii_attribute?(registry, name), do: {:pii, name}, else: :no
  end

  defp pii_read(_, _registry), do: :no

  defp line_of(meta), do: Keyword.get(meta || [], :line, 0)
end
