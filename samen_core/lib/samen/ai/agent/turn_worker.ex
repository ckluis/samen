defmodule Samen.AI.Agent.TurnWorker do
  @moduledoc """
  Oban worker for durable agent-turn execution (ADR-047 §4.1(c), batch A2). One job =
  one turn BATCH: `perform/1` loads the run cursor and executes up to
  `Samen.AI.Agent.turns_per_job/0` turns via the SAME engine `Samen.AI.Agent.run/4`
  drives, then either finishes (terminal/parked run) or RE-ARMS by enqueuing itself.

  ## Job args convention (token-only — F2.1)

  Job args carry ONLY the run row's opaque id — the agent module, owner actor, org,
  budgets, and transcript are all loaded from the durable row, never serialized into
  `oban_jobs.args` (the ADR-037 §5.9 sink rule).

  ## Single retry authority (the `Samen.Sequences.SendWorker` rule)

  EVERY business outcome — goal met, budget exhausted, cancel, kill, provider failure,
  refusal — returns `:ok` to Oban: it is a successfully RECORDED result, not a crashed
  job. Only a fetch-chain failure (the run row could not even be loaded) returns
  `{:error, _}` and asks Oban's own backoff to retry. The run row's never-nil
  `next_turn_at` watchdog (the AshOban `:agent_turn_due` trigger on
  `Samen.AI.Agent.Run`) is the ONE retry authority for everything else: a worker
  death mid-turn, a lost re-arm enqueue, a silently-discarded job — all recovered by
  the next due-scan cycle, which replays into the SAME `{run_id, turn_index}` turn row
  (`Samen.AI.Agent`'s decision-checkpoint reuse) instead of duplicating work.

  ## Uniqueness

  `unique: [keys: [:run_id], period: 60, states: :incomplete]` — a double-enqueue race
  for the same run (launch + watchdog firing together) dedupes; a legitimate re-arm
  after the prior job completed is never deduped against that finished job (the
  Sequences `:states` lesson).
  """
  use Oban.Worker,
    queue: :automation,
    max_attempts: 3,
    unique: [keys: [:run_id], period: 60, states: :incomplete]

  require Logger

  alias Samen.AI.Agent

  @doc "Enqueue a turn-batch job for `run_id`. Best-effort: never raises."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(run_id) do
    %{"run_id" => run_id} |> new() |> Oban.insert()
  rescue
    e ->
      Logger.warning("[Samen.AI.Agent.TurnWorker] enqueue raised: #{Exception.message(e)}")
      {:error, e}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Agent.fetch_run(run_id) do
      {:ok, run} ->
        case Agent.execute_batch(run) do
          {:continue, run} ->
            # Batch boundary: re-arm. A failed insert is logged loudly, never an error
            # to Oban — the run's in-flight watchdog window guarantees recovery
            # (the Sequences enqueue_send posture).
            case enqueue(run.id) do
              {:ok, _job} ->
                :ok

              {:error, reason} ->
                Logger.error(
                  "[Samen.AI.Agent.TurnWorker] re-arm enqueue FAILED run=#{run.id} " <>
                    "reason=#{inspect(reason)} — the :agent_turn_due watchdog will recover"
                )

                :ok
            end

          _terminal_or_done ->
            # Every business outcome is a recorded result (see moduledoc).
            :ok
        end

      {:error, :not_found} ->
        # The row is genuinely gone (e.g. org erasure raced the job) — nothing to
        # execute, nothing to retry against.
        Logger.warning("[Samen.AI.Agent.TurnWorker] run #{run_id} not found — skipping")
        :ok

      {:error, reason} ->
        # Transient fetch-chain failure: retriable, never `{:discard, _}` (the Sequences
        # MED-2 lesson — a discard here would strand nothing thanks to the watchdog, but
        # Oban's own backoff deserves the chance to recover a transient blip first).
        {:error, "agent turn batch: could not load run #{run_id} (#{inspect(reason)})"}
    end
  end
end
