defmodule Samen.AI.Embeddings.ReembedWorker do
  @moduledoc """
  T186 (OSS-SCAN, source: AlexClaw Apache-2.0 + BeamWeaver Apache-2.0, mode: adapt) — the
  scheduled incremental re-embed sweep. Calls `Samen.AI.Embeddings.reembed_stale/1`, which
  re-embeds ONLY rows whose `aie_model` is missing or does not match the currently configured
  embedder's `model_identifier/1` (drift on model upgrade) — never a full-table re-embed.
  Mount via `Samen.Jobs.default_crontab/0` (every 30 minutes).

  ## No configuration required, safe no-op when unwired

  Unlike `Samen.Retention.SweepWorker` (opt-in via `:retention_specs`), this job needs no host
  config: it reads the SAME embedder resolution every `embed_field/6` call already uses
  (`config :samen_core, Samen.AI, embedder: {module, config}`, or the keyless `:test` fallback).
  An unwired-prod host gets `{:error, :not_configured}` from `reembed_stale/1` — logged and
  discarded (`{:discard, reason}`), never retried into a backoff storm for a host that has not
  wired an embedder at all (the ADR-014 fail-honest contract: nothing to re-embed AGAINST).

  ## Queue / attempts

  Queue `:maintenance` (already in `Samen.Jobs.default_queue_config/0` — no queue_parity
  change needed, same queue `Samen.Retention.SweepWorker` and
  `Samen.AuditEvent.PartitionManager` share for periodic kernel housekeeping); `max_attempts: 5`
  (a transient DB hiccup retries; a genuinely broken batch does not retry forever). Idempotent:
  a re-run finds fewer (or zero) stale rows once the backlog has been swept, and re-embedding
  an already-fresh row is a no-op it will never even select (`stale_rows/2` excludes it).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    opts = args |> Map.get("limit") |> limit_opts()

    case Samen.AI.Embeddings.reembed_stale(opts) do
      {:ok, %{reembedded: n, errors: errors}} ->
        if errors != [] do
          Logger.warning(
            "[Samen.AI.Embeddings.ReembedWorker] job_id=#{job_id} reembedded=#{n} " <>
              "errors=#{length(errors)} sample=#{inspect(Enum.take(errors, 3))}"
          )
        else
          Logger.info(
            "[Samen.AI.Embeddings.ReembedWorker] job_id=#{job_id} reembedded=#{n} errors=0"
          )
        end

        :ok

      {:error, :not_configured} ->
        Logger.info(
          "[Samen.AI.Embeddings.ReembedWorker] job_id=#{job_id} skipped: no embedder configured"
        )

        {:discard, :not_configured}
    end
  end

  defp limit_opts(nil), do: []
  defp limit_opts(limit) when is_integer(limit), do: [limit: limit]
end
