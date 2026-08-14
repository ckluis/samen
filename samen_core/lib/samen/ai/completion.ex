defmodule Samen.AI.Completion do
  @moduledoc """
  `%Samen.AI.Completion{}` — the normalized result of a `Samen.AI.Provider.complete/2`
  call (ADR-043 §5.1). Provider-agnostic: the reference adapter package,
  `Samen.AI.Provider.Fake`, and any future adapter return this same shape so the kernel +
  verbs (T68) are provider-blind.

  The `Completion` carries MODEL OUTPUT (not vault-routed input) — it is not itself a
  masked value. `:model` / `:provider` / `:usage` are bounded metadata; `:text` is the
  generated completion. (ADR-043 defers the exact field list to T64; these are the core
  four — downstream tasks may extend by adding fields, never removing.)

  ## `:simulated` — the first-class "this is not a real model" flag (T152)

  `:simulated` is `true` when the completion was produced by a keyless/deterministic
  provider (`Samen.AI.Provider.Fake` in the CI lane, `Samen.AI.Embedder.Deterministic`)
  and `false` when a live provider genuinely produced it. It is set **by construction**
  at the ONE provider-invocation site (`Samen.AI.Chokepoint`), which stamps it from the
  dispatched provider (a provider self-declares via the optional `simulated?/0`
  callback — see `Samen.AI.Provider`) — never from the completion `:text`. This gives a
  UI an honest, machine-readable "simulated" badge instead of parsing the legacy
  `"fake-completion:"` text prefix (which is preserved — nothing that reads it breaks).
  The struct default is `false` (a completion is not simulated unless the kernel proves
  the provider is), the fail-honest posture: never claim a keyless output is real, and
  never silently mark a live output simulated.

  ## `:tool_calls` — native provider tool selection (ADR-047 §5.2, batch A3)

  An adapter that supports native (vendor-side) tool use maps the vendor response into
  this bounded field — a list of `%{"name" => kind, "args" => map}` entries; an adapter
  that does not leaves it `[]` (the default) and the agent loop falls back to parsing
  the bounded `TOOL:` JSON envelope out of `:text` (`Samen.AI.Agent.parse_next/1`).
  The field is provider **ingress**, so INV-7 does not govern its arrival — but its
  contents are UNTRUSTED MODEL OUTPUT that becomes EG2 egress on the next turn's echo
  (ADR-047 §4.3#6): the loop validates args through the action's own `validate/2`,
  refuses any `vt_` sentinel before execution, and re-enters only renderer-produced
  binaries. (Adding this field is in-contract: ADR-043 §11 deferred the exact
  `Completion` field list — extend by adding, never removing.)
  """

  @enforce_keys [:text]
  defstruct text: nil,
            model: nil,
            provider: nil,
            usage: %{},
            meta: %{},
            simulated: false,
            tool_calls: []

  @type t :: %__MODULE__{
          text: String.t(),
          model: String.t() | nil,
          provider: atom() | nil,
          usage: map(),
          meta: map(),
          simulated: boolean(),
          tool_calls: [map()]
        }
end
