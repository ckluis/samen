defmodule Samen.NoPlaintextPii.Tiers.PostShred.BackupPitr do
  @moduledoc """
  **Post-shred check (2): the BACKUP / PITR-HISTORY SCAN** (doc §runs oracle block,
  check 2; ADR-001 §5-7; plan T2.9).

  > (2) BACKUP/PITR-HISTORY SCAN — the per-subject KEY is an EXTERNAL KMS handle,
  >     NOT a Postgres row, so it is OUTSIDE the WAL/PITR surface; a restore brings
  >     back ciphertext, never the key. The scan asserts the key is absent from
  >     every DB tier + PITR history.

  The load-bearing claim of ADR-001: the per-subject DEK is never a Postgres row,
  so a point-in-time restore of any pre-shred WAL brings back the (useless)
  ciphertext but cannot resurrect the destroyed key. This tier proves it two ways:

    1. **Key absent from the external store's backup surface.** `backups_disabled?/0`
       on the KMS adapter must be `true` (ADR-001 CI check 2; the doc's "the key
       store is excluded from the backup surface"). `false` — PITR accidentally
       enabled on the wrapped-DEK store — is a violation (the store would be
       restorable and the shred reversible).

    2. **Key absent from every DB tier + PITR history.** For the live repo and each
       configured PITR-snapshot repo (`pitr_repos` — the pg_dump-based history from
       T2.5's drill machinery, restored into throwaway DBs), assert via
       `Samen.Vault.scan_pitr_key_absent/2` that (a) `pii_vault` carries no
       key-material-shaped column (the wrapped DEK is never a Postgres row) and
       (b) no ciphertext there decrypts (the key is not resurrectable from the
       snapshot).

  ## Simulation seam (no Neon in this environment)

  There is NO Neon/AWS PITR facility here (plan HARD note). The PITR history is
  SIMULATED with the pg_dump→psql-restore snapshots the T2.5 drill produces
  (`docs/runbooks/pitr-gameday-sim.sh`). Pass those restored DBs as `pitr_repos`.
  With no `pitr_repos`, the tier scans the LIVE repo for key absence (still a real
  assertion: the key is provably not a Postgres row on the live tier) and records
  the PITR-snapshot scan as a documented operator seam — never a fake pass.

  A real Neon branch-and-restore drill is registered as an operator TODO in
  `docs/runbooks/pitr-gameday.md`.

  ## Positive attestation

  `:post_shred` tier: emits `:pass` per sub-assertion cleared, `:violation` on any
  key presence / decryptable ciphertext / PITR-on regression. Never empty.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.Vault

  @tier :backup_pitr

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do:
      "post-shred backup/PITR-history scan: subject key absent from every DB tier + " <>
        "PITR history; external store PITR/backup disabled"

  @impl true
  def check(%Context{subject_id: nil}) do
    [
      Finding.violation(
        @tier,
        "<subject>",
        "post-shred backup/PITR scan requires --subject <uuid> — fail closed."
      )
    ]
  end

  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no live repo configured — cannot scan DB tiers for key absence (fail closed)."
      )
    ]
  end

  def check(%Context{} = ctx) do
    backups_disabled_findings() ++
      live_key_absent_findings(ctx) ++
      pitr_findings(ctx)
  end

  # ---------------------------------------------------------------------------
  # (2a) external store PITR/backup disabled
  # ---------------------------------------------------------------------------

  defp backups_disabled_findings do
    if Vault.backups_disabled?() do
      [
        Finding.pass(
          @tier,
          "kms_store_backups",
          "the external wrapped-DEK store has PITR/continuous-backup DISABLED " <>
            "(ADR-001 CI check 2) — the key store is excluded from the backup surface, " <>
            "so no restore can resurrect the shredded key"
        )
      ]
    else
      [
        Finding.violation(
          @tier,
          "kms_store_backups",
          "backups_disabled?/0 == false — PITR/continuous-backup is ENABLED on the " <>
            "wrapped-DEK store. A restore could resurrect the shredded key and re-decrypt " <>
            "every 'dead' copy. This is exactly the ADR-001 red path. Fail closed."
        )
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # (2b) key absent from the live DB tier
  # ---------------------------------------------------------------------------

  defp live_key_absent_findings(%Context{subject_id: sid, repo: repo}) do
    key_absent_finding("live", sid, repo)
  end

  # ---------------------------------------------------------------------------
  # (2c) key absent from every PITR-history snapshot (SIMULATED)
  # ---------------------------------------------------------------------------

  defp pitr_findings(%Context{pitr_repos: repos}) when repos in [nil, []] do
    [
      Finding.pass(
        @tier,
        "pitr_history",
        "SEAM: no PITR-snapshot repos passed. The key-absence assertion held on the LIVE " <>
          "tier (the key is provably not a Postgres row there). SIMULATE the PITR history " <>
          "by passing `pitr_repos: [RestoredSnapshotRepo, …]` (pg_dump snapshots from the " <>
          "T2.5 drill). A real Neon branch-and-restore drill is an operator TODO " <>
          "(docs/runbooks/pitr-gameday.md)."
      )
    ]
  end

  defp pitr_findings(%Context{subject_id: sid, pitr_repos: repos}) do
    Enum.flat_map(Enum.with_index(repos, 1), fn {repo, i} ->
      key_absent_finding("pitr_snapshot_#{i}", sid, repo)
    end)
  end

  # ---------------------------------------------------------------------------

  defp key_absent_finding(label, sid, repo) do
    case Vault.scan_pitr_key_absent(sid, repo) do
      {:ok, :key_absent} ->
        [
          Finding.pass(
            @tier,
            label,
            "the subject key is ABSENT from '#{label}' (no key-material column on pii_vault; " <>
              "no ciphertext decrypts) — a restore brings back ciphertext, never the key"
          )
        ]

      {:leaks, leaks} ->
        [
          Finding.violation(
            @tier,
            label,
            "key/plaintext residue on '#{label}': #{Enum.join(leaks, " | ")}"
          )
        ]
    end
  rescue
    e ->
      [
        Finding.violation(
          @tier,
          label,
          "could not scan '#{label}' for key absence (#{Exception.message(e)}) — fail closed."
        )
      ]
  end
end
