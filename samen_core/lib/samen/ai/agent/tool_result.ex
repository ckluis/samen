defmodule Samen.AI.Agent.ToolResult do
  @moduledoc """
  The EG2 tool-result renderer (ADR-047 §4.3 step 2, batch A3) — the ONE site that
  turns a governed action's outcome (and the model's own tool-call echo) into the
  **ordered list of plain binaries** that re-enters the prompt as `:history`.

  ## The scrub points, as implemented (each numbered point is an assertion site)

    * **Egress-mode resolution.** Any records the result carries resolve through
      `Samen.Api.PiiResolution.resolve/4` with `egress: true, grant_egress?: false`
      (§4.4 — agent runs are masked-only categorically): a vault-routed field comes
      back `%Samen.Masked{}` on EVERY plane and renders `••••`. Sabotage 248 drops
      the egress flag and the tenant plane would resolve PLAINTEXT — the named
      masking red test flips.
    * **`render_value/1` semantics, reused not re-derived** (the chokepoint's rule):
      `%Samen.Masked{}` → `••••`, `%Ash.ForbiddenField{}` → `••••`, `nil` → `••••`.
    * **Never `inspect/1`.** Anything the renderer does not recognize is dropped
      with a bounded `[unrenderable:<key>]` marker — an `inspect` here would be the
      freeform-text leak `Samen.Automation.RunRecord.bounded_outcomes/1` exists to
      prevent. Sabotage 247 returns the raw meta instead of rendered binaries and
      the chokepoint's `safe_segment?/1` allowlist REFUSES the next turn fail-closed
      (`:pii_egress_refused`) — the renderer is defense; the allowlist is the
      guarantee (§4.3#5, belt-and-braces).
    * **The call echo** (§4.3#6): the model's tool call (kind + args) re-enters as
      ONE rendered binary via `render_call/2` — never the raw arg map (the exact
      hole shipped sabotage 45 documents, re-proven on the agent path at A3).
    * **INGRESS neutralization (§4.3a, T182 — PROPOSED).** Every scrub point above
      faces OUTWARD; this one faces IN. A tool result is attacker-reachable data, and
      it re-enters the prompt as `:history` on the next turn — so before a binary is
      emitted it goes through `Samen.AI.Agent.Ingress.sanitize/1`, which neutralizes
      invisible/bidi/control characters and instruction-shaped text into one fixed,
      non-invertible marker. Both untrusted surfaces funnel through one clause each:
      values via `render_scalar/2`, model-emitted argument NAMES via `render_key/1`.
      Sabotage 289 keeps it refutable. This is a content transform inside the existing
      render chokepoint, deliberately NOT a second policy seam beside T181's hook chain
      (see `Samen.AI.Agent.Ingress`'s moduledoc for why the hook chain cannot host it).
    * **Secrets-redaction lane (§4.3b, T184 — PROPOSED), distinct from `pii_*`.** A
      THIRD content transform at the SAME two clauses: `Samen.AI.Agent.Secrets.redact/1`
      pattern-scans for operator/app API keys, tokens and credentialed connection
      strings appearing INCIDENTALLY in tool output — free text no `pii_*` vault
      declaration governs, so `PiiResolution` has nothing to key on. Runs BEFORE
      `Ingress.sanitize/1` (on the untouched raw binary, so ingress's own marker cannot
      first break the generic fallback's label/value adjacency); the vault-masking path
      above (`render_field/2`, egress-mode `PiiResolution.resolve/4`) is untouched.
      Sabotage 291 keeps it refutable; sabotage 255 regenerated (see `Secrets`'
      moduledoc for why the passes order this way).

  Mask-by-omission composes on top: `fetch_record` projects to condition-eligible
  fields only, so a plaintext-PII freeform column is not even present to render —
  and the vault-routed fields that ARE present render masked.

  ## Sentinel-bearing scalars: replaced per value, NOT escalated to a run failure (A4)

  A3 shipped this renderer NOT scanning for the `vt_` sentinel, leaning entirely on the
  chokepoint's `safe_segment?/1` last line. The A3 verifier confirmed the seam is real
  and named the consequence: a tenant who can get a `vt_`-looking string into an
  eligible column HARD-FAILS every agent run that touches that record
  (`:pii_egress_refused`), because the offending line kills the whole payload. That is a
  tenant-controlled denial-of-service on the agent plane — attacker-controlled DATA
  choosing the outcome of a governed run.

  The ADR settles the posture and it is not the fail-closed one. §4.3 step 2 makes
  `[unrenderable:<field>]` the renderer's general answer to "a value I cannot safely
  emit"; §4.3 step 3 asserts as a PROPERTY that "the transcript at rest contains no
  vault plaintext and **no `vt_*` token**"; and §4.3#6 says the echo "is rendered to a
  single **`vt_`-free binary** by the same renderer". A renderer that emits a `vt_`
  scalar violates all three. So a sentinel-bearing scalar (or map key) renders as the
  bounded `[unrenderable:<key>]` marker — the SAME marker every other unrenderable value
  gets — and the run proceeds honestly with that one value elided.

  This does not weaken the last line: `safe_segment?/1` still refuses any `vt_`-bearing
  binary the renderer might ever emit, and the belt-and-braces §4.3#5 property (a
  renderer regression that emits raw shapes REFUSES fail-closed) is untouched — sabotage
  247 still proves it. What changed is only that the normal path stopped routing
  tenant data through the emergency exit. Sabotage 255 keeps the replacement refutable.
  """

  alias Samen.AI.Agent.Ingress
  alias Samen.AI.Agent.Secrets
  alias Samen.Api.PiiResolution

  @mask Samen.Masked.mask()
  @max_scalar_bytes 500
  @max_lines 60

  # The vault FK-token sentinel (ADR-043 §3.1 INV-7). See `render_scalar/2` and the
  # "sentinel-bearing scalars" section of the moduledoc.
  @vt_sentinel "vt_"

  # A11 (perf bound, §8 A5-performance row): the STARTING size of the raw window
  # `render_scalar/2` feeds to `Secrets.redact/1` + `Ingress.sanitize/1` before the existing
  # `truncate/1` cut — `redacted_and_sanitized/1` GROWS past this when it is not enough (see that
  # function's moduledoc for why a fixed window alone was refuted). Sized from `Secrets`' OWN
  # documented bounds so a single bridged match starting anywhere before the `@max_scalar_bytes`
  # cut is guaranteed to complete inside it without growth: worst case a label starts in the last
  # byte before the cut, then the bridged pattern's own gap (4096), the longest comment opener
  # (`<![CDATA[`, 9 bytes) and its budget (200) run to their maximum before the value even
  # starts. No separate value-length margin is needed on top of that — `extend_past_value_run/2`
  # picks the cut back up wherever the window lands inside a value run and walks it forward to
  # the run's own end, dynamically, for a value of any length.
  @redaction_margin 4096 + 9 + 200
  @redaction_window @max_scalar_bytes + @redaction_margin

  # A11-attempt-2: mirrors (does not re-derive the POLICY of) `Secrets`' label vocabulary and its
  # possessive label-to-separator gap — used ONLY by `dangling_start/1` to tell whether a
  # candidate window's tail could still be in the middle of forming a match `Secrets.redact/1`
  # would find given more bytes. Copied verbatim from `Secrets`' own private pattern (not exposed
  # publicly), the same shape-only mirroring `value_class_byte?/1` already does for the value
  # class. Deliberately POSSESSIVE, like `Secrets`' own — a single deterministic pass, no
  # backtracking, so finding every label+separator in a window costs O(window), never more.
  @dangling_label_word "(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret[_-]?key|" <>
                          "client[_-]?secret|private[_-]?key|password|passwd|pwd)\\b"
  @dangling_label_prefix @dangling_label_word <> "[^\\p{L}\\p{N}:=]*+[:=]"

  # Tail state 1 (still hunting a separator): a label found, then nothing but valid label-gap
  # bytes (excluding `:`/`=`, `Secrets`' own class) from there to the cut, with `:`/`=` never
  # reached. That label-to-separator gap is POSSESSIVE in `Secrets` but carries no length cap —
  # if the run reaches the cut without a `:`/`=`, more bytes could still supply one.
  @dangling_no_separator Regex.compile!(@dangling_label_word <> "[^\\p{L}\\p{N}:=]*\\z", "iu")

  # Tail state 2 (adjacent, separator already found): a label+separator, then nothing but
  # non-language bytes from there to the cut. `Secrets`' adjacent gap is UNBOUNDED (T14/UXD-14),
  # so reaching the cut still inside it proves nothing about whether a value follows.
  @dangling_adjacent Regex.compile!(@dangling_label_prefix <> "[^\\p{L}\\p{N}]*\\z", "iu")

  # Tail state 3 (possibly bridged): a label+separator whose OWN end falls within
  # `@redaction_margin` bytes of the cut. `Secrets`' bridged pattern's span from a separator to a
  # completed value is bounded by exactly that margin (the bounded gap + the longest comment
  # opener + its budget — see `@redaction_margin`'s own comment), so a separator this close to the
  # cut could still be the start of a bridged match `Secrets`' own comment-opener/budget regex
  # would find given more bytes. Deliberately does NOT re-run `Secrets`' own bridged gap-then-
  # opener regex to check this: that regex's `{0,4096}` gap is NOT possessive (it backtracks to
  # find the opener), so running it costs as much as the match it exists to avoid paying for on
  # exactly the adversarial input this item bounds (many opener-shaped bytes). `{0,N}\z` needs no
  # such backtracking — reaching a FIXED anchor admits only one valid consumed length, so a PCRE
  # engine resolves it in O(margin), not O(margin²) — and is an over-approximation on PURPOSE (it
  # does not confirm an opener or budget actually follow): that only ever grows the window MORE
  # than a precise check would, never less, so it cannot turn a real divergence into a missed one.
  @dangling_bridged Regex.compile!(
                       @dangling_label_prefix <> "[\\s\\S]{0,#{@redaction_margin}}\\z",
                       "iu"
                     )

  # A11-attempt-3, tier 2 (VENDOR). VA11 refuted attempt 2 because the three tail states above
  # mirror ONLY `Secrets`' generic LABEL vocabulary, while `Secrets.redact/1` runs a SECOND,
  # earlier pass over twelve VENDOR-shaped patterns (AWS/GitHub/Slack/payment/npm/Google/PEM/JWT/
  # `Bearer`/connection-string). A window cut landing inside a vendor pattern's own non-value-class
  # gap (the space in `Bearer <token>`, the `:` in `user:pass@host`) was invisible to all three,
  # so the window settled with the vendor label rendered as plain text where the untruncated
  # computation renders a marker. This tier closes that class WITHOUT enumerating the twelve
  # patterns' bodies, which is what made the enumeration approach fragile twice over:
  #
  #   * `@vendor_break` is the set of characters that occur in NO vendor-pattern match. Every one
  #     of the twelve either draws its body from an explicit class that omits all four (alnum,
  #     `_`, `-`, `.`, `+`, `/`, `:`, `@`, `\s`) or, in the connection-string case, is spelled
  #     `[^\s"'<>]+` and omits them by construction. So a vendor match in progress at the cut lies
  #     ENTIRELY inside the maximal suffix free of those four bytes — its start can never be
  #     earlier than that suffix's own start, whatever the pattern.
  #   * `@vendor_anchor` is a PREFIX of each pattern's mandatory literal head, so the earliest
  #     anchor inside that suffix bounds the earliest in-progress match start from the other side.
  #     Being a prefix (never a suffix, never the body) is what makes a LOOSER anchor safe: a
  #     shorter alternative can only match EARLIER, i.e. settle less, never more.
  #   * `@vendor_anchor_max` covers the remaining case — an anchor bisected by the cut itself, so
  #     no anchor is visible at all. 16 exceeds the longest anchor (`mongodb+srv://`, 14).
  #
  # `secrets_pattern_pinning_test` fails if `Secrets`' `@vendor_patterns` list changes at all, so
  # a thirteenth pattern cannot silently desynchronize this tier.
  @vendor_break ["\"", "'", "<", ">"]
  @vendor_break_chunk 4096
  @vendor_anchor_max 16
  @vendor_anchor ~r{(?:\b(?:AKIA|ASIA|AIza|gh[opus]_|github_pat_|xox[baprs]-|(?:sk|pk|rk)_(?:live|test)_|sk-|npm_|eyJ|Bearer|(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://)|-----BEGIN )}

  # A11-attempt-3, tier 3 (INGRESS). Attempt 2 mirrored `Secrets` only and left `Ingress.sanitize/1`
  # — the SECOND transform in the same pipeline — unmodelled entirely, which is a divergence of the
  # same class VA11 refuted and is pinned as its own red fixture: `"new" <> 9000 spaces <>
  # "instructions:"` renders `new` under attempt 2 and `[neutralized]` untruncated, because
  # `Ingress`' `\bnew\s+instructions?\s*:` pattern reaches across an UNBOUNDED whitespace run.
  #
  # This tier is measured on `Ingress.sanitize/1`'s OWN OUTPUT, not on its input, and that is
  # load-bearing: `neutralize_instructions/2` runs its eight patterns to a four-pass fixpoint, and
  # a marker produced by one pass can be swallowed by a later pass's `[^.\n]{0,40}` gap. In INPUT
  # coordinates that composition has no useful bound (a marker standing in for a collapsed match
  # multiplies the reach every pass), but in the FINAL text's own coordinates the only way a pass
  # can multiply a divergence is by making the text LONGER, and that is bounded — see below.
  #
  # A11-attempt-4 replaces attempt 3's tier 3 outright. VA11 refuted attempt 3 here for two
  # independent reasons, both of which came from RESTATING a fact about code this file does not
  # execute instead of executing it:
  #
  #   * **Wrong whitespace class.** Attempt 3's comment asserted `Ingress` "compiles with `u` but
  #     not `ucp`, so `\s` is ASCII whitespace only", and exempted exactly six ASCII bytes from the
  #     budget. `Regex.opts/1` on `Ingress`' own patterns returns `[:unicode, :ucp, :caseless]`, so
  #     `\s` is Unicode-aware: 16 further code points (U+00A0, U+1680, U+2000..U+200A, U+202F,
  #     U+205F, U+3000, …) span `Ingress`' UNBOUNDED `\s+`/`\s*` runs for free while draining the
  #     budget, which settles the window INSIDE a run the pipeline collapses. `@ingress_free_class`
  #     below is no longer stated at all: `@ingress_free_codepoints` is COMPUTED at compile time by
  #     running the regex engine over every code point, so being wrong about what `\s` means is not
  #     expressible here any more. A free class that is too WIDE only walks the cut further back
  #     (settles LESS, never more), which is why the class is deliberately a strict superset of
  #     `\s` under every option combination — `\s` ⊆ `\p{Z}` ∪ `\p{Cc}` ∪ {HT,LF,VT,FF,CR,NEL}.
  #   * **Wrong units.** Attempt 3 derived the span in CODE POINTS (`{0,40}` is 40 code points
  #     under `u`) and spent it in BYTES, so its own model actually needed 674 x 4 + 13 = 2709
  #     against a 2048 budget. The budget is now derived AND spent in the SAME unit: code points.
  #
  # The derivation, in the units it is spent in (code points), measured on the FINAL output:
  #
  #   * Per-pattern maximum NON-FREE match length: P1 44, P2 7, P3 8, P4 110, P5 9, P6 16, P7 12,
  #     P8 48 — sum S = 254. (The patterns' bounded gaps are `{0,40}`/`{0,20}` CODE POINTS, and the
  #     literal heads/tails are ASCII, so these are code-point counts by construction.)
  #   * `Ingress`' control pass is a single-code-point global replace, so it is EXACTLY local:
  #     `controls(A <> B) == controls(A) <> controls(B)` on any code-point boundary. It contributes
  #     no divergence at all.
  #   * One instruction pass moves a divergence tail D to at most D + S, TIMES whatever the pass
  #     lengthens the text by. Only a match SHORTER than the 13-code-point marker lengthens
  #     anything, and only four such matches exist: P1 (`<||>`, 4), P2 (`[INST]`, 6), P3
  #     (`<<SYS>>`, 7) and P5 (`you are now`, 11). None of the four can be CREATED by a
  #     replacement — the marker contains no `<`, `|`, `>` or space, and no match collapses to the
  #     empty string, so no two characters can ever become adjacent — and every one that is present
  #     in the input is consumed on pass 1 by its own pattern. Passes 2..4 therefore only ever
  #     SHORTEN, and the multiplier is 1 for all of them.
  #   * Pass 1 worst case, applying the eight patterns in `Enum.reduce` order with each pattern's
  #     own lengthening ratio: 3.25(0+44)=143, 2.17(143+7)=326, 1.86(326+8)=621, +110=731,
  #     1.18(731+9)=873, +16=889, +12=901, +48=949. Passes 2-4 add S each: 949 + 3x254 = 1711.
  #
  # `@ingress_span` is 3072 code points — 1.79x that bound, and 23x the worst divergence a
  # 16 000-case adversarial hill-climb over `Ingress.sanitize/1` itself could reach (130). Both the
  # bound and the free class are re-checked by EXECUTING `Ingress.sanitize/1` in
  # `agent_ingress_test.exs`'s "A11 TIER-3 PREMISE" tests, which measure the real divergence tail
  # rather than trusting this comment.
  @ingress_span 3072

  # The set of code points tier 3 walks over WITHOUT spending budget, DERIVED by executing the
  # regex engine at compile time rather than restated as a byte list. It is a strict superset of
  # `\s` under `[:unicode, :ucp]` (the options `Regex.opts/1` reports for every one of `Ingress`'
  # patterns) and of `Ingress`' own `@control_pattern` class, so no code point that any
  # `\s+`/`\s*` in `Ingress` can span is ever charged. Over-inclusion is the SAFE direction: a free
  # code point walks the cut further back, i.e. settles LESS.
  @ingress_free_class ~r/[\s\p{Z}\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @ingress_free_codepoints (fn ->
                              all =
                                for cp <- 0..0x10FFFF,
                                    cp < 0xD800 or cp > 0xDFFF,
                                    into: <<>>,
                                    do: <<cp::utf8>>

                              ~r/[\s\p{Z}\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
                              |> Regex.scan(all, return: :index)
                              |> List.flatten()
                              |> Enum.map(fn {offset, length} ->
                                <<cp::utf8>> = binary_part(all, offset, length)
                                cp
                              end)
                              |> MapSet.new()
                            end).()

  @doc """
  Render the model's own tool call (kind + validated args) to a single bounded
  binary for transcript/history re-entry — NEVER the raw arg map (§4.3#6).
  """
  @spec render_call(String.t(), map()) :: String.t()
  def render_call(kind, args) when is_binary(kind) and is_map(args) do
    rendered_args =
      args
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{render_key(k)}=#{render_scalar(v, to_string(k))}" end)

    String.trim("tool_call: #{kind} #{rendered_args}")
  end

  @doc """
  Render a governed action's outcome to the ordered list of plain binaries that
  re-enters the prompt as `:history` (§4.3 step 2).

  `opts`:
    * `:actor` — the run owner's actor map, threaded to `PiiResolution.resolve/4`
      (egress mode; REQUIRED for a record-bearing result).

  A `{:error, kind}` outcome renders as ONE bounded `tool_error:` line — the honest
  refusal the model sees (never a silent skip, never a rich term).
  """
  @spec render({:ok, map()} | {:error, term()}, keyword()) :: [String.t()]
  def render({:ok, meta}, opts) when is_map(meta) do
    meta
    |> render_meta(opts)
    |> Enum.take(@max_lines)
  end

  def render({:ok, _other}, _opts), do: ["tool_result: [unrenderable]"]

  def render({:error, kind}, _opts), do: ["tool_error: " <> bounded_kind(kind)]

  def render(_other, _opts), do: ["tool_error: tool_failed"]

  # --- meta rendering --------------------------------------------------------------------

  defp render_meta(meta, opts) do
    {records, meta} = pop(meta, :records)
    {resource_mod, meta} = pop(meta, :resource_module)
    {fields, meta} = pop(meta, :fields)
    {hits, meta} = pop(meta, :hits)

    scalar_lines =
      meta
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> "#{render_key(k)}: #{render_scalar(v, to_string(k))}" end)

    scalar_lines ++
      render_hits(hits) ++
      render_records(records, resource_mod, fields, opts)
  end

  defp pop(meta, key) do
    {value, rest} = Map.pop(meta, key)

    case value do
      nil -> Map.pop(rest, to_string(key))
      _ -> {value, rest}
    end
  end

  # --- search hits (already masking-safe bounded maps) -----------------------------------

  defp render_hits(nil), do: []

  defp render_hits(hits) when is_list(hits) do
    Enum.map(hits, fn
      hit when is_map(hit) and not is_struct(hit) ->
        rendered =
          hit
          |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
          |> Enum.map_join(" ", fn {k, v} -> "#{render_key(k)}=#{render_hit_value(v, to_string(k))}" end)

        "hit: " <> rendered

      _other ->
        "hit: [unrenderable]"
    end)
  end

  defp render_hits(_), do: ["hits: [unrenderable]"]

  # A hit's "display" is itself a bounded map of registered non-PII scalars.
  defp render_hit_value(v, _key) when is_map(v) and not is_struct(v) do
    v
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(",", fn {k, val} -> "#{render_key(k)}:#{render_scalar(val, to_string(k))}" end)
  end

  defp render_hit_value(v, key), do: render_scalar(v, key)

  # --- records (the §4.3 step-2 resolve + render) ----------------------------------------

  defp render_records(nil, _resource_mod, _fields, _opts), do: []

  defp render_records(records, resource_mod, fields, opts)
       when is_list(records) and is_atom(resource_mod) and not is_nil(resource_mod) do
    actor = Keyword.get(opts, :actor)
    pii_fields = pii_names(resource_mod)
    eligible = List.wrap(fields) |> Enum.reject(&(&1 in [:id, "id"]))

    # THE load-bearing call (§4.3 step 2 / §4.4): egress mode + grant egress OFF,
    # explicitly — a live reveal grant and grant_plaintext_egress: true can never
    # admit plaintext into an agent tool result (operator decision §9#2 TAKEN).
    resolved =
      PiiResolution.resolve(records, resource_mod, actor,
        egress: true,
        grant_egress?: false,
        repo: repo_of(resource_mod)
      )

    Enum.flat_map(resolved, fn record ->
      # A5 (the A4 verifier's R7): the primary key goes through `render_scalar/2` like
      # every other value. It was the ONE interpolation site that did not, which is
      # structurally moot for a uuid pk but would have been a sentinel path around the
      # A4 elision fold for a host resource with a string pk.
      header = "record: #{inspect(resource_mod)}##{render_scalar(Map.get(record, :id), "id")}"

      value_lines =
        Enum.map(eligible, fn field ->
          "#{render_key(field)}: #{render_field(Map.get(record, field), to_string(field))}"
        end)

      pii_lines =
        Enum.map(pii_fields, fn field ->
          "#{render_key(field)}: #{render_field(Map.get(record, field), to_string(field))}"
        end)

      [header | value_lines ++ pii_lines]
    end)
  rescue
    # A renderer crash must degrade to a bounded marker, never leak a term (EG6) —
    # and the chokepoint allowlist remains the last line regardless.
    _ -> ["tool_result: [unrenderable]"]
  end

  defp render_records(_records, _resource_mod, _fields, _opts), do: ["tool_result: [unrenderable]"]

  # The chokepoint's render_value/1 semantics, reused: masked/forbidden/nil → ••••.
  defp render_field(%Samen.Masked{}, _key), do: @mask
  defp render_field(%Ash.ForbiddenField{}, _key), do: @mask
  defp render_field(nil, _key), do: @mask
  defp render_field(value, key), do: render_scalar(value, key)

  # --- scalars ---------------------------------------------------------------------------

  # Bounded scalar rendering: binaries (truncated), numbers, booleans, atoms, and
  # date/times render; EVERYTHING else — a struct, a nested rich term, a pid — is
  # dropped with the bounded marker, never inspect-ed.
  #
  # A4 (fold (c)): a scalar CARRYING the `vt_` vault-token sentinel is one more value
  # this renderer cannot safely emit, so it takes the same `[unrenderable:<key>]` exit
  # as any other. Per-VALUE, deliberately: escalating it to the chokepoint's whole-payload
  # refusal would let attacker-controlled data hard-fail a governed run (see moduledoc).
  # Truncation runs AFTER the scan, so a sentinel past the 500-byte boundary cannot be
  # "sanitised" by luck.
  #
  # T182 (§4.3a INGRESS, PROPOSED): the value is NEUTRALIZED before it is scanned and before
  # it is emitted — this clause is the ingress chokepoint for every untrusted binary that
  # becomes a `:history` line. Sanitizing FIRST is load-bearing twice over: the binary that
  # gets emitted is the binary that was scanned, and a `vt_` obfuscated with zero-width
  # characters cannot hide from the sentinel scan behind them. The RAW value is scanned too,
  # so the pre-T182 refusal is a floor this can only tighten, never move.
  #
  # T184 (§4.3b secrets lane, PROPOSED): `Secrets.redact/1` runs FIRST, on the untouched raw
  # binary, before `Ingress.sanitize/1` — a distinct lane from the `pii_*` vault taxonomy
  # above, catching operator/app API keys, tokens and connection strings that carry no
  # declared-field vault routing at all (see `Secrets`' moduledoc for the ordering rationale).
  #
  # A11 (perf bound, §8 A5-performance row): `redacted_and_sanitized/1` bounds how much of `v`
  # `Secrets.redact/1` + `Ingress.sanitize/1` ever have to process — cost was O(byte_size(v)) even
  # though only `@max_scalar_bytes` of the OUTPUT is ever kept, and a packed-label opener flood
  # turns that into a large, linear, but production-reachable cost (144ms/2.45s at 64KB/1MB).
  # Attempt 1 fixed the window's size; VA11 broke that fixed size two ways (window starvation
  # under heavy redaction, and adjacent-gap non-formation) and attempt 2's
  # `redacted_and_sanitized/1` GROWS the window instead — see its own moduledoc for the full
  # byte-identity argument. The scan-then-truncate ORDER is unchanged: `sentinel?/1` still runs on
  # the FULL, unbounded `v` (never windowed — the vt_ floor must not narrow), and truncation to
  # `@max_scalar_bytes` still runs AFTER the scan, on the bounded transform's output, exactly as
  # before.
  defp render_scalar(v, key) when is_binary(v) do
    sanitized = redacted_and_sanitized(v)

    if sentinel?(v) or sentinel?(sanitized),
      do: unrenderable(key),
      else: truncate(sanitized)
  end

  defp render_scalar(v, _key) when is_number(v), do: to_string(v)
  defp render_scalar(v, _key) when is_boolean(v), do: to_string(v)

  defp render_scalar(v, key) when is_atom(v) and not is_nil(v) do
    rendered = Atom.to_string(v)
    if sentinel?(rendered), do: unrenderable(key), else: rendered
  end

  defp render_scalar(%DateTime{} = v, _key), do: DateTime.to_iso8601(v)
  defp render_scalar(%NaiveDateTime{} = v, _key), do: NaiveDateTime.to_iso8601(v)
  defp render_scalar(%Date{} = v, _key), do: Date.to_iso8601(v)
  defp render_scalar(_v, key), do: unrenderable(key)

  # The bounded marker. The KEY is authored/catalog-derived (a field or arg name), never
  # tenant free text — but it is scanned anyway, so no path can smuggle a sentinel out
  # through the marker itself.
  defp unrenderable(key) do
    key = to_string(key)
    if sentinel?(key), do: "[unrenderable]", else: "[unrenderable:#{key}]"
  end

  defp sentinel?(value) when is_binary(value), do: String.contains?(value, @vt_sentinel)
  defp sentinel?(_value), do: false

  # Every key this module interpolates into a line — a meta key, a record field name, a
  # search-hit key, a model-emitted ARG name. Field names are catalog-derived and arg
  # names are already `vt_`-gated upstream (`Samen.AI.Agent`'s `refuse_vt_args/1` scans
  # keys AND values), but `render_call/2` and `render/2` are PUBLIC — so the key side is
  # scanned here too rather than relying on every caller having done it.
  # T182: an arg name is MODEL output, so it is untrusted content on the ingress side too —
  # an arg name carrying a line break would forge a transcript line out of `render_call/2`'s
  # `k=v` join exactly as a value would. Same neutralization, same chokepoint discipline.
  # T184: same secrets lane, same ordering (redact before sanitize) — a model-emitted arg
  # name is untrusted content too and gets no exemption from the pattern scan.
  defp render_key(key) do
    rendered = key |> to_string() |> Secrets.redact() |> Ingress.sanitize()
    if sentinel?(rendered), do: "[key]", else: rendered
  end

  defp truncate(v) when byte_size(v) <= @max_scalar_bytes, do: v
  defp truncate(v), do: String.slice(v, 0, @max_scalar_bytes)

  # --- A11 (attempt 3): bound redaction cost by the RENDERED OUTPUT length, growing the raw
  # window, and settle each PASS of the pipeline in that pass's OWN coordinates ----------------

  # Attempt 1 fixed the raw window; VA11 broke the fixed size two ways (redaction-collapse window
  # starvation on a tiled short-label/long-value shape, and adjacent-gap non-formation past the
  # window's edge). Attempt 2 replaced it with a GROWN window and fixed both, and VA11 refuted it
  # again for a THIRD reason of the same species: its `dangling_start/1` mirrored only `Secrets`'
  # generic LABEL vocabulary, so a cut landing inside a VENDOR pattern's own non-value-class gap
  # (`Bearer <token>`, `postgres://user:pass@host`) settled early and rendered the vendor label as
  # plain text where the untruncated computation renders a marker. Building this node's own corpus
  # then found a FOURTH of the same species that no verifier had reached yet: attempt 2 modelled
  # `Secrets` only and never modelled `Ingress.sanitize/1` at all, so `"new" <> 9000 spaces <>
  # "instructions:"` rendered `new` instead of `[neutralized]`.
  #
  # The recurring root cause in all four is ONE thing: the window logic mirrored a SUBSET of what
  # the pipeline actually matches. Attempt 3's answer is structural rather than a fourth
  # hand-written tail state.
  #
  #   1. The pipeline is settled PASS BY PASS, each pass analysed in its OWN input's coordinates:
  #      vendor patterns against the raw window, `Secrets`' labelled patterns against the REDACTED
  #      text, `Ingress`' patterns against the SANITIZED text. Every earlier pass's collapse has
  #      already happened by the time the next pass is analysed, so a marker that shortens the
  #      distance between a label and its value (a long vendor secret collapsing to 17 bytes
  #      INSIDE `Secrets`' bridged 4096+9+200 budget, a marker swallowed by `Ingress`' `{0,40}`
  #      gap on a later fixpoint pass) cannot smuggle reach past a bound measured before it.
  #      Attempt 2 measured everything against the RAW window, where those two compositions have
  #      no useful bound at all.
  #   2. Each tier over-approximates by CHARACTER CLASS or by SPAN BUDGET rather than by
  #      re-deriving pattern bodies: `@vendor_break` (the four bytes no vendor pattern can contain)
  #      plus `@vendor_anchor` (a PREFIX of each pattern's literal head) for the vendor tier;
  #      `@ingress_span` non-whitespace bytes, with whitespace runs skipped without budget, for the
  #      ingress tier. Both are one-sided: a looser class or a shorter anchor settles LESS, never
  #      more, so being wrong about a detail costs window growth, not byte-identity.
  #   3. `secrets_pattern_pinning_test` (in `agent_ingress_test.exs`) hashes `Secrets`'
  #      `@vendor_patterns` and label vocabulary and `Ingress`' `@instruction_patterns` straight
  #      out of their source files and fails if either module gains, loses or edits a pattern —
  #      the desynchronization that produced all four divergences cannot happen silently again.
  #
  # Growth itself is unchanged in shape: start at `@redaction_window`, and DOUBLE only when the
  # settled output falls short of `@max_scalar_bytes` graphemes, until the target is reached or the
  # raw binary is exhausted (at which point the untruncated computation runs, byte-identical by
  # definition). No FINITE window can be a proof against `Secrets`' deliberately unbounded
  # adjacent gap (`password=<4097 spaces><value>` must still redact — `Secrets`' own moduledoc), so
  # a shape that never settles gracefully degrades to the cost the untruncated computation already
  # paid, never more; doubling keeps the total across iterations O(final window).
  #
  # Only grown for a `v` that is valid UTF-8 AS A WHOLE. `Secrets.redact/1` and `Ingress.sanitize/1`
  # both pick between a Unicode-aware and a byte-oriented mode by checking `String.valid?/1` on
  # whatever text THEY receive, and a truncated window of an INVALID-UTF-8 `v` could be valid on
  # its own — a different mode, therefore a real divergence. Any codepoint-aligned prefix of a
  # valid `v` is itself valid, so the divergence cannot occur once `v` is known valid. For an
  # invalid-UTF-8 `v` this returns the untruncated computation: unbounded, exactly like before this
  # item, but byte-identical.
  defp redacted_and_sanitized(v) when byte_size(v) <= @redaction_window do
    v |> Secrets.redact() |> Ingress.sanitize()
  end

  defp redacted_and_sanitized(v) do
    if String.valid?(v) do
      grow_window(v, @redaction_window)
    else
      v |> Secrets.redact() |> Ingress.sanitize()
    end
  end

  # Returns the FINAL redacted+sanitized text directly (never a raw window `render_scalar/2` would
  # have to transform again) — `settled_output/1` already computes it once per candidate to check
  # sufficiency.
  defp grow_window(v, cut) do
    if cut >= byte_size(v) do
      v |> Secrets.redact() |> Ingress.sanitize()
    else
      case v |> binary_part(0, cut) |> shrink_to_valid_utf8() |> settled_output() do
        {:sufficient, settled} -> settled
        :insufficient -> grow_window(v, cut * 2)
      end
    end
  end

  # The three tiers, in pipeline order. Each cut is taken in the coordinates of the text the NEXT
  # transform will actually see, so no tier has to reason about an earlier tier's collapses.
  defp settled_output(prefix) do
    redacted =
      prefix
      |> binary_part(0, vendor_settled(prefix))
      |> shrink_to_valid_utf8()
      |> Secrets.redact()

    sanitized =
      redacted
      |> binary_part(0, labeled_settled(redacted))
      |> shrink_to_valid_utf8()
      |> Ingress.sanitize()

    settled =
      sanitized
      |> binary_part(0, ingress_settled(sanitized))
      |> shrink_to_valid_utf8()

    # VA11 attempt 4 (rung 4): `truncate/1` measures GRAPHEMES (`String.slice/3`), but every
    # tier above is denominated in bytes or code points, so nothing bounds where a grapheme
    # cluster's boundary falls. At `>=`, a settled prefix of EXACTLY 500 graphemes whose 500th
    # cluster is INCOMPLETE (its continuation code point(s) — a combining mark, the second half
    # of a regional-indicator flag pair — sit just past the tier-3 cut) reads as sufficient, and
    # `truncate/1` then leaves that grapheme severed where the unbounded computation would have
    # completed it. At 501+ settled graphemes the 500th cluster is necessarily closed (grapheme
    # segmentation only re-opens a boundary when more code points that extend it are present in
    # the text being measured), so `>` is exactly the one grapheme less permissive that closes
    # the gap without touching any tier's byte/code-point budget.
    if String.length(settled) > @max_scalar_bytes,
      do: {:sufficient, settled},
      else: :insufficient
  end

  # TIER 1 (vendor). The earliest raw offset at which any of `Secrets`' twelve vendor patterns
  # could still be forming. A vendor match contains none of `@vendor_break`, so it cannot start
  # before the maximal `@vendor_break`-free suffix; inside that suffix it must begin at a
  # `@vendor_anchor`; and an anchor bisected by the cut itself is covered by `@vendor_anchor_max`.
  defp vendor_settled(prefix) do
    len = byte_size(prefix)
    run = vc_run_start(prefix)

    anchor =
      case Regex.run(@vendor_anchor, binary_part(prefix, run, len - run), return: :index) do
        [{start, _len} | _] -> run + start
        nil -> len
      end

    min(anchor, max(len - @vendor_anchor_max, 0))
  end

  # The start of the maximal suffix free of every `@vendor_break` byte, scanned backwards in
  # bounded chunks so a multi-megabyte window costs O(window) time and O(chunk) memory rather than
  # materialising one match tuple per occurrence.
  defp vc_run_start(text), do: vc_run_start(text, byte_size(text))
  defp vc_run_start(_text, 0), do: 0

  defp vc_run_start(text, from) do
    start = max(from - @vendor_break_chunk, 0)

    case :binary.matches(binary_part(text, start, from - start), @vendor_break) do
      [] ->
        vc_run_start(text, start)

      matches ->
        {offset, length} = List.last(matches)
        start + offset + length
    end
  end

  # TIER 2 (`Secrets`' labelled fallback), measured on the REDACTED text. `back_off_value_run/2`
  # keeps the cut from bisecting a value-class run that ends at the dangling point.
  defp labeled_settled(text) do
    case dangling_start(text) do
      nil -> byte_size(text)
      start -> back_off_value_run(text, start)
    end
  end

  # The earliest offset at which a match `Secrets`' labelled or bridged pattern could find might
  # still be forming — the smallest of the three tail states' starts, whichever fire.
  defp dangling_start(text) do
    [
      match_start(@dangling_no_separator, text),
      match_start(@dangling_adjacent, text),
      match_start(@dangling_bridged, text)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      starts -> Enum.min(starts)
    end
  end

  defp match_start(regex, text) do
    case Regex.run(regex, text, return: :index) do
      [{start, _len} | _] -> start
      nil -> nil
    end
  end

  # Back the cut off (backward, one byte at a time) past any run of `Secrets`' value-class bytes
  # ending exactly at `cut`, so settling on an earlier "dangling" boundary never bisects a
  # DIFFERENT, already-resolved match's value run that happens to reach up to it.
  defp back_off_value_run(_text, 0), do: 0

  defp back_off_value_run(text, cut) do
    if value_class_byte?(:binary.at(text, cut - 1)) do
      back_off_value_run(text, cut - 1)
    else
      cut
    end
  end

  # TIER 3 (`Ingress`), measured on the SANITIZED text — see `@ingress_span`. Walks backwards ONE
  # CODE POINT at a time, spending one unit of budget per code point OUTSIDE
  # `@ingress_free_codepoints` and none at all for one inside it. Code points, not bytes: the
  # budget is derived from `{0,40}`-style quantifiers that count code points, so spending it per
  # byte would be spending a different currency than the one it was priced in — the second of the
  # two unsoundnesses that refuted attempt 3.
  defp ingress_settled(text), do: ingress_settled(text, byte_size(text), @ingress_span)

  defp ingress_settled(_text, 0, _budget), do: 0

  defp ingress_settled(text, at, budget) do
    start = codepoint_start(text, at - 1, 3)

    case binary_part(text, start, at - start) do
      <<cp::utf8>> ->
        cond do
          ingress_free_codepoint?(cp) -> ingress_settled(text, start, budget)
          budget == 0 -> at
          true -> ingress_settled(text, start, budget - 1)
        end

      _not_a_codepoint ->
        # Unreachable on a valid-UTF-8 `text` (the only kind `grow_window/2` produces), but a
        # renderer may never raise: fall back to charging the single byte.
        if budget == 0, do: at, else: ingress_settled(text, at - 1, budget - 1)
    end
  end

  # The index of the first byte of the code point whose LAST byte sits at `index`. Bounded at
  # three continuation bytes — the widest UTF-8 code point is four bytes.
  defp codepoint_start(_text, index, 0), do: index

  defp codepoint_start(text, index, back) do
    if index > 0 and Bitwise.band(:binary.at(text, index), 0xC0) == 0x80,
      do: codepoint_start(text, index - 1, back - 1),
      else: index
  end

  # ASCII is decided arithmetically so the hot path never touches the `MapSet`: `\s` ∪ `\p{Cc}`
  # restricted to ASCII is exactly `0x00..0x20` plus DEL. Above ASCII the compile-time-derived set
  # decides. `agent_ingress_test.exs` asserts the two agree on every code point.
  defp ingress_free_codepoint?(cp) when cp <= 0x20, do: true
  defp ingress_free_codepoint?(0x7F), do: true
  defp ingress_free_codepoint?(cp) when cp < 0x80, do: false
  defp ingress_free_codepoint?(cp), do: MapSet.member?(@ingress_free_codepoints, cp)

  @doc false
  # Exposed for `agent_ingress_test.exs`'s TIER-3 PREMISE tests, which re-derive both halves of
  # the tier-3 bound by EXECUTING `Ingress.sanitize/1` instead of trusting `@ingress_span`'s
  # comment. Not part of the render contract.
  def __tier3_bound__, do: {@ingress_span, @ingress_free_codepoints, @ingress_free_class}

  # Never cut mid-codepoint: back off one byte at a time (bounded — the widest UTF-8 codepoint is
  # 4 bytes) until the prefix is valid UTF-8 on its own. `grow_window/2` only ever runs on a `v`
  # already confirmed valid UTF-8 as a whole, so this restores codepoint alignment after a raw
  # byte cut rather than papering over a `v` that was invalid to begin with — and every realigned
  # prefix stays in the Unicode-mode pattern the untruncated `v` would use, exactly.
  defp shrink_to_valid_utf8(text) when byte_size(text) == 0, do: text

  defp shrink_to_valid_utf8(text) do
    if String.valid?(text),
      do: text,
      else: shrink_to_valid_utf8(binary_part(text, 0, byte_size(text) - 1))
  end

  # The character class `Secrets`' generic value pattern (`@value_shape`) matches, mirrored here
  # ONLY so a window cut never lands inside a value run mid-match. Not a re-derivation of
  # `Secrets`' redaction policy — the label vocabulary and match semantics stay in `Secrets`,
  # untouched; this is the one fact about its shape a caller needs to avoid bisecting a secret.
  defp value_class_byte?(byte) do
    (byte >= ?A and byte <= ?Z) or (byte >= ?a and byte <= ?z) or (byte >= ?0 and byte <= ?9) or
      byte in [?+, ?/, ?_, ?., ?-, ?!, ?@, ?#, ?$, ?%, ?^, ?&, ?*, ?', ?"]
  end

  defp bounded_kind(kind) when is_atom(kind) and not is_nil(kind) do
    rendered = Atom.to_string(kind)
    if sentinel?(rendered), do: "tool_failed", else: truncate(rendered)
  end

  defp bounded_kind(_kind), do: "tool_failed"

  defp pii_names(resource_mod) do
    resource_mod |> Samen.Pii.Info.pii_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  defp repo_of(resource_mod) do
    AshPostgres.DataLayer.Info.repo(resource_mod, :read)
  rescue
    _ -> Application.get_env(:samen_core, :vault_repo)
  end
end
