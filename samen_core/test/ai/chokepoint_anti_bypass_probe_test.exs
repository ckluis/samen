defmodule Samen.AI.ChokepointAntiBypassProbeTest do
  @moduledoc """
  RP-AI-1 (ADR-043 §3.2 layer 3 / §13) — the single-mint anti-bypass probe, implemented as
  the **AST/grep scan** ADR-043 §3.2 names. `%Samen.AI.MaskedPayload{}` is the ONLY value a
  `Samen.AI.Provider` callback accepts (function-clause refusal), and a `MaskedPayload` is
  minted by exactly ONE module — `Samen.AI.Chokepoint` (`seal/3`). This probe DETECTS any
  construction of a `MaskedPayload` outside the chokepoint so a forged payload cannot reach a
  provider undetected.

  ## Why AST, not grep (the T64 attempt-1 gap this closes)

  A regex literal-scan catches only the syntactic `%MaskedPayload{field: ...}` form; it MISSES
  DYNAMIC construction — `struct(MaskedPayload, ...)`, `struct!/2`, `Kernel.struct/2`,
  `apply(Kernel, :struct, [MaskedPayload | _])`, and the `%{__struct__: MaskedPayload}` map
  forge — through which a rogue lib module could mint a `MaskedPayload` carrying RAW content
  outside the chokepoint and dispatch it to a provider. `%MaskedPayload{}` is a plain struct
  (`@enforce_keys [:kind]` only), so those forges succeed at runtime. This probe parses each
  `.ex` source's AST (`Code.string_to_quoted/1` + `Macro.prewalk/2`) and flags EVERY such
  construction outside the sanctioned chokepoint — the exact `struct/2` bypass an independent
  verifier reproduced is caught (see the rogue-file test below).

  ## What this guarantees — and its honest residual

  This is a **detection guarantee enforced at CI**, NOT a compile-time type-impossibility:
  the AST probe detects static struct literals AND `struct`/`struct!`/`Kernel.struct`/
  `apply(Kernel, :struct, ...)`/`%{__struct__: ...}` dynamic construction of a `MaskedPayload`
  outside `Samen.AI.Chokepoint`. The honest residual: a determined metaprogramming path — a
  fully-computed module name (`Module.concat/1` from runtime data) or runtime-generated code
  (`Code.eval_string/1`) — is beyond static AST detection, so single-mint is enforced
  **by probe**, not by the type system. Accidental/refactor bypasses (which developers write
  as any of the detected forms) ARE caught; the sound value-layer INV-7 guarantee
  (PiiResolution egress mode returning `%Masked{}` — no plaintext to leak) is T65.

  ## Match vs. construction (literal form)

  A field-BEARING `%MaskedPayload{kind: ...}` literal is a construction (always sets `:kind`,
  `@enforce_keys`). A field-LESS `%MaskedPayload{} = x` is a match (fields read via dot access —
  the lib-wide convention). The AST literal detector keys on non-empty fields, so provider/
  consumer matches are invisible to it; `struct/2`-form detection has no such ambiguity
  (`struct(MaskedPayload, ...)` is always construction). The rogue-file proof + the direct
  detector table below make the probe sabotage-refutable.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  @app_lib_globs ~w(
    samen_core/lib
    samen_web/lib
    samen_anthropic/lib
    samen_stripe/lib
    samen_postmark/lib
    samen_ses/lib
    samen_resend/lib
    demo/lib
    driftwood/lib
    pawchart/lib
    spikes/*/lib
  )

  @generator_template_globs ~w(samen_core/priv/templates)

  # THE single legitimate minting site (the module this probe exists to protect).
  @allowed_files ~w(samen_core/lib/samen/ai/chokepoint.ex)
                 |> Enum.map(&Path.join(Path.expand("../../..", __DIR__), &1))

  # --------------------------------------------------------------------------------------
  # Public scan entry point (public so the direct-detector table can call it)

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

  # --------------------------------------------------------------------------------------
  # File / tree scan

  defp scan_paths(extra_roots \\ []) do
    (@app_lib_globs ++ @generator_template_globs)
    |> Enum.flat_map(fn rel_glob -> Path.wildcard(Path.join(@repo_root, rel_glob)) end)
    |> Kernel.++(extra_roots)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join(dir, "**/*.{ex,eex}")) end)
    |> Enum.reject(&(&1 in @allowed_files))
  end

  defp all_offenders(paths) do
    for path <- paths,
        File.regular?(path),
        offender <- offenders_in_source(File.read!(path), Path.relative_to(path, @repo_root)) do
      offender
    end
  end

  # --------------------------------------------------------------------------------------

  describe "full-tree AST probe: a MaskedPayload is minted ONLY in Samen.AI.Chokepoint" do
    test "zero out-of-chokepoint MaskedPayload constructions (any form) under any app's lib/" do
      offenders = all_offenders(scan_paths())

      assert offenders == [],
             "an AI-egress path bypassed the chokepoint — MaskedPayload construction(s) found " <>
               "OUTSIDE Samen.AI.Chokepoint (literal or dynamic): #{inspect(offenders)}"
    end

    test "sanity: the scan genuinely walks the real tree (finds files in multiple apps)" do
      paths = scan_paths()
      assert Enum.any?(paths, &String.contains?(&1, "/samen_core/lib/"))
      assert Enum.any?(paths, &String.contains?(&1, "/samen_web/lib/"))
    end

    test "the chokepoint file itself IS the (sole) legitimate minting site" do
      chokepoint = Path.join(@repo_root, "samen_core/lib/samen/ai/chokepoint.ex")

      found =
        chokepoint
        |> File.read!()
        |> offenders_in_source("chokepoint.ex")
        |> Enum.any?(fn {_l, _line, kind} -> kind == :literal end)

      assert found, "sanity: Samen.AI.Chokepoint must contain the real MaskedPayload construction"
    end
  end

  describe "the AST probe catches the demonstrated struct/2 bypass (sabotage-refutable)" do
    test "ROGUE-FILE RED PROOF: literal + struct/2 + struct!/2 + apply-Kernel-struct forges all flip the probe" do
      tmp_root = Path.join(System.tmp_dir!(), "t64_rogue_lib_#{System.unique_integer([:positive])}")
      rogue_path = Path.join(tmp_root, "rogue_ai_bypass_tmp.ex")
      File.mkdir_p!(tmp_root)

      # The exact attack an independent verifier reproduced live: mint a MaskedPayload carrying
      # RAW PII OUTSIDE the chokepoint via struct/2 (which the old grep probe missed), plus the
      # other dynamic forms — none go through seal/3.
      File.write!(rogue_path, """
      defmodule Samen.AI.RogueBypassTmp do
        alias Samen.AI.MaskedPayload

        def literal_forge, do: %MaskedPayload{kind: :complete, segments: ["RAW-PII-ssn-123-45-6789"]}

        def struct2_forge do
          struct(Samen.AI.MaskedPayload, %{kind: :complete, segments: ["RAW-PII-ssn-123-45-6789"]})
        end

        def struct_bang_forge do
          struct!(MaskedPayload, %{kind: :complete, segments: ["RAW-PII"]})
        end

        def apply_forge do
          apply(Kernel, :struct, [Samen.AI.MaskedPayload, %{kind: :complete, segments: ["RAW-PII"]}])
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_root) end)

      offenders = all_offenders(scan_paths([tmp_root]))
      rogue = Enum.filter(offenders, fn {p, _l, _k} -> String.ends_with?(p, "rogue_ai_bypass_tmp.ex") end)
      kinds = rogue |> Enum.map(fn {_p, _l, k} -> k end) |> Enum.sort() |> Enum.uniq()

      assert :struct_call in kinds,
             "the struct/2 + struct!/2 forge (the verifier's exact bypass) MUST be caught — got: #{inspect(rogue)}"

      assert :literal in kinds, "the literal forge must be caught"
      assert :apply_struct in kinds, "the apply(Kernel, :struct, ...) forge must be caught"

      # Sabotage-refutable: removing the rogue file restores a fully green scan.
      File.rm_rf!(tmp_root)

      refute Enum.any?(all_offenders(scan_paths([tmp_root])), fn {p, _l, _k} ->
               String.ends_with?(p, "rogue_ai_bypass_tmp.ex")
             end),
             "removing the rogue file must restore a green scan"
    end

    test "DIRECT DETECTOR TABLE: each construction form flags; matches / unrelated structs do NOT" do
      # Flagged — every construction form (remove a detector clause and the matching row fails).
      assert [{_, _, :literal}] = offenders_in_source("%MaskedPayload{kind: :complete}")
      assert [{_, _, :literal}] = offenders_in_source("%Samen.AI.MaskedPayload{kind: :complete, segments: []}")
      assert [{_, _, :struct_call}] = offenders_in_source("struct(Samen.AI.MaskedPayload, %{kind: :complete})")
      assert [{_, _, :struct_call}] = offenders_in_source("struct!(MaskedPayload, %{kind: :complete})")
      assert [{_, _, :struct_call}] = offenders_in_source("Kernel.struct(MaskedPayload, %{kind: :complete})")
      assert [{_, _, :apply_struct}] = offenders_in_source("apply(Kernel, :struct, [Samen.AI.MaskedPayload, %{kind: :complete}])")
      assert [{_, _, :struct_map}] = offenders_in_source("%{__struct__: Samen.AI.MaskedPayload, kind: :complete, segments: []}")

      # NOT flagged — a field-less match, dot access, and an unrelated struct construction:
      # the ban is not vacuously true (it distinguishes construction from consumption).
      assert offenders_in_source("def complete(%MaskedPayload{} = payload, config), do: payload.segments") == []
      assert offenders_in_source("with {:ok, %Samen.AI.MaskedPayload{} = p} <- seal(), do: p") == []
      assert offenders_in_source("struct(SomeOtherResource, %{a: 1})") == []
      assert offenders_in_source("Kernel.struct(Foo.Bar, attrs)") == []
    end
  end
end
