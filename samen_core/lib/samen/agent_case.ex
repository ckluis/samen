defmodule Samen.AgentCase do
  @moduledoc """
  Agent-loop proof helpers (ADR-047 §3#8, batch A1) — the `Samen.MaskingCase` /
  `Samen.RedPath` sibling for the agent plane: test infra shipped in `lib` so hosts and
  verticals write the SAME non-vacuous proofs (`use Samen.AgentCase`).

  ## The agent-loop proof discipline (anti-tautology, per ADR-047 A1)

  Every agent red assertion ships with its positive control:

    * **budget honesty** — an exhausted run returns `{:error, :budget_exhausted, run}`,
      run terminal `:budget_exhausted`, and the last assistant turn is NOT promoted
      (`assert_honest_exhaustion!/1`); the POSITIVE control is the same script under a
      sufficient budget succeeding with the real `FINAL:` answer — proving the assertion
      could fail (RP-AG-6).
    * **no text at rest** — no persisted run/turn column carries any prompt/completion
      text (`assert_no_text_at_rest!/2` scans EVERY attribute of EVERY persisted row for
      the canaries); the control is asserting the canaries DID reach the provider
      recording (`sent_texts/0`), so absence-at-rest is a property, not a no-op.
    * **history re-scrub engaged** — the recorded payload of turn N carries the prior
      turns' lines (`assert_history_accumulated!/2`), all segments are plain binaries
      with no `{:grant_span, …}` tag ever passed (`assert_masked_only_payloads!/0`,
      RP-AG-3's asserted property), and a `vt_*`-poisoned line REFUSES fail-closed
      (the red leg lives in the A1 suite).

  ## Usage

      use Samen.AgentCase

      script(continue: "step one", final: "done")
      {:ok, %{answer: "done", run: run}} = run_scripted(MyAgent, scope, "goal")
  """

  import ExUnit.Assertions

  alias Samen.AI.Agent
  alias Samen.AI.Agent.Turn
  alias Samen.AI.MaskedPayload
  alias Samen.AI.Provider.Scripted

  defmacro __using__(_opts) do
    quote do
      import Samen.AgentCase
    end
  end

  @doc "The `{module, config}` provider pair injecting the deterministic scripted double."
  @spec scripted_provider() :: {module(), map()}
  def scripted_provider, do: {Scripted, %{}}

  @doc "Set the process-local turn script (delegates to `Samen.AI.Provider.Scripted.script/1`)."
  @spec script([term()]) :: :ok
  def script(entries), do: Scripted.script(entries)

  @doc """
  Run `agent_mod` for `goal` under the scripted provider (`opts` pass through to
  `Samen.AI.Agent.run/4`; `:provider` is pinned to the scripted double).
  """
  @spec run_scripted(module(), Samen.Scope.t(), String.t(), keyword()) :: term()
  def run_scripted(agent_mod, scope, goal, opts \\ []) do
    Agent.run(agent_mod, scope, goal, Keyword.put(opts, :provider, scripted_provider()))
  end

  @doc "Every scripted `:complete` payload's segment list, OLDEST call first."
  @spec sent_segments() :: [[term()]]
  def sent_segments do
    Scripted.sent_payloads()
    |> Enum.reverse()
    |> Enum.filter(fn {callback, _} -> callback == :complete end)
    # Field-less match + dot access (the single-mint probe convention).
    |> Enum.map(fn {_callback, %MaskedPayload{} = payload} -> payload.segments end)
  end

  @doc "Every binary that reached the provider boundary, flattened (for canary controls)."
  @spec sent_texts() :: [String.t()]
  def sent_texts do
    sent_segments()
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Every scripted `:complete` payload's EG2 `:tools` field (the sealed tool DEFS the
  provider was offered), OLDEST call first (A3 — ADR-047 §4.2).
  """
  @spec sent_tool_defs() :: [[map()]]
  def sent_tool_defs do
    Scripted.sent_payloads()
    |> Enum.reverse()
    |> Enum.filter(fn {callback, _} -> callback == :complete end)
    # Field-less match + dot access (the single-mint probe convention).
    |> Enum.map(fn {_callback, %MaskedPayload{} = payload} -> payload.tools end)
  end

  @doc """
  BUDGET-HONESTY red half (RP-AG-6): the result is `{:error, :budget_exhausted, run}` —
  never an `{:ok, …}` promotion of the last assistant turn — and the persisted run is
  terminal `:budget_exhausted` with a bounded `error_kind`. Returns the run.
  """
  def assert_honest_exhaustion!(result) do
    assert {:error, :budget_exhausted, run} = result,
           "expected fail-honest budget exhaustion ({:error, :budget_exhausted, run}), " <>
             "got: #{inspect(result)} — a partial answer dressed as a result is the exact " <>
             "lie the fail-honest floor forbids (ADR-047 §6)"

    assert run.state == :budget_exhausted
    assert is_binary(run.error_kind) and run.error_kind != ""
    run
  end

  @doc "A terminal-state assertion on the PERSISTED row (reloads the run first)."
  def assert_terminal!(run, state) do
    run = Ash.get!(Samen.AI.Agent.Run, run.id, authorize?: false)
    assert run.state == state, "expected terminal #{inspect(state)}, got #{inspect(run.state)}"
    assert run.next_turn_at == nil, "a terminal run must clear next_turn_at (§4.1)"
    run
  end

  @doc "The run's bounded turn-log rows, ordered by `turn_index`."
  @spec turn_rows(term()) :: [term()]
  def turn_rows(run) do
    require Ash.Query

    Turn
    |> Ash.Query.filter(run_id == ^run.id)
    |> Ash.Query.sort(turn_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  NO-TEXT-AT-REST red half (ADR-047 §6): no attribute of the persisted run row NOR of any
  of its turn rows contains any of `canaries` (prompt text, completion text, tool arg
  values) — scalar, list, AND map/jsonb values alike (`leaks?/2`). Pair it with a
  `sent_texts/0` control proving the canaries DID cross the provider boundary —
  otherwise the scan is vacuous. The run's vault-routed `:transcript` reads back as
  `%Samen.Masked{}` (a `vt_*` token at rest, never text) — proven at the PHYSICAL layer
  by `assert_transcript_vaulted_at_rest!/2`.
  """
  def assert_no_text_at_rest!(run, canaries) do
    run = Ash.get!(Samen.AI.Agent.Run, run.id, authorize?: false)

    for row <- [run | turn_rows(run)],
        {attr, value} <- persisted_attributes(row),
        canary <- List.wrap(canaries) do
      refute leaks?(value, canary),
             "persisted text leak: #{inspect(attr)} on #{inspect(row.__struct__)} " <>
               "contains #{inspect(canary)} — the run/turn log is token-only (ADR-047 §6)"
    end

    :ok
  end

  @doc """
  A2's vault-routing proof at the PHYSICAL layer (ADR-047 §7.4): read the run's RAW
  database row (`SELECT *`, no Ash types, no `Samen.Type.VaultField` masking) and assert

    * the transcript column holds a `vt_*` vault token — never plaintext, and
    * NO column of the raw row contains any of `canaries`.

  This is the direct assertion that the transcript at rest lives inside the DEK
  envelope — not an inference from the (type-mediated) Ash read.
  """
  def assert_transcript_vaulted_at_rest!(run, canaries) do
    repo = AshPostgres.DataLayer.Info.repo(Samen.AI.Agent.Run, :read)
    {:ok, run_pk} = Ecto.UUID.dump(run.id)

    %{columns: columns, rows: [row]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT * FROM ai_agent_run WHERE arn_id = $1", [run_pk])

    raw = Enum.zip(columns, row)
    {_col, transcript} = Enum.find(raw, fn {col, _} -> col == "pii_arn_transcript" end)

    assert is_binary(transcript) and String.starts_with?(transcript, "vt_"),
           "the physical transcript column must hold a vt_* vault token " <>
             "(ADR-047 §7.4 — inside the DEK envelope); got: #{inspect(transcript)}"

    for {col, value} <- raw, is_binary(value), canary <- List.wrap(canaries) do
      refute String.contains?(value, canary),
             "PHYSICAL text leak: raw column #{col} contains #{inspect(canary)} — " <>
               "transcript plaintext escaped the DEK envelope (ADR-047 §7.4)"
    end

    :ok
  end

  @doc """
  HISTORY-ACCUMULATION green half (§3.2a engaged on the agent path): the payload of call
  `n` (1-based) contains every line of `expected_lines` as a segment — prior assistant
  turns re-entered through `:history` and survived the re-scrub.
  """
  def assert_history_accumulated!(n, expected_lines) do
    segments = sent_segments() |> Enum.at(n - 1)

    assert is_list(segments), "no recorded payload for call #{n}"

    for line <- expected_lines do
      assert line in segments,
             "turn #{n}'s payload is missing accumulated history line #{inspect(line)} — " <>
               "got segments: #{inspect(segments)}"
    end

    segments
  end

  @doc """
  MASKED-ONLY property (RP-AG-3, §4.4 — operator decision §9#2 TAKEN): every segment of
  every recorded payload is a plain binary — no `{:grant_span, …}` tag, no `vt_*` token,
  no un-rendered struct — because the agent path passes `grant_egress?: false` and only
  rendered binaries as history.

  T188: delegates to the shared, cross-family kit
  `Samen.AdapterConformanceCase.assert_masked_segments!/1` — same contract, same callers,
  DRY (this was one of the three narrower things T188 generalizes).
  """
  def assert_masked_only_payloads! do
    Samen.AdapterConformanceCase.assert_masked_segments!(sent_segments())
  end

  @doc """
  Does `value` contain `canary` anywhere — as a binary, inside a list, or inside a
  MAP/jsonb value (keys AND values, recursively)?

  A1 shipped this scanning binaries and lists only, which the A1 verifier flagged as
  VACUOUS for map-typed attributes; A2's bounded `meta` jsonb on the turn log makes the
  map arm load-bearing, so it is now public and recursive over maps — with a red-path
  test proving a canary inside a map value IS detected (non-vacuity). Structs (e.g. the
  `%Samen.Masked{}` a vault-routed read presents, `DateTime`) are deliberately NOT
  descended: a masked value at rest is a token, and scanning it would assert nothing.
  """
  @spec leaks?(term(), String.t()) :: boolean()
  def leaks?(value, canary) when is_binary(value), do: String.contains?(value, canary)

  def leaks?(value, canary) when is_list(value),
    do: Enum.any?(value, &leaks?(&1, canary))

  def leaks?(%_struct{}, _canary), do: false

  def leaks?(value, canary) when is_map(value),
    do: Enum.any?(value, fn {k, v} -> leaks?(k, canary) or leaks?(v, canary) end)

  def leaks?(value, canary) when is_atom(value) and not is_nil(value),
    do: String.contains?(Atom.to_string(value), canary)

  def leaks?(_value, _canary), do: false

  # --- internals -------------------------------------------------------------------------

  # Every persisted (non-meta) attribute of an Ash record, as {name, value}.
  defp persisted_attributes(%resource{} = row) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn %{name: name} -> {name, Map.get(row, name)} end)
  end
end
