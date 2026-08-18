defmodule Samen.Webhook.IngestWorker do
  @moduledoc """
  The webhook processing worker (ADR-038 §5.2 steps 4–5 + §5.5; T19/B9).

  Runs in the new `:webhooks_in` Oban queue (added next to `:webhooks_out` in
  `Samen.Jobs`). The ingress endpoint (`samen_web`) fast-acks the provider (200) after
  it persists a `Samen.Webhook.Event` envelope, then enqueues THIS worker with a
  TOKEN-ONLY arg — the envelope row id, nothing else (never the payload). Slow work
  never runs in the request; provider timeouts/retries are absorbed by the fast ack +
  the idempotent replay store.

  ## Lifecycle

    1. Load the envelope by id (a missing/foreign row is a no-op — `:ok`).
    2. `mark_processing/2` (stamps an attempt).
    3. `Samen.Webhook.Dispatch.run/2` — billing kinds → reconciler (T21), delivery →
       C4 handler (T30). Absent a wired dispatch, the honest default `:unhandled`s.
    4. On `:ok` → `mark_processed`. On `{:discard, reason}` → dead-letter immediately.
       On `{:error, reason}` → retry; on the FINAL attempt the envelope is flipped to
       `:dead` (the DLQ state, ADR-038 §5.5) so a handler-crash payload lands
       operator-visible.

  ## Idempotency (safe replay)

  Processing is idempotent by construction: billing reconciliation re-fetches the
  authoritative object (§3.4), delivery re-matches by `provider_message_id` (§4.4).
  So the operator "replay" action (re-enqueue a `:dead` envelope) is safe — this
  worker can run the same envelope any number of times.

  ## Repo resolution

  The worker is repo-agnostic (kernel infra). It reads the ingress repo from
  `config :samen_core, Samen.Webhook, repo: MyApp.Repo` (the same key `samen_web`'s
  ingress writes through), or from the job arg `"repo"` (a module string) for tests.
  """

  use Oban.Worker, queue: :webhooks_in, max_attempts: 20

  alias Samen.Webhook.{Dispatch, Event}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    repo = resolve_repo(args)
    event_id = Map.get(args, "event_id") || Map.get(args, :event_id)

    case repo && event_id && Event.get(repo, event_id) do
      nil ->
        # No repo, no id, or the row is gone — nothing to do, acknowledge.
        :ok

      %Event{} = event ->
        process(repo, event, job)
    end
  end

  @doc """
  Enqueue an envelope for processing. Token-only args — the row id (+ the repo module
  so the worker can resolve it in a multi-repo test/host). Returns the Oban insert result.
  """
  @spec enqueue(Event.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Event{id: id}, opts \\ []) do
    args = %{"event_id" => id}

    args =
      case Keyword.get(opts, :repo) do
        nil -> args
        repo -> Map.put(args, "repo", to_string(repo))
      end

    args
    |> new()
    |> Oban.insert()
  end

  # ---------------------------------------------------------------------------

  defp process(repo, event, job) do
    {:ok, event} = Event.mark_processing(repo, event)

    case safe_dispatch(event) do
      :ok ->
        {:ok, _} = Event.mark_processed(repo, event)
        :ok

      {:discard, reason} ->
        {:ok, _} = Event.mark_dead(repo, event, reason)
        {:discard, reason}

      {:error, reason} ->
        if final_attempt?(job) do
          # Exhausted retries — dead-letter the envelope (operator-visible DLQ, §5.5).
          {:ok, _} = Event.mark_dead(repo, event, reason)
        end

        {:error, reason}
    end
  end

  # A raising handler is a transient failure, not a crash of the worker — capture it so
  # the envelope's attempt/DLQ accounting stays correct (never a payload echo in the error).
  defp safe_dispatch(event) do
    Dispatch.run(event)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
  defp final_attempt?(_), do: true

  defp resolve_repo(args) do
    case Map.get(args, "repo") || Map.get(args, :repo) do
      nil -> Application.get_env(:samen_core, Samen.Webhook, [])[:repo]
      mod when is_atom(mod) -> mod
      mod when is_binary(mod) -> safe_module(mod)
    end
  end

  defp safe_module(str) do
    String.to_existing_atom(str)
  rescue
    _ ->
      # tolerate "Elixir."-prefixed or bare names
      try do
        Module.concat([str])
      rescue
        _ -> nil
      end
  end
end
