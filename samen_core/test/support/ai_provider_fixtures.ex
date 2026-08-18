defmodule NoSimulatedCallbackProvider do
  @moduledoc """
  T78 (spec §I5) test fixture — a `Samen.AI.Provider` that OMITS the optional
  `simulated?/0` callback (ADR-043 §5.1, T152). Proves `Samen.AI.Embeddings.
  embedder_simulated?/1`'s fail-honest default: a provider that never declares
  itself simulated is treated as LIVE (`false`), never guessed at.
  """
  @behaviour Samen.AI.Provider

  alias Samen.AI.MaskedPayload

  @impl true
  def complete(%MaskedPayload{}, _config), do: {:error, :not_implemented}

  @impl true
  def embed(%MaskedPayload{}, _config), do: {:error, :not_implemented}
end

defmodule RaisingSimulatedProvider do
  @moduledoc """
  T78 (spec §I5) test fixture — a `Samen.AI.Provider` whose `simulated?/0` RAISES.
  Proves `Samen.AI.Embeddings.embedder_simulated?/1`'s belt: a misbehaving
  provider can never crash the caller, degrading to `false` (live) instead —
  never a fabricated `true`, never a raise reaching a KB-suggestion panel.
  """
  @behaviour Samen.AI.Provider

  alias Samen.AI.MaskedPayload

  @impl true
  def complete(%MaskedPayload{}, _config), do: {:error, :not_implemented}

  @impl true
  def embed(%MaskedPayload{}, _config), do: {:error, :not_implemented}

  @impl true
  def simulated?, do: raise("boom — a misbehaving provider's simulated?/0")
end
