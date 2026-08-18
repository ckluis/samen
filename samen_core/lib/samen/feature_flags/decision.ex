defmodule Samen.FeatureFlags.Decision do
  @moduledoc """
  The result of `Samen.FeatureFlags.evaluate/2` — a bounded, non-PII struct
  describing whether a flag is ON for a subject and WHY (ADR-020 §2, design G6 §3.2).

  ## Fields

    * `:on` — the gate value the caller acts on (`true`/`false`).
    * `:variant` — the assigned variant name (an atom) when the flag is
      multivariate and ON; `nil` for a plain on/off flag.
    * `:reason` — the precedence branch that decided the outcome. One of:
        * `:kill_switch`  — `enabled == false`; the incident lever short-circuited
          everything (fail-SAFE: also the reason returned when the engine cannot
          confirm a flag is ON — a cache/lookup error, an unknown flag).
        * `:disabled`     — the flag exists but is not enabled (alias kept distinct
          from `:kill_switch` only where a caller wants it; the engine uses
          `:kill_switch` for `enabled == false`).
        * `:deny`         — an explicit deny rule matched (highest targeting priority).
        * `:allow`        — an explicit allow rule matched.
        * `:targeted`     — a targeting rule matched (org/plan/tier/stage — non-PII).
        * `:rollout_in`   — inside the deterministic percentage bucket.
        * `:rollout_out`  — outside the bucket (OFF).
        * `:default`      — no rule/rollout applied; the flag's default gate.

  ## Fleet-composed reasons (ADR-044 §7.3, `Samen.Fleet.Directive.Precedence`)

  `Samen.Fleet.Directive.Precedence.decide/3` returns a `Decision` too, composing
  a LOCAL config with a fleet directive — it adds these reasons, which never
  appear from a plain `Samen.FeatureFlags.evaluate/2` call:

        * `:local_off`         — a local off-state (kill / explicit deny / a local
          `then: "off"` targeting match / `rollout_pct <= 0`) — fleet was NOT
          consulted (§7.3's one-way OFF authority).
        * `:fleet_kill`        — no local off-state, but the fleet directive's
          `kill: true` short-circuited OFF.
        * `:fleet_deny`/`:fleet_allow`/`:fleet_targeted` — a FLEET targeting rule
          (not a local one) decided the outcome.
        * `:fleet_rollout_in`/`:fleet_rollout_out` — the FLEET percentage bucket
          decided the outcome.

  Every field is bounded and non-PII by construction: `variant` is a config-defined
  atom, `reason` is a fixed enum, `on` is a boolean. A `Decision` is safe to log as
  a metric.
  """

  @type reason ::
          :kill_switch
          | :disabled
          | :deny
          | :allow
          | :targeted
          | :rollout_in
          | :rollout_out
          | :default
          | :local_off
          | :fleet_kill
          | :fleet_deny
          | :fleet_allow
          | :fleet_targeted
          | :fleet_rollout_in
          | :fleet_rollout_out

  @type t :: %__MODULE__{
          on: boolean(),
          variant: atom() | nil,
          reason: reason()
        }

  @enforce_keys [:on, :reason]
  defstruct on: false, variant: nil, reason: :default

  @doc "The fail-SAFE decision: OFF for a flag the engine cannot confirm ON."
  @spec off(reason()) :: t()
  def off(reason \\ :kill_switch), do: %__MODULE__{on: false, variant: nil, reason: reason}
end
