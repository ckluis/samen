defmodule PiiReads do
  @moduledoc """
  `pii_reads` AST verifier — feasibility spike (plan S0.7, verifier C3).

  ## What it is

  A dataflow *match* (NOT a sound taint proof — doc §runs 4a, §775) over
  Elixir source. It flags a **direct** flow of a vault-declared PII value into
  a `Logger` / span / sink call that sits **outside** a `:reveal`-scoped
  action, while never flagging the `pii do` / `pii_attribute` **declaration
  sites** themselves.

  The layered design the plan cites (C3 + J2):

    * **Direct leak → AST.** This module. `Logger.info("ssn=\#{contact.pii_ssn}")`
      is a syntactic flow of a pii field into a sink argument — caught here.
    * **Laundered leak → sink schema allow-list.** If the pii value is passed
      through a helper first (`log_it(contact.pii_ssn)` where `log_it/1` calls
      `Logger`), a pure AST match at the sink no longer sees a pii field — it
      sees an opaque local. That is an **expected miss** here; the doc's
      backstop is the build-time wide-event/span *schema allow-list* at the
      sink (§4b, plan J2): every sink field must be typed as a bounded
      ID / token / enum / number, so a laundered name cannot land in a typed
      field. This spike does not implement J2; it documents the miss honestly.

  ## Detection model

  A "sink" is a call to a known leak surface:
    * `Logger.<level>(...)`  (debug/info/warn/warning/error/notice/emergency ...)
    * `IO.puts/1,2`, `IO.inspect/1,2`, `IO.write/1,2`
    * span attribute setters: `Tracer.set_attribute(s)`, `Span.set_attribute(s)`,
      `OpenTelemetry.Span.set_attribute(s)`, `:otel_span.set_attribute(s)`
    * generic event sinks: any call `<name>_sink(...)` or `emit_event(...)` /
      `emit(...)` / `record_event(...)`

  A value is "tainted" (a PII read) when the sink's arguments contain, directly:
    * a field read `expr.field` where `field` is a vault-declared pii attribute
    * a keyword/map fetch of a pii key: `Map.get(x, :pii_ssn)`, `x[:pii_ssn]`,
      `Keyword.get(kw, :per_full_name)`
    * a bare variable whose name is a pii attribute (e.g. a `per_full_name` var)
    * any of the above nested inside a string interpolation (`\#{...}`) or an
      arbitrary sub-expression of an argument (we prewalk each argument).

  Scope awareness: a leak found lexically inside a `:reveal`-scoped action is
  allowed (not flagged). We detect reveal scope by recognizing the enclosing
  form — `action :reveal do ... end`, `def reveal(...)`, `defp reveal_*`, or a
  `# samen:reveal` scope marker. Everything else is out-of-scope ⇒ flagged.

  ## Guarantee (fail-closed)

  `scan_sources/1` returns every finding it can see; `PiiReads.Harness`
  exits non-zero when any direct leak is found in the scanned corpus. A
  seeded direct leak MUST produce exit 1; a clean corpus MUST produce exit 0.
  """

  alias PiiReads.PiiRegistry

  @type finding :: %{
          kind: :direct_leak,
          file: String.t(),
          line: non_neg_integer(),
          sink: String.t(),
          pii: [atom()],
          scope: :out_of_reveal
        }

  @sink_module_calls %{
    {Logger,
     [
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
     ]} => "Logger",
    {IO, [:puts, :inspect, :write, :warn]} => "IO",
    {Tracer, [:set_attribute, :set_attributes, :add_event]} => "Tracer",
    {Span, [:set_attribute, :set_attributes, :add_event]} => "Span",
    {OpenTelemetry.Span, [:set_attribute, :set_attributes]} => "OpenTelemetry.Span"
  }

  # Bare-function sinks (no module prefix). Suffix `_sink` matches any name.
  @bare_sink_fns [:emit_event, :emit, :record_event, :publish_event, :ship_event]

  @doc """
  Scan a list of `{file_path, source_string}` pairs. Returns `{:ok, findings}`.
  Parse errors are surfaced as findings too (fail-closed: unparseable source is
  not silently skipped).
  """
  @spec scan_sources([{String.t(), String.t()}]) :: {:ok, [finding()]}
  def scan_sources(pairs) when is_list(pairs) do
    findings =
      pairs
      |> Enum.flat_map(fn {file, src} -> scan_source(file, src) end)

    {:ok, findings}
  end

  @doc "Scan every `.ex`/`.exs` file under `dir` (recursively)."
  @spec scan_dir(String.t()) :: {:ok, [finding()]}
  def scan_dir(dir) do
    dir
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.map(fn path -> {path, File.read!(path)} end)
    |> scan_sources()
  end

  @spec scan_source(String.t(), String.t()) :: [finding()]
  def scan_source(file, src) do
    case Code.string_to_quoted(src, columns: true, token_metadata: true) do
      {:ok, ast} ->
        walk(file, ast)

      {:error, {meta, msg, token}} ->
        [
          %{
            kind: :parse_error,
            file: file,
            line: Keyword.get(meta || [], :line, 0),
            message: "#{inspect(msg)} #{inspect(token)}"
          }
        ]
    end
  end

  # ---- the walk ----------------------------------------------------------

  # We prewalk the whole module AST carrying a `reveal?` flag in the accumulator.
  # When we descend into a reveal-scoped form we set the flag for that subtree;
  # sinks found while the flag is true are NOT reported.
  #
  # Because `Macro.prewalk/3` cannot easily "pop" scope on exit, we instead
  # handle scope by recursing manually on the scope-introducing forms and
  # letting prewalk handle the leaf sink detection within a fixed scope.
  defp walk(file, ast) do
    do_walk(file, ast, false, [])
    |> Enum.reverse()
  end

  # do_walk/4: (file, node, reveal?, acc) -> acc'
  defp do_walk(file, node, reveal?, acc)

  # `pii do ... end` — declaration block. Never a sink; skip entirely so the
  # pii_attribute declaration sites are structurally excluded (they name the
  # pii field, but they are declarations, not flows).
  defp do_walk(_file, {:pii, _meta, _args}, _reveal?, acc), do: acc

  # `action :reveal do ... end` — reveal-scoped Ash action. Descend with
  # reveal? = true so any sink inside is allowed.
  defp do_walk(file, {:action, _meta, [:reveal, kw]} = _node, _reveal?, acc)
       when is_list(kw) do
    body = Keyword.get(kw, :do)
    do_walk_children(file, body, true, acc)
  end

  defp do_walk(file, {:action, _meta, [:reveal | rest]}, _reveal?, acc) do
    do_walk_children(file, rest, true, acc)
  end

  # `def reveal(...)` / `defp reveal(...)` / `def reveal_*` — reveal-scoped fn.
  defp do_walk(file, {kw, _meta, [head | body]}, _reveal?, acc)
       when kw in [:def, :defp] do
    reveal_scoped = reveal_head?(head)
    do_walk_children(file, [head | body], reveal_scoped, acc)
  end

  # A scope marker call `samen_reveal_scope do ... end` (used by a couple of
  # corpus legit-reveal sites that are plain functions, to model an explicit
  # reveal chokepoint).
  defp do_walk(file, {:samen_reveal_scope, _meta, [kw]}, _reveal?, acc)
       when is_list(kw) do
    do_walk_children(file, Keyword.get(kw, :do), true, acc)
  end

  # A call node — check if it's a sink, then keep descending.
  defp do_walk(file, {_form, meta, args} = node, reveal?, acc)
       when is_list(args) or is_atom(args) do
    acc =
      case sink_call(node) do
        {:sink, sink_name} ->
          maybe_flag(file, meta, sink_name, args, reveal?, acc)

        :no ->
          acc
      end

    do_walk_children(file, args_of(node), reveal?, acc)
  end

  # 2-tuples, lists, and other containers: descend.
  defp do_walk(file, {a, b}, reveal?, acc) do
    acc = do_walk(file, a, reveal?, acc)
    do_walk(file, b, reveal?, acc)
  end

  defp do_walk(file, list, reveal?, acc) when is_list(list) do
    Enum.reduce(list, acc, fn el, a -> do_walk(file, el, reveal?, a) end)
  end

  defp do_walk(_file, _leaf, _reveal?, acc), do: acc

  defp do_walk_children(file, children, reveal?, acc) do
    do_walk(file, children, reveal?, acc)
  end

  defp args_of({_form, _meta, args}) when is_list(args), do: args
  defp args_of(_), do: []

  # ---- reveal head detection --------------------------------------------

  # `def reveal(x) when ...` — the head is a `when` wrapping the real head.
  # Must precede the generic atom-head clause below (`:when` is itself an atom).
  defp reveal_head?({:when, _meta, [inner | _]}), do: reveal_head?(inner)

  defp reveal_head?({name, _meta, _args}) when is_atom(name) do
    s = Atom.to_string(name)
    name == :reveal or String.starts_with?(s, "reveal")
  end

  defp reveal_head?(_), do: false

  # ---- sink classification ----------------------------------------------

  # Module-qualified sink: `Logger.info(...)`, `IO.puts(...)`, etc.
  defp sink_call({{:., _, [mod_ast, fun]}, _meta, _args}) when is_atom(fun) do
    with {:ok, mod} <- module_of(mod_ast),
         name when is_binary(name) <- lookup_module_sink(mod, fun) do
      {:sink, "#{name}.#{fun}"}
    else
      _ -> :no
    end
  end

  # Bare-function sink: `emit_event(...)`, `foo_sink(...)`.
  defp sink_call({fun, _meta, args})
       when is_atom(fun) and (is_list(args) or is_atom(args)) do
    s = Atom.to_string(fun)

    cond do
      fun in @bare_sink_fns -> {:sink, s}
      String.ends_with?(s, "_sink") -> {:sink, s}
      true -> :no
    end
  end

  defp sink_call(_), do: :no

  defp lookup_module_sink(mod, fun) do
    Enum.find_value(@sink_module_calls, fn {{m, funs}, label} ->
      if m == mod and fun in funs, do: label, else: nil
    end)
  end

  # Resolve a module AST (alias) to the actual module atom where possible.
  defp module_of({:__aliases__, _, parts}) do
    {:ok, Module.concat(parts)}
  end

  defp module_of(mod) when is_atom(mod), do: {:ok, mod}
  defp module_of(_), do: :error

  # ---- taint check on sink arguments ------------------------------------

  defp maybe_flag(file, meta, sink_name, args, reveal?, acc) do
    pii = tainted_pii_in(args)

    cond do
      pii == [] ->
        acc

      reveal? ->
        # Inside a :reveal-scoped action — allowed by design. Not a finding.
        acc

      true ->
        finding = %{
          kind: :direct_leak,
          file: file,
          line: Keyword.get(meta, :line, 0),
          sink: sink_name,
          pii: pii,
          scope: :out_of_reveal
        }

        [finding | acc]
    end
  end

  # Prewalk each argument expression collecting any pii-attribute reads.
  # This is what catches string interpolation, nested calls, tuples, etc:
  # a `\#{contact.pii_ssn}` desugars to a `Kernel.to_string(contact.pii_ssn)`
  # call whose arg we still see as a `.pii_ssn` field read.
  @spec tainted_pii_in(term()) :: [atom()]
  defp tainted_pii_in(args) do
    {_ast, found} =
      Macro.prewalk(args, [], fn node, found ->
        case pii_read(node) do
          {:pii, name} -> {node, [name | found]}
          :no -> {node, found}
        end
      end)

    found |> Enum.uniq() |> Enum.sort()
  end

  # Field read: `expr.per_full_name`
  defp pii_read({{:., _, [_base, field]}, _meta, []}) when is_atom(field) do
    if PiiRegistry.pii_attribute?(field), do: {:pii, field}, else: :no
  end

  # `Map.get(x, :pii_ssn)` / `Keyword.get(kw, :per_full_name)` / similar 2-arg
  # fetches whose 2nd arg is a pii key atom.
  defp pii_read({{:., _, [_mod, getter]}, _meta, [_container, key]})
       when getter in [:get, :fetch, :fetch!, :get!] and is_atom(key) do
    if PiiRegistry.pii_attribute?(key), do: {:pii, key}, else: :no
  end

  # Access syntax: `x[:pii_ssn]`
  defp pii_read({{:., _, [Access, :get]}, _meta, [_container, key]})
       when is_atom(key) do
    if PiiRegistry.pii_attribute?(key), do: {:pii, key}, else: :no
  end

  # Bare variable whose *name* is a pii attribute: `per_full_name` bound var.
  defp pii_read({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    if PiiRegistry.pii_attribute?(name), do: {:pii, name}, else: :no
  end

  defp pii_read(_), do: :no
end
