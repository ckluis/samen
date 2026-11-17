defmodule Samen.AI.MaskedPayloadScan do
  @moduledoc """
  The RP-AI-1 single-mint AST scan (ADR-043 §3.2 layer 3): the source scanner `Samen.AI.ChokepointAntiBypassProbeTest`
  proves against the whole tree and `Samen.AI.VerbsTest` runs over the six verb modules. Lives in test support (not in
  a test module) so a suite that calls it does not depend on another test file having been loaded first — run alone,
  `verbs_test.exs` used to fail with `ChokepointAntiBypassProbeTest is not available`.
  """

  # --------------------------------------------------------------------------------------
  # Public scan entry point 

  @doc """
  Offenders in `content` (a source string) — the AST scan, with a text-scan fallback for
  content that does not parse as Elixir (`.eex` templates, or a parse error). Returns
  `[{label, line, kind}]` where `kind` is `:literal | :struct_call | :apply_struct |
  :struct_map | :text`.
  """
  def offenders_in_source(content, label \\ "snippet") do
    # emit_warnings: false — this is a read-only parse of foreign source for structural
    # analysis, not a compile; suppress the tokenizer's formatting diagnostics (e.g. heredoc
    # indentation notes) so the scan is silent regardless of which lib file it reads.
    case Code.string_to_quoted(content, emit_warnings: false) do
      {:ok, ast} -> ast_offenders(ast, label)
      {:error, _} -> text_offenders(content, label)
    end
  end

  # --------------------------------------------------------------------------------------
  # AST detection

  defp ast_offenders(ast, label) do
    {_ast, offenders} =
      Macro.prewalk(ast, [], fn node, acc ->
        case construction_kind(node) do
          nil -> {node, acc}
          kind -> {node, [{label, line_of(node), kind} | acc]}
        end
      end)

    Enum.reverse(offenders)
  end

  # Returns a tag atom if `node` constructs a %MaskedPayload{}, else nil.
  defp construction_kind(node) do
    cond do
      struct_literal_construction?(node) -> :literal
      dynamic_struct_call?(node) -> :struct_call
      apply_struct?(node) -> :apply_struct
      struct_map_forge?(node) -> :struct_map
      true -> nil
    end
  end

  # (a) `%MaskedPayload{kind: ...}` — a field-BEARING struct literal (construction). A
  # field-less `%MaskedPayload{}` match has an empty field list and is NOT flagged.
  defp struct_literal_construction?({:%, _, [alias_ast, {:%{}, _, fields}]}) do
    maskedpayload_alias?(alias_ast) and fields != []
  end

  defp struct_literal_construction?(_), do: false

  # (b) `struct(MaskedPayload, ...)` / `struct!(MaskedPayload, ...)` (local) and
  # `Kernel.struct(MaskedPayload, ...)` / `Kernel.struct!(...)` (remote).
  defp dynamic_struct_call?({fun, _, [first | _]}) when fun in [:struct, :struct!] do
    maskedpayload_alias?(first)
  end

  defp dynamic_struct_call?({{:., _, [kernel_ast, fun]}, _, [first | _]})
       when fun in [:struct, :struct!] do
    kernel_alias?(kernel_ast) and maskedpayload_alias?(first)
  end

  defp dynamic_struct_call?(_), do: false

  # (c) `apply(Kernel, :struct, [MaskedPayload | _])` / `apply(Kernel, :struct!, [...])`.
  defp apply_struct?({:apply, _, [kernel_ast, fun, [first | _]]})
       when fun in [:struct, :struct!] do
    kernel_alias?(kernel_ast) and maskedpayload_alias?(first)
  end

  defp apply_struct?(_), do: false

  # (d) `%{__struct__: MaskedPayload, ...}` — the bare-map struct forge.
  defp struct_map_forge?({:%{}, _, pairs}) when is_list(pairs) do
    Enum.any?(pairs, fn
      {:__struct__, alias_ast} -> maskedpayload_alias?(alias_ast)
      _ -> false
    end)
  end

  defp struct_map_forge?(_), do: false

  # An `{:__aliases__, _, parts}` node naming MaskedPayload — matches both the
  # fully-qualified `Samen.AI.MaskedPayload` and an aliased `MaskedPayload`. There is exactly
  # one MaskedPayload in the tree, so keying on the last segment is unambiguous.
  defp maskedpayload_alias?({:__aliases__, _, parts}) when is_list(parts) do
    List.last(parts) == :MaskedPayload
  end

  defp maskedpayload_alias?(_), do: false

  defp kernel_alias?({:__aliases__, _, [:Kernel]}), do: true
  defp kernel_alias?(_), do: false

  defp line_of({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line_of(_), do: 0

  # --------------------------------------------------------------------------------------
  # Text fallback (for `.eex` templates / non-parsing sources) — covers the literal AND the
  # struct/2 forms textually so a template bypass is not silently missed.

  @text_literal_re ~r/%(?:Samen\.AI\.)?MaskedPayload\{\s*[a-z_]/
  @text_struct_re ~r/struct!?\(\s*(?:Samen\.AI\.)?MaskedPayload\b/

  defp text_offenders(content, label) do
    for {line, idx} <- content |> String.split("\n") |> Enum.with_index(1),
        code_line?(line),
        Regex.match?(@text_literal_re, line) or Regex.match?(@text_struct_re, line) do
      {label, idx, :text}
    end
  end

  defp code_line?(line) do
    trimmed = String.trim_leading(line)
    not String.starts_with?(trimmed, "#") and not in_backticks?(line)
  end

  defp in_backticks?(line),
    do: Regex.match?(~r/`[^`]*(?:%(?:Samen\.AI\.)?MaskedPayload\{|struct!?\()/, line)
end
