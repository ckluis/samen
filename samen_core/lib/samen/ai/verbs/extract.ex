defmodule Samen.AI.Verbs.Extract do
  @moduledoc """
  The Extract intelligence verb (ADR-043 §7.5, T68) — pulls structured fields out of
  `input`. Pass `params: %{fields: "..."}` to name the fields the built-in default template
  extracts. Routes through `Samen.AI.Verbs.run/4` → `Samen.AI.complete/4` →
  `Samen.AI.Chokepoint` (the ONE egress chokepoint; see `Samen.AI.Verbs` moduledoc). Never
  touches a provider or a `%Samen.AI.MaskedPayload{}` directly.
  """

  @doc "See `Samen.AI.Verbs.run/4` for `opts` (`:prompt`, `:params`, `:bindings`, ...)."
  @spec run(term(), term(), keyword()) :: {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def run(scope, input, opts \\ []), do: Samen.AI.Verbs.run(:extract, scope, input, opts)
end
