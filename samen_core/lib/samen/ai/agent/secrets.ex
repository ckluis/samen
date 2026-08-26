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

  The generic labeled fallback requires label/separator/value adjacency in the RAW string. An
  attacker who interleaves zero-width or bidi characters between an unrecognized secret's label
  and its value could defeat pattern (2) — the noise breaks the adjacency the regex needs, and
  `redact/1` runs before `Ingress.sanitize/1` would have collapsed that noise to one marker,
  precisely so it does not ALSO break vendor-prefix matching (which does not depend on adjacency
  to a label at all). A KNOWN vendor-shaped secret cannot be evaded this way, because its
  signature is internal to the token itself, not a separate label. This is a narrower residual
  than doing nothing, and it is the honest trade against silently breaking the fallback on
  ordinary tenant text that happens to contain the word "key" or "secret" near an unrelated value.
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
  # or not the value matches a known vendor format above. `label` and `sep` are captured so the
  # replacement can (optionally) keep the label readable — deliberately NOT kept, to match
  # `Ingress`'s whole-match-to-marker style and avoid the label itself ever being adversarial
  # content (a model-influenced label reading "password" next to unrelated text still redacts,
  # which is the fail-closed reading: a false positive costs a visible marker).
  @labeled_pattern ~r/(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret[_-]?key|client[_-]?secret|private[_-]?key|password|passwd|pwd)\b\s*[:=]\s*["']?[A-Za-z0-9+\/_.\-!@#$%^&*]{12,}["']?/i

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

  defp redact_labeled_fallback(text), do: Regex.replace(@labeled_pattern, text, @marker)
end
