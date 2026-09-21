#!/usr/bin/env elixir
# scripts/mutation/mutate.exs — the deterministic mutant ENGINE behind the
# mutation gate (ADR-049). Pure source-to-source; no mix project, no DB.
#
# WHY AN AST WALK AND NOT A REGEX. A regex mutation engine mutates the `==`
# inside a string literal, a comment, or a @moduledoc — producing mutants that
# are either no-ops (noise that has to be exempted) or unparseable (noise that
# has to be discarded). Every site here comes from `Code.string_to_quoted/2`
# with `columns: true`, so a site is by construction a real operator or a real
# boolean literal in real code. The MUTATION itself is then a byte-splice at
# that exact line/column — the rest of the file is untouched, which is what
# makes the harness's SHA-256 byte-exact restore contract (mutate.sh step 5)
# cheap and total.
#
# OPERATOR FAMILIES (deliberately four; all single-token, all parse-preserving):
#   EQ     ==  -> !=   !=  -> ==   === -> !==  !== -> ===
#   REL    >   -> >=   >=  -> >    <   -> <=   <=  -> <
#   BOOLOP and -> or   or  -> and  &&  -> ||   ||  -> &&
#   BOOLLIT true -> false        false -> true
# These are the four families that flip the mechanisms this repo claims: a
# fail-closed default (BOOLLIT), an off-by-one threshold (REL), a weakened
# condition (BOOLOP), and an identity/equality check (EQ). Families whose
# replacement changes arity or precedence class (`not`/`!` removal, `in` ->
# `not in`) are deliberately EXCLUDED: they generate mutants whose behaviour
# change is real but not attributable to the line a reader is looking at, and
# an unattributable mutant is the same vacuity the sabotage corpus exists to
# refuse.
#
# SKIPPED SITES. Boolean literals under the documentation/behaviour attributes
# (@moduledoc/@doc/@typedoc/@impl/@deprecated/@derive) are not mutated: flipping
# `@moduledoc false` is a guaranteed-equivalent mutant, i.e. permanent noise in
# the ledger. Every other site in the file is fair game.
#
# SUBCOMMANDS
#   list <relpath>...         TSV of every VALID mutant site (see below).
#   apply <relpath> <line> <col> <from> <to>
#                             splice the mutant into the file IN PLACE. Refuses
#                             (exit 3) unless the source at line/col is exactly
#                             <from> — so a stale site can never corrupt a file.
#   count <relpath>...        one `<relpath>\t<n>` line per file.
#
# `list` TSV columns (tab-separated, stable order, no header):
#   relpath  line  col  family  from  to  line_sha12
# `line_sha12` is the first 12 hex of SHA-256 over the UNMUTATED source line
# (no trailing newline). The ledger pins exemptions on it, NOT on the line
# number, so inserting lines above a justified survivor keeps the exemption
# valid while EDITING that line expires it.
#
# VALIDITY. A site is emitted only if (a) the source text at line/col really is
# the `from` token, and (b) the mutated file still PARSES. (b) matters: a mutant
# that cannot parse makes `mix test` fail for compile reasons, which the harness
# would otherwise score as a kill — a false green. Non-parsing candidates are
# dropped here, at enumeration time, where they cost nothing.
#
# Exit: 0 ok · 2 usage · 3 apply refused (token mismatch / bad site).

