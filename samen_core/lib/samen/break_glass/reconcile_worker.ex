defmodule Samen.BreakGlass.ReconcileWorker do
  @moduledoc """
  The scheduled break-glass reconciliation cron (F3.5; T4.4, ADR-002 §3).

  Break-glass reveals performed on an operator node while the central chain was
  UNREACHABLE are written to a node-local append-only audit file. Those entries
  live ONLY on the node's disk until they are anchored back into the central
  hash-chain — the "honest residue window". Previously reconciliation was a manual
  `Samen.BreakGlass.Reconciliation.reconcile/1` call; this worker runs it on the
  default crontab so the window closes on a cadence, and emits the
  `[:samen, :break_glass, :unanchored]` signal every tick (even at zero) so a
  monitor sees the residue drain to zero.

  ## Fail-closed semantics

    * `{:ok, _}` — entries anchored (or nothing to do). `:ok`.
    * `{:error, {:local_tamper, _}}` — the node-local chain is CORRUPT. This is
      persistent (retry cannot heal it), so we log `error`, keep the
      already-emitted telemetry, and return `:ok` (do not spin Oban retries on a
      tamper). The `:unanchored` signal stays positive — the alert that the window
      is stuck open.
    * `{:error, _}` (central chain / repo unreachable) — TRANSIENT. Return
      `{:error, reason}` so Oban retries; the entries stay safely local meanwhile.

  ## Queue / attempts

  Queue `:maintenance`; `max_attempts: 5` (retryable transient anchor path). Anchoring
  is idempotent (keyed on each local entry's content hash), so retry never double-anchors.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  require Logger

  alias Samen.BreakGlass.Reconciliation

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    # Emit the residue signal FIRST so the monitor observes the window regardless
    # of the reconcile outcome (a repo outage still needs the "N unanchored" alert).
    _ = safe_signal()

    case Reconciliation.reconcile() do
      {:ok, %{anchored: anchored, already: already, total: total}} ->
        Logger.debug(
          "[Samen.BreakGlass.ReconcileWorker] job_id=#{job_id} anchored=#{anchored} already=#{already} total=#{total}"
        )

        # Re-emit AFTER a successful anchor so the downstream sees residue drop.
        _ = safe_signal()
        :ok

      {:error, {:local_tamper, detail}} ->
        # Persistent corruption — telemetry/log is the alert; do not retry-spin.
        Logger.error(
          "[Samen.BreakGlass.ReconcileWorker] job_id=#{job_id} LOCAL TAMPER — nothing anchored: #{inspect(detail)}"
        )

        :ok

      {:error, reason} ->
        # Transient (central chain/repo unreachable) — retry; entries stay local.
        Logger.warning(
          "[Samen.BreakGlass.ReconcileWorker] job_id=#{job_id} reconcile deferred (retryable): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp safe_signal do
    Reconciliation.emit_unanchored_signal()
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end
end
