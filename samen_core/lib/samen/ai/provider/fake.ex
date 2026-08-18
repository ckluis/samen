defmodule Samen.AI.Provider.Fake do
  @moduledoc """
  The core, call-recording AI test double (ADR-043 §4; M9 keyless CI). The
  `Samen.Delivery.FakeProvider` / `Samen.Delivery.LocalSink` honest-capture analog for the
  AI plane: it is the provider an UNWIRED `Samen.AI` call resolves to in `:test`
  (`Samen.AI.provider_for/2`), and the double every downstream WS-D task + the T72 red-team
  runs against — with ZERO API keys and ZERO live calls (§4).

  ## Deterministic (same input ⇒ same output)

  `complete/2` returns a `%Samen.AI.Completion{}` whose `:text` is a pure function of the
  sealed payload segments + an optional `config[:seed]` — so a fixture asserting on output
  is stable across runs. No model cognition (that is the `SAMEN_AI_LIVE=1` lane); the Fake
  proves the CHOKEPOINT + assembly path, provider-independently.

  ## Recording (a leak = the canary appears in the recording)

  Every `MaskedPayload` the Fake is SENT is recorded (process-local, the
  `Samen.Delivery.FakeProvider` idiom). T72's red-team inspects `sent_payloads/0` for canary
  plaintext / `vt_*` tokens: if a leak reaches the provider boundary, it is in the recording.

  ## By-construction refusal + fail-honest

  Both callbacks pattern-match `%Samen.AI.MaskedPayload{}` in the head — a raw string/map
  refuses by `FunctionClauseError`, exactly like a real adapter (the by-construction gate
  holds even for the CI double). The Fake is the test lane, so it does not gate on an API
  key; a scriptable `config[:error]` lets a test force the fail-honest / EG6 error paths
  (`Samen.AI.Chokepoint` normalizes whatever the Fake returns).
  """

  @behaviour Samen.AI.Provider

  alias Samen.AI.{Completion, MaskedPayload}

  @impl Samen.AI.Provider
  def complete(%MaskedPayload{} = payload, config) when is_map(config) do
    record(:complete, payload)

    case Map.get(config, :error) do
      nil ->
        {:ok,
         %Completion{
           text: deterministic_text(payload, config),
           model: Map.get(config, :model, "fake-deterministic-1"),
           provider: :fake,
           usage: %{input_segments: length(payload.segments)},
           meta: %{seed: Map.get(config, :seed, 0)}
         }}

      err ->
        {:error, err}
    end
  end

  @impl Samen.AI.Provider
  def simulated?, do: true

  @impl Samen.AI.Provider
  def embed(%MaskedPayload{} = payload, config) when is_map(config) do
    record(:embed, payload)

    case Map.get(config, :error) do
      nil -> {:ok, Enum.map(payload.segments, &deterministic_vector(&1, config))}
      err -> {:error, err}
    end
  end

  # --- deterministic output --------------------------------------------------------------

  # Field-less match + dot access on purpose (the single-mint probe convention: only the
  # chokepoint uses a field-BEARING %MaskedPayload{...} literal).
  defp deterministic_text(%MaskedPayload{} = payload, config) do
    seed = Map.get(config, :seed, 0)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({payload.segments, seed}))
      |> Base.encode16(case: :lower)

    "fake-completion:" <> binary_part(digest, 0, 16)
  end

  # A stable token-projection to a small fixed dimension. No semantic quality (T67 ships the
  # real Samen.AI.Embedder.Deterministic); enough for chokepoint/recording tests.
  @dim 8
  defp deterministic_vector(segment, config) do
    seed = Map.get(config, :seed, 0)

    :crypto.hash(:sha256, :erlang.term_to_binary({segment, seed}))
    |> :binary.bin_to_list()
    |> Enum.take(@dim)
    |> Enum.map(&(&1 / 255))
  end

  # --- recording (process-local, the Samen.Delivery.FakeProvider idiom) ------------------

  @key :samen_ai_fake_sent_payloads

  defp record(callback, %MaskedPayload{} = payload) do
    Process.put(@key, [{callback, payload} | Process.get(@key, [])])
  end

  @doc "All `{callback, %MaskedPayload{}}` tuples the Fake was sent this process, newest first."
  @spec sent_payloads() :: [{atom(), MaskedPayload.t()}]
  def sent_payloads, do: Process.get(@key, [])

  @doc "Clear the recorded payloads for the current process."
  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
    :ok
  end
end
