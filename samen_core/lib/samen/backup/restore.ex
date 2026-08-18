defmodule Samen.Backup.Restore do
  @moduledoc """
  The restore-target seam for backup VERIFICATION (L6 / T92).

  "Did the backup actually work?" cannot be answered by the presence of a dump
  file — only by RESTORING it into a scratch database and querying it back. This
  behaviour is that restore step, kept behind an adapter exactly like
  `Samen.Files.Storage` and `Samen.Delivery.Provider` so the verification LOGIC is
  host-agnostic and the real cloud restore target (Neon PITR branch / an S3-hosted
  `pg_dump` artifact — L1/L3, credential-gated) is a swappable, FAIL-HONEST seam.

  ## Fail-honest contract (ADR-014/024/026)

  An UNCONFIGURED restore target returns `{:error, :not_configured}` — it NEVER
  hands back a fake handle, because a fake handle would let the verifier report a
  green "backup is restorable" for a restore that never happened. That is the exact
  lie the fail-honest gates abolish. `Samen.Backup.Restore.NotConfigured` is the
  default and encodes it.

  `Samen.Backup.Restore.LocalPgDump` is the locally-provable adapter: it really
  runs `pg_restore` of a real `pg_dump` artifact into a real scratch database and
  hands back a live connection, so the verifier checks bytes that actually
  round-tripped through Postgres.

  A `restore/2` implementation returns:

    * `{:ok, handle}` — `handle` is a map carrying at least `:query` (a
      `(sql, params) -> {:ok, %{rows: rows}} | {:error, term}` function bound to the
      restored scratch DB) and `:cleanup` (a 0-arity teardown). The verifier reads
      the restored data ONLY through `:query`.
    * `{:error, :not_configured}` — no restore target wired.
    * `{:error, reason}` — a real restore FAILURE (corrupt/truncated/missing
      artifact, DDL error, …). This is a REAL signal the verifier surfaces as a
      failed verification, never swallowed.
  """

  @type config :: map()
  @type handle :: %{
          required(:query) => (String.t(), list() -> {:ok, map()} | {:error, term()}),
          required(:cleanup) => (-> any()),
          optional(atom()) => any()
        }

  @callback configured?(config()) :: boolean()
  @callback restore(config(), scratch :: map()) :: {:ok, handle()} | {:error, term()}
end

defmodule Samen.Backup.Restore.NotConfigured do
  @moduledoc """
  The DEFAULT, fail-honest restore target (L6). Mirrors `Samen.Files.Storage.S3`
  and `Samen.Delivery.Smtp`: absent a real backup/restore backend it refuses
  rather than pretending a restore succeeded.

  A backup-verification run against this adapter can only ever return
  `{:error, :not_configured}` — NEVER `{:ok, _}`. Wiring a real target (the
  credential-gated L1/L3 Neon-PITR / S3-artifact restore) is an operator TODO.
  """
  @behaviour Samen.Backup.Restore

  @impl true
  def configured?(_config), do: false

  @impl true
  def restore(_config, _scratch), do: {:error, :not_configured}
end
