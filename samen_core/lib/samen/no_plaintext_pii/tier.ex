defmodule Samen.NoPlaintextPii.Tier do
  @moduledoc """
  The extensible tier behaviour for the `no_plaintext_pii` verifier (C5).

  The destruction oracle (doc §runs oracle block) asserts the
  **token-only-downstream** invariant across every *projected tier* — CDC mirror,
  rollups, matviews, app-log sink, `aud_event`, trace/event sink schema — plus the
  KMS/config posture. The full post-shred oracle (`--subject --tiers all`) is
  Phase 2 (T2.9). This module is the **CI-mode** foundation: it defines the tier
  contract so Phase 2 can add `cdc_mirror` / `rollup` / `trace_sink` tiers by
  writing new tier modules and registering them — WITHOUT touching the harness.

  ## The contract

  A tier is a module implementing:

    * `tier_name/0` — a short atom name for diagnostics + the registry key
      (e.g. `:vault_declarations`, `:audit_rows`, `:catalog`, `:log_telemetry`).

    * `mode/0` — `:ci` (asserted in the CI-mode invariant that runs today) or
      `:post_shred` (only meaningful with a subject + live shred state — Phase 2).
      CI mode runs ONLY `:ci` tiers; a `:post_shred` tier registered today is
      inert until the T2.9 oracle drives it.

    * `check/1` — takes the shared `Samen.NoPlaintextPii.Context` and returns a
      list of `Samen.NoPlaintextPii.Finding` structs. An empty list = the tier is
      clean. A tier NEVER raises for an expected "violation" — it returns a
      finding so the harness can aggregate and fail closed once, with all
      diagnostics.

    * `describe/0` — one-line human description for the pass banner.

  ## Fail-closed discipline

  A tier that cannot introspect what it needs (missing repo, uncompiled schema)
  MUST return a finding (fail closed), NOT silently pass. "I couldn't check" is a
  violation, not an all-clear — the whole point of the oracle is that absence of
  evidence is not evidence of absence.

  ## Exemptions (doc D8)

  Registered `non_pii!` columns are plaintext-at-rest by design. A tier that scans
  physical columns for plaintext PII types must consult
  `Samen.NoPlaintextPii.Context.non_pii_exempt?/3` and, instead of flagging an
  exempt column, emit an `:exempt` finding so the harness LISTS it in output (the
  T1.8d "exempt-but-listed" clause) without failing the build.
  """

  @doc "The registry key + diagnostic name for this tier."
  @callback tier_name() :: atom()

  @doc "`:ci` (asserted now) or `:post_shred` (Phase 2 T2.9, inert in CI mode)."
  @callback mode() :: :ci | :post_shred

  @doc "One-line human description for the pass banner."
  @callback describe() :: String.t()

  @doc "Run the tier's checks; return findings (empty = clean)."
  @callback check(Samen.NoPlaintextPii.Context.t()) :: [Samen.NoPlaintextPii.Finding.t()]
end

defmodule Samen.NoPlaintextPii.Finding do
  @moduledoc """
  One result from a tier check (`Samen.NoPlaintextPii.Tier.check/1`).

  `severity`:
    * `:violation` — fails the build (the token-only invariant is broken here).
    * `:exempt`    — a registered `non_pii!` plaintext column: listed in output,
      does NOT fail the build (doc D8; T1.8d clause (d)).

  `tier` names the emitting tier; `subject` names the offending item (a
  `table.column`, a config key, …); `detail` is the human explanation.
  """
  @enforce_keys [:tier, :severity, :subject, :detail]
  defstruct [:tier, :severity, :subject, :detail]

  @type severity :: :violation | :exempt

  @type t :: %__MODULE__{
          tier: atom(),
          severity: severity(),
          subject: String.t(),
          detail: String.t()
        }

  @doc "Build a `:violation` finding."
  @spec violation(atom(), String.t(), String.t()) :: t()
  def violation(tier, subject, detail),
    do: %__MODULE__{tier: tier, severity: :violation, subject: subject, detail: detail}

  @doc "Build an `:exempt` finding (listed, not failed)."
  @spec exempt(atom(), String.t(), String.t()) :: t()
  def exempt(tier, subject, detail),
    do: %__MODULE__{tier: tier, severity: :exempt, subject: subject, detail: detail}

  @doc "Format a finding for human output."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{severity: :exempt} = f),
    do: "[#{f.tier}] EXEMPT (non_pii!): #{f.subject} — #{f.detail}"

  def format(%__MODULE__{} = f),
    do: "[#{f.tier}] #{f.subject} — #{f.detail}"
end
