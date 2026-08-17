defmodule Samen.Backup.VerificationWorker do
  @moduledoc """
  The scheduled backup-verification Oban job (L6 / T92).

  Runs `Samen.Backup.Verification.verify/1` on a cadence (see
  `docs/runbooks/backup-cadence.md`) so "is our most recent backup actually
  restorable?" is answered continuously, not discovered during an incident.

  ## Fail-honest, never a fake green

    * unconfigured restore target → emits the operator alert and `{:cancel,
      :not_configured}` (Oban cancels — visible, no retry storm). It does NOT
      return `:ok`, because "no backend wired" is not a passing verification.
    * a verification FAILURE (corrupt/missing artifact, manifest drift) → returns
      `{:error, reason}` so Oban retries AND the `[:samen, :backup, :verification,
      :failed]` operator alert fires.
    * a full matching restore round-trip → `:ok`.

  Config (`config :samen_core, :backup_verification, ...`) supplies the adapter,
  its config, the scratch descriptor, and the expected manifest. Absent config the
  worker defaults to `Samen.Backup.Restore.NotConfigured` — fail-honest by default.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Samen.Backup.Verification

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Verification.verify(config()) do
      {:ok, _report} ->
        :ok

      {:error, :not_configured} ->
        # Honest cancel: nothing to verify, and we refuse to report success for a
        # restore that never happened.
        {:cancel, :not_configured}

      {:error, reason} ->
        # Real failure — surface to Oban (retry + discard→DLQ) and the alert already
        # fired inside verify/1.
        {:error, reason}
    end
  end

  defp config do
    Application.get_env(:samen_core, :backup_verification, [])
  end
end
