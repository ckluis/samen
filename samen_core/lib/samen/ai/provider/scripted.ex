defmodule Samen.AI.Provider.Scripted do
  @moduledoc """
  `Samen.AI.Provider.Scripted` — the deterministic, TURN-SCRIPTED agent-loop test double
  (ADR-047 batches A1+A2; the multi-turn sibling of `Samen.AI.Provider.Fake`).

  Where `Provider.Fake` answers every call with one hash-derived text, an agent-loop test
  needs a provider that answers call 1, call 2, … call N with SCRIPTED, distinct turns —
  so the loop's dynamic next-step selection (continue vs. `FINAL:`), budget accounting
  (per-turn `usage`), and error paths are all drivable keylessly and deterministically.

  ## Scripting

      Scripted.script([
        continue: "looking at the shipment",
        continue: "checking the carrier",
        final: "the carrier missed the pickup window"
      ])

  Entry forms (consumed strictly in order, one per `complete/2` call):

    * `{:continue, text}` — an intermediate assistant turn (`FINAL:`-free by shape);
    * `{:final, text}` — a goal-met turn (`"FINAL: " <> text`);
    * `{:error, reason}` — a scripted provider failure (the chokepoint EG6-normalizes it);
    * `%{text: ..., usage: %{input_tokens: _, output_tokens: _}}` — full control (token
      budgets); `{:continue | :final, text, usage}` is sugar for the same;
    * a zero-arity fun returning any of the above, evaluated AT CALL TIME — the seam a
      test uses to act *between* turns (issue a durable `Samen.AI.Agent.cancel/2`, flip
      the `Samen.AI.Agent.Breaker` kill-switch, or `exit/1` to simulate a worker death
      mid-turn — the A2 restart-safety proof).

  ## The cross-process seam (A2 — flagged by A1, required by the Oban worker)

  The script and the recording live in `:persistent_term`, NOT the process dictionary:
  A2's `Samen.AI.Agent.TurnWorker` executes turns in whatever process runs the job (an
  Oban drain, a watchdog replay, a spawned crash-simulation Task), and a process-local
  script would make the worker path fail `{:error, :not_configured}` dishonestly-honest
  — scripted work the double could not see. Global state means this double is a
  ONE-RUNNER-AT-A-TIME seam: agent suites run `async: false` and `reset/0` in setup.
  The fail-honest floor is unchanged either way (below).

  ## Fail-honest (ADR-014/024/026 — the contract this double must also honor)

  **No script (or an exhausted script) NEVER returns `{:ok, _}`** — it returns
  `{:error, :not_configured}`, exactly like an unconfigured real adapter: work that was
  not scripted is work not done, and a canned success here is the lie the sabotage
  harness exists to catch. `embed/2` is honestly `{:error, :not_implemented}` (this
  double scripts turns, not vectors).

  ## By-construction refusal + recording

  Both callbacks head-match `%Samen.AI.MaskedPayload{}` (field-LESS match + dot access —
  the single-mint probe convention), so a raw string/map refuses by `FunctionClauseError`
  like every adapter. Every payload RECEIVED is recorded (`sent_payloads/0`, newest
  first) — the A1/A2 history-accumulation/re-scrub assertions read the recording exactly
  as the T72 red-team reads the Fake's. `simulated?/0` is `true`: every completion is
  stamped `simulated: true` by the chokepoint's dispatch site (T152), never parsed from
  text.
  """

  @behaviour Samen.AI.Provider

  alias Samen.AI.{Completion, MaskedPayload}

  @script_key {__MODULE__, :script}
  @sent_key {__MODULE__, :sent_payloads}

  @impl Samen.AI.Provider
  def complete(%MaskedPayload{} = payload, config) when is_map(config) do
    record(:complete, payload)

    case next_entry() do
      # Fail-honest: nothing (left) scripted = no work done. NEVER a canned {:ok, _}.
      :exhausted -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
      %{text: text} = entry -> {:ok, completion(text, Map.get(entry, :usage, %{}))}
    end
  end

  @impl Samen.AI.Provider
  def embed(%MaskedPayload{} = payload, config) when is_map(config) do
    record(:embed, payload)
    {:error, :not_implemented}
  end

  @impl Samen.AI.Provider
  def simulated?, do: true

  # --- scripting -------------------------------------------------------------------------

  @doc """
  Set the turn script (replacing any previous one). Entries are consumed in order, one
  per `complete/2` call, from WHICHEVER process dispatches (the A2 cross-process seam);
  see the moduledoc for entry forms.
  """
  @spec script([term()]) :: :ok
  def script(entries) when is_list(entries) do
    :persistent_term.put(@script_key, entries)
    :ok
  end

  @doc "Entries not yet consumed (a fully-consumed script returns `[]`)."
  @spec remaining() :: [term()]
  def remaining, do: :persistent_term.get(@script_key, [])

  defp next_entry do
    case :persistent_term.get(@script_key, []) do
      [] ->
        :exhausted

      [entry | rest] ->
        :persistent_term.put(@script_key, rest)
        normalize(entry)
    end
  end

  # A fun entry is evaluated AT CALL TIME (the between-turns test seam), then normalized
  # like any literal entry.
  defp normalize(fun) when is_function(fun, 0), do: normalize(fun.())
  defp normalize({:continue, text}) when is_binary(text), do: %{text: text}
  defp normalize({:continue, text, usage}) when is_binary(text), do: %{text: text, usage: usage}
  defp normalize({:final, text}) when is_binary(text), do: %{text: "FINAL: " <> text}

  defp normalize({:final, text, usage}) when is_binary(text),
    do: %{text: "FINAL: " <> text, usage: usage}

  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(%{text: text} = entry) when is_binary(text), do: entry

  # A malformed entry is a test-authoring bug: refuse honestly (the unconfigured shape),
  # never guess a completion into existence.
  defp normalize(_other), do: {:error, :not_configured}

  defp completion(text, usage) do
    %Completion{
      text: text,
      model: "scripted-1",
      provider: :scripted,
      usage: usage
    }
  end

  # --- recording (persistent_term — cross-process, the A2 worker seam) --------------------

  defp record(callback, %MaskedPayload{} = payload) do
    :persistent_term.put(@sent_key, [{callback, payload} | :persistent_term.get(@sent_key, [])])
  end

  @doc "All `{callback, %MaskedPayload{}}` tuples the double received, newest first."
  @spec sent_payloads() :: [{atom(), MaskedPayload.t()}]
  def sent_payloads, do: :persistent_term.get(@sent_key, [])

  @doc "Clear the script AND the recording (every process sees the cleared state)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@script_key)
    :persistent_term.erase(@sent_key)
    :ok
  end
end
