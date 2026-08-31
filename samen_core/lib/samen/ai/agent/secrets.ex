defmodule Samen.AI.Agent.Secrets do
  @moduledoc """
  Pattern-based secrets-redaction lane at the tool-result INGRESS chokepoint (T184; ADR-047
  §4.3b, PROPOSED) — **distinct from the declared-field `pii_*` vault-class taxonomy**.

  ## Why a second lane, not a wider `pii_*`

  `pii_*` (`Samen.Pii.Info`, the vault, `PiiResolution.resolve/4`) governs content the schema
  **declares**: a resource author marks a column `pii_attribute(:ssn, ..., vault: :pii_ssn)` and
  every read resolves it through the vault. That machinery has no opinion about a column NOBODY
  declared — a tenant's freeform `notes` field that happens to contain an operator's leaked AWS
  key, or an app config value copied into a support ticket body. Those bytes carry no vault
  token, no `Ash.ForbiddenField`, nothing `PiiResolution` can key on. They are attacker/tenant
  **free text** that merely happens to be secret-SHAPED, so the only mechanism that can catch
  them is a pattern scan over the rendered content itself — the "distinct lane" this item is.

  ## Where it runs (the ingress chokepoint, not a second policy seam)

  Exactly `Samen.AI.Agent.Ingress`'s two call sites (T182, ADR-047 §4.3a): `render_scalar/2`
  (values) and `render_key/1` (model-emitted argument names) in `Samen.AI.Agent.ToolResult` — the
  ONE site that turns a governed action's outcome into the binaries that enter `:history`. No new
  dispatch point, no `Samen.AI.Agent.Hook` chain consumer (the same reasoning `Ingress`'s
  moduledoc gives: `:after_tool_execution` is optional, host-configured, narrowing-only, and
  content-blind by design — hosting a redaction pass there would make a security guarantee
  opt-in). Two policy seams in one loop is exactly the failure the T181→T182→T183→T184 ordering
  exists to prevent; this is a THIRD content transform inside the one existing render chokepoint,
  not a fourth seam.

  `redact/1` runs BEFORE `Ingress.sanitize/1` in both call sites: on the untouched raw binary, so
  a control/bidi character `Ingress` would later collapse to its own marker cannot first split a
  `label = value` adjacency the generic fallback pattern (below) depends on. `Ingress.sanitize/1`
  then mops up whatever control/instruction content remains in the (now possibly redacted) text.
  Running the passes in the other order would let ingress noise silently defeat the labeled
  fallback without ever touching a KNOWN vendor-prefixed secret (those match on contiguous
  printable characters `Ingress` never touches either way) — see RESIDUAL below for the honest
  boundary of what this still cannot see.

  ## What it catches

  Two ordered classes, both many-to-one onto the SAME fixed marker:

    1. **Known vendor-shaped prefixes** — AWS access/session key ids, GitHub tokens (classic and
       fine-grained), Slack tokens, payment-processor-style live/restricted secret keys, npm tokens,
       Google API keys, PEM
       private-key headers, JWTs (three base64url segments), `Authorization: Bearer` values, and
       connection-string schemes (`postgres(ql)?/mysql/mongodb(+srv)?/redis/amqp`) carrying an
       embedded `user:pass@host` credential.
    2. **The fail-closed generic fallback** — an `api_key=`/`token=`/`secret=`/`password=`-shaped
       label assigned to a non-trivial value, regardless of whether the value matches any known
       vendor format. This is the "unrecognized-but-secret-shaped string is redacted, not passed
       through" floor: a secret with no known vendor signature is still caught because it is
       still *labeled* as one in the tool output.

  Neither class fires on ordinary business data of the same rough shape — a UUID, a plain
  sentence, a numeric id — because both require either a vendor's distinctive character prefix or
  an explicit secret-shaped label; nothing here is a generic high-entropy-string heuristic (that
  would over-redact every record id the loop needs to keep referencing).

  ## Not reversible, and provably so

  Every matched span of every class collapses to the SAME fixed marker (`marker/0`), so `redact/1`
  is many-to-one exactly like `Ingress.sanitize/1`: two DIFFERENT secrets redact to byte-identical
  output, which is a collision, and a function with a collision has no inverse. It is also
  idempotent (the marker itself matches no vendor pattern and satisfies no labeled-secret shape),
  so a second pass changes nothing.

  ## `pii_*` masking is untouched

  This module never calls `Samen.Api.PiiResolution`, never reads `Samen.Pii.Info`, and is not
  invoked from `render_field/2`, `render_records/4`, or anywhere on the vault-resolution path —
  those are byte-unchanged by this item. The two lanes compose (a vault-routed field still masks
  to `••••` before it would ever reach `redact/1`) but neither can substitute for the other: a
  `pii_*` field with no declared secret shape still vault-masks; a secret-shaped string with no
  `pii_*` declaration still redacts here.

  ## Known residual (documented, not silently accepted)

  **Label/value adjacency noise — the NON-LANGUAGE class is CLOSED; four fragments remain STATED
  LIMITS (T14, UXD-14).** The generic labeled fallback used to require STRICT
  label/separator/value adjacency in the raw string, so an attacker who interleaved a comment span
  or zero-width/bidi characters between an unrecognized secret's label and its value (e.g.
  `token = /* leaked */ <value>`) could defeat pattern (2) — and `redact/1` runs before
  `Ingress.sanitize/1` would have collapsed that noise, precisely so it does not ALSO break
  vendor-prefix matching (which does not depend on adjacency to a label at all).

  The gap is no longer an enumerated vocabulary of "noise" characters. An enumeration is exactly
  what the next unlisted code point walks around: attempt 1 of this item enumerated twelve code
  points plus self-terminating comment spans and was then defeated by NBSP (U+00A0), the
  ideographic space (U+3000), an unterminated `/*`, an unterminated `<!--`, a backslash-newline
  continuation, and a comment body crossing a newline. The rule is now the COMPLEMENT of language,
  applied on BOTH sides of the separator: the gap is any run of characters that are **neither
  Unicode letters (`\p{L}`) nor Unicode numbers (`\p{N}`)**. That single rule covers every space
  variant (NBSP, ideographic, em, thin, narrow-nbsp, Ogham), every format/zero-width/bidi code
  point including ones Unicode has not assigned yet, every combining mark, every punctuation run,
  and a backslash-newline continuation — none of which is prose, so a sentence containing a long
  token still cannot be bridged. Applying it BEFORE the separator too is what finally redacts
  `{"api_key": "<value>"}`, the JSON object-key shape a tool result most often has, which no
  earlier version of this lane caught. A second, additive pattern bridges a recognized
  comment/annotation opener (`/*`, `<!--`, `<![CDATA[`, `//`, `#`, `--`) plus up to 200 following
  characters of ANY kind, so a comment defeats nothing whether or not it ever closes and whether or
  not its body crosses a newline. A KNOWN vendor-shaped secret is unaffected either way, because
  its signature is internal to the token, not a separate label.

  **The gaps are UNBOUNDED, and that is a correction.** Attempt 2 of this item capped both gaps at
  4096 characters to keep backtracking bounded, and the cap SUBTRACTED coverage the lane already
  had: the pre-T14 pattern spelled both gaps `\s*`, unbounded, so `password=<4097 spaces><value>`
  redacted before this item and stopped redacting under the cap — a labeled non-vendor secret
  leaking in cleartext for the price of pressing the space bar, which is the exact UXD-14 harm.
  Backtracking is now bounded STRUCTURALLY instead, at no cost in coverage: the label-to-separator
  gap is possessive over a class that excludes `:` and `=`, so it has exactly one way to match and
  never re-tries at a later separator, and the two gaps therefore no longer multiply. The result is
  both safer and faster — a 64KB colon flood cost 270ms under attempt 2's caps and costs 1.7ms
  without them. `secrets_test.exs`'s two "REGRESSION GUARD" tests fail if a length cap is ever
  re-introduced on either adjacent gap.

  **STATED LIMITS — four fragments this does NOT close.** Each is pinned by a test in
  `secrets_test.exs`'s "T14/UXD-14 STATED LIMIT" describe block, so deleting a disclosure here
  turns a test red rather than quietly widening the claim. **None of the four is a regression: every
  one of them was equally uncaught by the lane before this item.**

    1. **Anything that is a letter or a number.** The gap ends at the first `\p{L}`/`\p{N}`, so
       words between the separator and the value that no recognized comment opener introduces are
       not bridged — `auth_token = leaked <value>` passes through. Neither is a SINGLE letter or
       number of any script: `auth_token=<U+03A9><value>`, `<U+2160>` (a Roman numeral, `\p{Nl}`)
       and `<U+0660>` (an Arabic-Indic digit) each block the bridge on their own. Unrecognized
       comment syntaxes (`;`, `%`, `REM`, an HTML tag like `<b>x</b>`) are letters under this rule
       and belong here too. Bridging arbitrary letters is indistinguishable from the false positive
       this module refuses to pay for.
    2. **Noise INSIDE the value.** Splitting the value itself below the 12-character floor
       (`api_key=abcdefgh<ZWSP>ijklmnop`) still evades: a value class that tolerated embedded noise
       would tolerate embedded prose, which is fragment 1's false positive by another route.
    3. **More than 4096 non-language characters BEFORE a recognized comment opener.** The bound is
       on the BRIDGED pattern only — the one pattern whose gap multiplies by a second quantifier
       (fragment 4's 200-character budget). The adjacent pattern's gaps carry no bound at all.
    4. **More than 200 characters between a recognized comment opener and the value.**

  **The price, measured rather than estimated.** This rule is fail-closed and over-redacts in two
  named ways, both pinned by tests: prose that FOLLOWS a recognized opener can be redacted
  (`auth_token = /* set by the administrator later`, and the real-world shape
  `api_key: # see https://docs.example.com/getting-started`), because a value inside an unterminated
  comment is still a leaked value; and a label with an EMPTY value followed only by punctuation
  redacts the next 12-character token (`password:\n  - first-item-name`, and a comment divider
  under an empty key). Over 52 ordinary non-secret strings measured against the pre-T14 lane,
  **2 redact here that did not redact before this item** (both of them instances of the two costs
  just named, both now pinned at `secrets_test.exs:351` and `:358`), and 4 more redact at this
  commit AND at `c41e169` — `pwd` in
  ordinary shell output, an `.env.example` placeholder, a commented-out placeholder, and
  `api_key: System.get_env(...)` in Elixir source — which are the T184-era cost of the label
  vocabulary, not this item's. A false positive costs a reader one visible marker; a false negative
  here is a real credential leak.

  **Unlisted-label high-entropy blob — STATED LIMIT, not closed.** The fallback's label vocabulary
  (`@labeled_pattern` below) is a closed, bounded, reviewed list, deliberately not a generic
  high-entropy-string heuristic (see "What it catches" above). A value under a label OUTSIDE that
  list (e.g. `backup_blob=<base64 blob>`) is not redacted, by design: an entropy heuristic broad
  enough to catch an arbitrary-labeled blob would also flag ordinary record ids, hashes, and other
  high-entropy-but-non-secret business data the loop needs to keep referencing verbatim — the same
  false-positive cost this module already refuses to pay for the listed labels. Closing this needs
  either a deliberately reviewed, still-bounded label-vocabulary expansion or a genuinely new
  detector class, never a widening of THIS regex into free-form entropy scanning. Pinned by
  `secrets_test.exs`'s "DOCUMENTED LIMIT" test so this stays a fact, not just a sentence.
  """

  # One marker for EVERY redacted span of EVERY class — the same discipline as
  # `Samen.AI.Agent.Ingress.marker/0`: sharing it makes the transform many-to-one, therefore not
  # invertible (see moduledoc). Deliberately distinct text from `Ingress.marker/0` so a reader
  # (human or verifier) can tell WHICH lane fired without inspecting the source.
  @marker "[redacted:secret]"

  # Known vendor-shaped prefixes. Bounded and explicit, like `Ingress`'s `@instruction_patterns` —
  # a false positive costs a reader a visible marker; a false negative here is a real credential
  # leak, so this list is reviewed, not generated.
  @vendor_patterns [
    # AWS access key id / STS temporary session key id.
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    # GitHub tokens: classic (ghp_/gho_/ghu_/ghs_/ghr_) and fine-grained (github_pat_).
    ~r/\bgh[opus]_[A-Za-z0-9]{36,255}\b/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{22,255}\b/,
    # Slack tokens (bot/app/user/config/refresh).
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
    # Payment-processor-style live/restricted secret & publishable keys (`sk_live_`/`pk_live_`/
    # `rk_live_`; test-mode keys are still credential-shaped, so `_test_` is caught too).
    ~r/\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b/,
    # Generic `sk-` bearer-style secret keys (the shape several hosted LLM/API vendors use).
    ~r/\bsk-[A-Za-z0-9]{20,}\b/,
    # npm publish tokens.
    ~r/\bnpm_[A-Za-z0-9]{36}\b/,
    # Google API keys.
    ~r/\bAIza[0-9A-Za-z_-]{35}\b/,
    # PEM private-key headers — the header alone is enough to flag the block as key material.
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    # JWTs: three base64url segments joined by dots, each long enough not to be a stray word.
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
    # Authorization: Bearer <token>.
    ~r/\bBearer\s+[A-Za-z0-9\-_.]{20,}/,
    # Connection strings carrying an embedded user:pass@host credential.
    ~r{\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s"'<>]+:[^\s"'<>@]+@[^\s"'<>]+}
  ]

  # The fail-closed generic fallback: a secret-shaped LABEL assigned a non-trivial value, whether
  # or not the value matches a known vendor format above. The WHOLE match collapses to the marker
  # (the label is deliberately not preserved) to match `Ingress`'s whole-match-to-marker style and
  # to keep a model-influenced label from ever being echoed back as content.
  #
  # T14 (UXD-14): the gap between the separator and the value is a COMPLEMENT, not a vocabulary.
  # Attempt 1 of this item bounded the gap to an enumerated list of code points plus
  # self-terminating comment spans, and a verifier walked around it with NBSP (U+00A0), the
  # ideographic space (U+3000), an unterminated `/*`, an unterminated `<!--`, a backslash-newline
  # continuation, and a comment body crossing a newline (the enumerated `/\*.*?\*/` had no DOTALL).
  # An enumeration always has a next evasion, so the rule is stated negatively instead: the gap is
  # any run of characters that are NEITHER a Unicode letter (\p{L}) NOR a Unicode number (\p{N}).
  # Nothing in that class is prose, which is what keeps the false-positive floor: a recognized
  # label inside a sentence cannot reach a long token further along the sentence, because the
  # sentence's own letters end the gap.
  #
  # `@bridged_pattern_*` is the second, strictly additive pattern: the same label and the same
  # non-language gap, then a recognized comment/annotation OPENER, then up to 200 characters of ANY
  # kind before the value. It never requires the comment to close, so terminated, unterminated and
  # newline-crossing comment bodies are one case rather than three. Prose that is NOT introduced by
  # an opener is the documented residual — see the moduledoc's "What remains open".
  #
  # Both patterns exist in two spellings. `\p{L}`/`\p{N}` need PCRE's Unicode mode, and a
  # Unicode-mode `:re` RAISES `ArgumentError` on a binary that is not valid UTF-8 — which would
  # break `redact/1`'s "total on binaries, never raises" contract (the exact regression
  # `secrets_test.exs`'s "does not raise" test exists to catch). So the Unicode spelling runs on
  # valid UTF-8 and a byte-mode spelling runs otherwise; the byte spelling's `[^A-Za-z0-9]` treats
  # every non-ASCII byte as non-language, so the invalid-UTF-8 path is strictly MORE redacting,
  # never less — an attacker cannot buy leniency by corrupting the encoding.
  @label_vocabulary "(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret[_-]?key|" <>
                      "client[_-]?secret|private[_-]?key|password|passwd|pwd)\\b"

  @value_shape "[\"']?[A-Za-z0-9+/_.\\-!@#$%^&*]{12,}[\"']?"

  @comment_opener "(?:/\\*|<!--|<!\\[CDATA\\[|//|\\#|--)"

  # Bounded, and the bound is a reviewed number, not a guess: a comment long enough to push its own
  # payload past 200 characters is disclosed as part of the prose-bridging residual above.
  @bridge_budget "[\\s\\S]{0,200}?"

  # The separator-to-value gap is UNBOUNDED, deliberately, and the reason is a regression this item
  # had to undo. Attempt 2 of T14 capped both gaps at 4096 characters to keep backtracking bounded,
  # and that cap SUBTRACTED coverage the lane already had: the pre-T14 pattern spelled both gaps
  # `\s*`, unbounded, so `password=<4097 spaces><non-vendor secret>` redacted before this item and
  # stopped redacting under the cap — a labeled secret leaking in cleartext at trivial attacker
  # cost, which is the exact UXD-14 harm. Backtracking is bounded STRUCTURALLY here instead, at no
  # cost in coverage. The quadratic blow-up the cap was defending against was the PRODUCT of the two
  # gaps (a lazy label-to-separator gap re-trying at every later separator, each retry driving a
  # greedy separator-to-value gap); `@label_prefix_*` below removes the product by being possessive
  # over a class that EXCLUDES `:` and `=`, so it has exactly one way to match and never re-tries.
  # What is left is a single greedy repeat of one character class, linear in the gap's length.
  @noise_gap_unicode "[^\\p{L}\\p{N}]*"
  @noise_gap_bytes "[^A-Za-z0-9]*"

  # The BRIDGED pattern's leading gap keeps a 4096 bound, because the bridge is the one place a
  # product survives: its gap multiplies by the 200-character `@bridge_budget` below it. That bound
  # subtracts NOTHING — no version of this lane before T14 bridged a comment opener at all, so it
  # bounds new coverage (moduledoc fragment 3) rather than removing old coverage.
  @bridge_gap_unicode "[^\\p{L}\\p{N}]{0,4096}"
  @bridge_gap_bytes "[^A-Za-z0-9]{0,4096}"

  # The SAME non-language rule applies on BOTH sides of the separator. Before T14 the separator had
  # to follow the label across `\s*` only, so `{"api_key": "<value>"}` — a JSON object key, i.e.
  # the single most common shape a tool result actually has — was never redacted at all, because a
  # quote character sat between the label and the `:`. POSSESSIVE over a class that excludes `:` and
  # `=`: there is exactly one way to match it (up to the nearest separator reachable through
  # non-language characters), which is the same span the lazy spelling found, minus the retries. The
  # gap after the separator can itself cross a `:`/`=`, so locking onto the nearest one loses no
  # match — it only removes the backtracking that forced attempt 2 to cap the gaps.
  @label_prefix_unicode @label_vocabulary <> "[^\\p{L}\\p{N}:=]*+[:=]"
  @label_prefix_bytes @label_vocabulary <> "[^A-Za-z0-9:=]*+[:=]"

  @labeled_pattern_unicode Regex.compile!(
                             @label_prefix_unicode <> @noise_gap_unicode <> @value_shape,
                             "iu"
                           )

  @labeled_pattern_bytes Regex.compile!(
                           @label_prefix_bytes <> @noise_gap_bytes <> @value_shape,
                           "i"
                         )

  @bridged_pattern_unicode Regex.compile!(
                             @label_prefix_unicode <>
                               @bridge_gap_unicode <>
                               @comment_opener <> @bridge_budget <> @value_shape,
                             "iu"
                           )

  @bridged_pattern_bytes Regex.compile!(
                           @label_prefix_bytes <>
                             @bridge_gap_bytes <>
                             @comment_opener <> @bridge_budget <> @value_shape,
                           "i"
                         )

  @doc """
  The redacted projection of one untrusted binary, safe to store as a `:history` line.

  Total on binaries and never raises. Runs the vendor-pattern pass first, then the generic
  labeled-fallback pass over what remains — a value already redacted by (1) cannot ALSO match
  (2), since the marker itself is neither vendor-shaped nor label-adjacent.
  """
  @spec redact(binary()) :: binary()
  def redact(value) when is_binary(value) do
    value
    |> redact_vendor_patterns()
    |> redact_labeled_fallback()
  end

  @doc "The marker every redacted span collapses to. Exposed so tests assert one constant."
  @spec marker() :: binary()
  def marker, do: @marker

  defp redact_vendor_patterns(text) do
    Enum.reduce(@vendor_patterns, text, &Regex.replace(&1, &2, @marker))
  end

  defp redact_labeled_fallback(text) do
    {adjacent, bridged} =
      if String.valid?(text) do
        {@labeled_pattern_unicode, @bridged_pattern_unicode}
      else
        {@labeled_pattern_bytes, @bridged_pattern_bytes}
      end

    text
    |> then(&Regex.replace(adjacent, &1, @marker))
    |> then(&Regex.replace(bridged, &1, @marker))
  end
end