defmodule Samen.Mutation.Engine do
  @eq %{"==" => "!=", "!=" => "==", "===" => "!==", "!==" => "==="}
  @rel %{">" => ">=", ">=" => ">", "<" => "<=", "<=" => "<"}
  @boolop %{"and" => "or", "or" => "and", "&&" => "||", "||" => "&&"}
  @boollit %{"true" => "false", "false" => "true"}

  @families [{"EQ", @eq}, {"REL", @rel}, {"BOOLOP", @boolop}, {"BOOLLIT", @boollit}]

  # Boolean literals under these module attributes are compile-time
  # documentation/plumbing: flipping them is an equivalent mutant by
  # construction, so they never become sites.
  @doc_attrs [:moduledoc, :doc, :typedoc, :impl, :deprecated, :derive]

  def family_of(token) do
    Enum.find_value(@families, fn {name, map} ->
      if Map.has_key?(map, token), do: {name, Map.fetch!(map, token)}
    end)
  end

  # ── site enumeration ───────────────────────────────────────────────────────

  def sites(source) do
    encoder = fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end

    case Code.string_to_quoted(source,
           columns: true,
           token_metadata: true,
           literal_encoder: encoder,
           emit_warnings: false
         ) do
      {:ok, ast} ->
        ast
        |> walk([])
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} = err ->
        throw({:unparseable, err})
    end
  end

  # A hand-rolled recursive walk (not Macro.prewalk) because the doc-attribute
  # skip has to PRUNE a subtree, which prewalk cannot express.
  defp walk({:@, _, [{attr, _, _}]} = _node, acc) when attr in @doc_attrs, do: acc

  defp walk({op, meta, args} = node, acc) when is_atom(op) and is_list(args) do
    acc = collect_operator(node, meta, args, acc)
    acc = collect_bool_literal(node, acc)
    walk_children(args, acc)
  end

  defp walk({left, right}, acc), do: walk_children([left, right], acc)
  defp walk(list, acc) when is_list(list), do: walk_children(list, acc)
  defp walk({_, _, args}, acc) when is_list(args), do: walk_children(args, acc)
  defp walk(_leaf, acc), do: acc

  defp walk_children(children, acc) when is_list(children),
    do: Enum.reduce(children, acc, &walk/2)

  defp walk_children(_other, acc), do: acc

  # Binary operator site: the operator's own meta carries the line/column OF
  # THE OPERATOR TOKEN when `columns: true` is set.
  defp collect_operator({op, meta, [_, _]}, _meta, _args, acc) do
    token = Atom.to_string(op)

    with {family, to} <- family_of(token),
         true <- family != "BOOLLIT",
         line when is_integer(line) <- Keyword.get(meta, :line),
         col when is_integer(col) <- Keyword.get(meta, :column) do
      [{line, col, family, token, to} | acc]
    else
      _ -> acc
    end
  end

  defp collect_operator(_node, _meta, _args, acc), do: acc

  # Boolean literal site: `literal_encoder` wraps every literal in a
  # `{:__block__, meta, [literal]}` so a bare `true`/`false` gets line/column
  # metadata it otherwise would not have.
  defp collect_bool_literal({:__block__, meta, [lit]}, acc) when is_boolean(lit) do
    token = to_string(lit)

    with {_family, to} <- family_of(token),
         line when is_integer(line) <- Keyword.get(meta, :line),
         col when is_integer(col) <- Keyword.get(meta, :column) do
      [{line, col, "BOOLLIT", token, to} | acc]
    else
      _ -> acc
    end
  end

  defp collect_bool_literal(_node, acc), do: acc

  # ── splicing ───────────────────────────────────────────────────────────────

  # Elixir's tokenizer counts columns in CODEPOINTS, 1-based. Splice the same
  # way (never bytes) so a module with a non-ASCII byte anywhere earlier on the
  # line — a `••••` mask literal, a — in a comment — still mutates at the right
  # place instead of shredding the file.
  def splice(source, line_no, col, from, to) do
    lines = String.split(source, "\n")
    idx = line_no - 1

    case Enum.at(lines, idx) do
      nil ->
        {:error, {:no_such_line, line_no}}

      line ->
        cps = String.to_charlist(line)
        prefix = cps |> Enum.take(col - 1) |> List.to_string()
        rest = cps |> Enum.drop(col - 1) |> List.to_string()

        if String.starts_with?(rest, from) do
          mutated =
            prefix <> to <> String.slice(rest, String.length(from)..-1//1)

          {:ok, lines |> List.replace_at(idx, mutated) |> Enum.join("\n")}
        else
          {:error, {:token_mismatch, line_no, col, from, String.slice(rest, 0, 24)}}
        end
    end
  end

  def parses?(source) do
    match?({:ok, _}, Code.string_to_quoted(source, emit_warnings: false))
  end

  def line_sha12(source, line_no) do
    line = source |> String.split("\n") |> Enum.at(line_no - 1) || ""

    :crypto.hash(:sha256, line)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end

defmodule Samen.Mutation.CLI do
  alias Samen.Mutation.Engine

  def main(["list" | files]) when files != [], do: list(files)
  def main(["count" | files]) when files != [], do: count(files)

  def main(["apply", file, line, col, from, to]) do
    source = File.read!(file)

    case Engine.splice(source, String.to_integer(line), String.to_integer(col), from, to) do
      {:ok, mutated} ->
        unless Engine.parses?(mutated) do
          die(3, "apply refused: the mutant does not parse (#{file} #{line}:#{col} #{from}->#{to})")
        end

        File.write!(file, mutated)
        IO.puts("applied #{file} #{line}:#{col} #{from} -> #{to}")

      {:error, reason} ->
        die(3, "apply refused: #{inspect(reason)} in #{file}")
    end
  end

  def main(_), do: die(2, usage())

  defp list(files) do
    Enum.each(files, fn file ->
      source = read(file)

      for {line, col, family, from, to} <- valid_sites(file, source) do
        IO.puts(
          Enum.join(
            [file, line, col, family, from, to, Engine.line_sha12(source, line)],
            "\t"
          )
        )
      end
    end)
  end

  defp count(files) do
    Enum.each(files, fn file ->
      source = read(file)
      IO.puts("#{file}\t#{length(valid_sites(file, source))}")
    end)
  end

  # A candidate becomes a SITE only if it splices cleanly AND the result parses.
  defp valid_sites(file, source) do
    sites =
      try do
        Engine.sites(source)
      catch
        {:unparseable, err} ->
          die(2, "#{file} does not parse: #{inspect(err)}")
      end

    Enum.filter(sites, fn {line, col, _family, from, to} ->
      case Engine.splice(source, line, col, from, to) do
        {:ok, mutated} -> Engine.parses?(mutated)
        {:error, _} -> false
      end
    end)
  end

  defp read(file) do
    case File.read(file) do
      {:ok, source} -> source
      {:error, reason} -> die(2, "cannot read #{file}: #{:file.format_error(reason)}")
    end
  end

  defp usage do
    """
    Usage:
      mutate.exs list  <file>...
      mutate.exs count <file>...
      mutate.exs apply <file> <line> <col> <from> <to>
    """
  end

  defp die(code, msg) do
    IO.puts(:stderr, msg)
    System.halt(code)
  end
end

Samen.Mutation.CLI.main(System.argv())
