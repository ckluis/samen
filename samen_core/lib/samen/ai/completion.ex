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
  """

  @enforce_keys [:text]
  defstruct text: nil, model: nil, provider: nil, usage: %{}, meta: %{}

  @type t :: %__MODULE__{
          text: String.t(),
          model: String.t() | nil,
          provider: atom() | nil,
          usage: map(),
          meta: map()
        }
end
