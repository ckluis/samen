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
  """

  @enforce_keys [:text]
  defstruct text: nil, model: nil, provider: nil, usage: %{}, meta: %{}, simulated: false

  @type t :: %__MODULE__{
          text: String.t(),
          model: String.t() | nil,
          provider: atom() | nil,
          usage: map(),
          meta: map(),
          simulated: boolean()
        }
end
