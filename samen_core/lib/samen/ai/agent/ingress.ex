defmodule Samen.AI.Agent.Ingress do
  @moduledoc """
  Untrusted-content sanitization at tool-result **INGRESS** — the missing direction of the
  ADR-047 chokepoint (T182; ADR-047 §4.3a, PROPOSED).

  ADR-047 §4.3 spells out six numbered scrub points and every one of them faces **outward**:
  PII resolves in egress mode (§4.3#2), the transcript at rest carries no vault plaintext and
  no `vt_*` token (§4.3#3), `safe_segment?/1` refuses an unrenderable shape on the way to the
  provider (§4.3#5). All of that protects **samen's own data from leaving**. Nothing protected
  the loop from what a tool result **brings in**.

  A tool result is attacker-reachable data. A tenant (or an upstream system a tenant controls)
  owns the bytes in a record's freeform column, and those bytes re-enter the prompt on the next
  turn as `:history` (§4.3 step 4). Two classes of content turn that data into control:

    * **Frame forgery.** The transcript is an ordered list of plain binaries that the provider
      sees as lines. A value carrying a line break does not render as one line — it renders as
      two, and the second one is attacker-authored at the start of a line, where the loop's own
      frames (`tool_call: `, `tool_result: `, `record: `, `hit: `) live.
    * **Invisible content.** Zero-width and bidi format characters are read by the model and
      not by the human reviewing the transcript, so what a reviewer approves and what the model
      acts on are different strings.

  ## What it does

  `sanitize/1` runs two ordered passes and **neutralizes** — it replaces, it never deletes, and
  the replacement is not an escaping scheme anything downstream can undo:

    1. **Invisible / control characters.** Every codepoint in `\\p{Cc}` (C0 + C1 controls,
       including `\\n`, `\\r`, `\\t` and NEL), `\\p{Cf}` (ZWSP/ZWNJ/ZWJ/WJ/BOM/SHY/MVS, the
       LRM/RLM/LRE/RLE/PDF/LRO/RLO bidi overrides, the LRI/RLI/FSI/PDI isolates, the
       interlinear-annotation marks, and the U+E0000 tag block), `\\p{Zl}` (U+2028) and
       `\\p{Zp}` (U+2029) becomes the marker. This is what closes frame forgery
       **structurally**: a sanitized value cannot contain a line break, so it can never open a
       line, so it can never forge a frame. That is deliberately stronger than blocklisting
       role words — `"the user: bob"` in a tenant's note stays readable, because after this
       pass it is not a forgery vector.
    2. **Instruction-shaped text.** The chat-template control tokens that are never legitimate
       tenant text (`<|…|>`, `[INST]`/`[/INST]`, `<<SYS>>`/`<</SYS>>`) and the bounded list of
       imperative frame-override phrases in `@instruction_patterns` become the same marker.
       Applied to a bounded fixpoint so a replacement cannot leave a fresh match behind.

  A binary that is not valid UTF-8 has no renderable content and can carry arbitrary bytes into
  a prompt, so it is refused wholesale as `#{inspect("[neutralized:invalid_utf8]")}` — a visible
  marker, never a silent drop.

  ## Not reversible, and provably so

  **Every** neutralized span of **every** class collapses to the *same* fixed marker, so
  `sanitize/1` is many-to-one: `sanitize/1` maps a zero-width space and a right-to-left
  override to byte-identical output. A function with a collision has no inverse, so no
  downstream reader — the model included — can reconstruct the original active payload from
  what the transcript stored. It is also idempotent, so a second pass restores nothing.

  ## Where it runs (the ingress chokepoint, not a second policy seam)

  `Samen.AI.Agent.ToolResult` is the ONE site that turns a governed action's outcome into the
  binaries that enter `:history` (§4.3 step 2), and inside it every untrusted binary funnels
  through `render_scalar/2` (values) and `render_key/1` (model-emitted argument names). Those
  are the two call sites, so sanitization is applied **before the value is stored**, in both the
  in-process and the durable loop, by construction rather than by a caller remembering.

  This is deliberately **not** a consumer of T181's `Samen.AI.Agent.Hook` chain (§10a row 25).
  That seam is an optional, host-configured, **narrowing-only policy** seam: `:after_tool_execution`
  is handed a token-only context (`run_id`/`agent`/`org_id`/`kind`/`arg_keys`/`error_kind`) that
  never carries the outcome's content, and the point accepts `:halt` alone. Rewriting content
  through it would have to widen the one invariant that seam exists to keep, and would make a
  security guarantee opt-in — the opposite of fail-closed. Two policy seams in one loop is the
  failure the T181→T184 ordering exists to prevent, and adding a content transform inside the
  existing render chokepoint adds none.

  ## Known residual (documented, not silently accepted)

  Variation selectors (U+FE00–U+FE0F, U+E0100–U+E01EF) are category `Mn`/`Me`, not `Cf`, and are
  left alone: they legitimately carry emoji presentation in tenant text. They can encode hidden
  data but cannot forge a frame, and every codepoint they attach to still renders visibly.
  """

  # One marker for EVERY neutralized span of EVERY class. Sharing it is what makes the
  # transform many-to-one, and therefore not invertible (see the moduledoc).
  @marker "[neutralized]"
  @invalid_marker "[neutralized:invalid_utf8]"

  # C0/C1 controls, every Unicode format character (zero-width, bidi, tag block), and the
  # line/paragraph separators. `\p{Cs}` cannot occur in a valid UTF-8 binary and `\p{Cn}` is
  # deliberately excluded — it moves between Unicode versions.
  @control_pattern ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  # Bounded and explicit. Two groups: chat-template control tokens (never legitimate tenant
  # text), then the imperative frame-override openers. Narrow by design — a false positive
  # costs a reader a visible marker, but mangling ordinary business text costs every reader.
  @instruction_patterns [
    ~r/<\|[^|>\n]{0,40}\|>/u,
    ~r/\[\/?INST\]/iu,
    ~r/<<\/?SYS>>/iu,
    ~r/\b(?:ignore|disregard|forget|override|bypass)\b[^.\n]{0,40}?\b(?:previous|prior|preceding|earlier|above|all)\b[^.\n]{0,40}?\b(?:instruction|instructions|prompt|prompts|rule|rules|direction|directions|message|messages|context)\b/iu,
    ~r/\byou\s+are\s+now\b/iu,
    ~r/\bnew\s+instructions?\s*:/iu,
    ~r/\bsystem\s+prompt\b/iu,
    ~r/\b(?:reveal|print|repeat|output|show)\b[^.\n]{0,20}?\byour\s+(?:system\s+)?(?:prompt|instructions)\b/iu
  ]

  # A replacement can in principle leave a fresh match behind, so pass 2 runs to a fixpoint.
  # Bounded, because "run until stable" on adversarial input is not a termination argument.
  @instruction_passes 4

  @doc """
  The neutralized projection of one untrusted binary, safe to store as a `:history` line.

  Total on binaries and never raises: an invalid-UTF-8 binary is refused wholesale as
  `[neutralized:invalid_utf8]` rather than passed to a Unicode matcher.
  """
  @spec sanitize(binary()) :: binary()
  def sanitize(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> neutralize_controls()
      |> neutralize_instructions(@instruction_passes)
    else
      @invalid_marker
    end
  end

  @doc "The marker every neutralized span collapses to. Exposed so tests assert one constant."
  @spec marker() :: binary()
  def marker, do: @marker

  # --- pass 1: invisible / control characters -------------------------------------------

  defp neutralize_controls(text), do: Regex.replace(@control_pattern, text, @marker)

  # --- pass 2: instruction-shaped text --------------------------------------------------

  defp neutralize_instructions(text, 0), do: text

  defp neutralize_instructions(text, passes) do
    case apply_instruction_patterns(text) do
      ^text -> text
      changed -> neutralize_instructions(changed, passes - 1)
    end
  end

  defp apply_instruction_patterns(text) do
    Enum.reduce(@instruction_patterns, text, &Regex.replace(&1, &2, @marker))
  end
end
