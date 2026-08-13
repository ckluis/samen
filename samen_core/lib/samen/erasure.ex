defmodule Samen.Erasure do
  @moduledoc """
  Crypto-shred orchestration (doc D7/D8; §data; §limits erasure bullet; T1.7).

  `shred/2` is the one entry point that erases a subject. It is a *key-destruction*
  job — NOT a copy-chasing / destruction-by-eventual-consistency job. One key shred
  makes every vaulted value undecryptable across live/replica/backup-PITR/CDC/
  rollup/audit at once (the ciphertext stays; the DEK is gone). The two carve-outs
  key-shred does NOT reach — trace-sink pseudonyms and review-gated `non_pii!`
  plaintext columns — are handled explicitly here (pseudonym unlinks with the same
  DEK; `non_pii!` rows are redacted row-level).

  ## What `shred/2` does (T1.7 (a)–(d))

    1. **Destroys the subject key** via the `Samen.Kms` adapter (`shred/1`). This
       is the load-bearing act: after it, `Samen.Vault.reveal/3` returns
       `{:error, :shredded}` for EVERY vault row of the subject, everywhere.
    2. **Writes the SHREDDED sentinel** on the subject's `pii_vault` rows
       (`state = "shredded"`, `erased_at = now`). The domain-row token FK now
       points at a dangling / sentinel vault row (doc D7 "down to a dangling
       token"). The ciphertext is left in place (it is useless bytes) so the
       oracle can still *see* that every key-reachable copy is undecryptable.
    3. **Redacts registered `non_pii!` columns** (`Samen.NonPii.redact_for_subject/3`)
       — the plaintext carve-out key-shred cannot reach — and records the tally.
    4. **Emits an audit row** (`rvl_reveal_audit`, event `"erased"`) so the erasure
       is on the tamper-evident lifecycle log the reveal grants already write to.
    5. **Writes + returns the erasure report artifact** (`era_erasure_report`):
       attestation id, outcome, which tiers were touched, redaction tally — the
       artifact the T2.9 oracle consumes.

  Steps 2–5 run in ONE Ecto transaction so a partial erasure never leaves a
  half-stamped state. Step 1 (the key shred) happens FIRST and OUTSIDE the tx: the
  key store is external (ADR-001), so its destruction cannot participate in the
  Postgres transaction — and it is the load-bearing guarantee, so it must succeed
  before we bother sealing the DB tiers. If the DB-tier tx then fails, the key is
  still gone (fail-safe: the data is already unrecoverable); a re-run is idempotent
  and completes the sentinel/redaction/report.

  ## Idempotence

  A second `shred/2` for the same subject is safe. The KMS `shred/1` is idempotent
  (returns the existing tombstone). Sealing already-sealed vault rows is a no-op.
  Re-redaction writes 0 additional cells. The attestation stays positive
  (`:shredded` with `destroyed_at`). A fresh report row is written each call with
  `outcome: "already_shredded"` on the second, so the audit trail shows both calls.

  ## Return

  `{:ok, %{attestation: attestation, report: report}}` on success — the attestation
  is ALWAYS positive after a successful shred (`state: :shredded`). `{:error, term}`
  only if the key store itself is unreachable at shred time (fail-closed: no
  attestation is fabricated).
  """

  alias Samen.Kms
  alias Samen.Vault.VaultRow
  alias Samen.Erasure.Report
  alias Samen.NonPii
  alias Samen.Reveal.Grants

  import Ecto.Query, only: [from: 2]

  @doc """
  Crypto-shred `subject_id`. See the module doc for the full sequence.

  Options:
    * `:repo` — the Ecto repo for the DB-tier work (vault sentinel, non_pii!
      redaction, audit row, report). Defaults to the configured `:non_pii_repo` /
      `:reveal_grant_repo` / `:verify_repo`.
    * `:actor_id` — who initiated the erasure (recorded in the audit row).
      Defaults to `"system:erasure"`.
  """
  @spec shred(String.t(), keyword()) ::
          {:ok, %{attestation: Kms.attestation(), report: Report.t()}} | {:error, term}
  def shred(subject_id, opts \\ []) when is_binary(subject_id) do
    r = Keyword.get(opts, :repo) || default_repo()
    actor_id = Keyword.get(opts, :actor_id, "system:erasure")
    # Optional: the subject's org, so the erasure event rides that org's T4.3 chain
    # (ADR-002). Absent → the reserved "__global__" operator/system chain.
    org_id = Keyword.get(opts, :org_id) || Samen.AuditChain.global_org()

    # Options forwarded to the rollup erasure policy (T2.3): `:specs` (override the
    # registry) and `:raw_retained?` (force the rebuild/suppress arm — tests use
    # this to exercise the archived-window suppress arm without physically
    # detaching a partition; see the simulation seam in `Samen.Rollup`).
    rollup_opts = Keyword.take(opts, [:specs, :raw_retained?])

    # Options for the file-blob erasure arm (ADR-046 §4.3 D4): the registered file
    # specs (or the config default), the subject's org (for the token-only blob-delete
    # audit; nil → each file's own org_id), and who initiated the erasure.
    file_opts = [
      file_specs: Keyword.get(opts, :file_specs),
      org_id: Keyword.get(opts, :org_id),
      actor_id: actor_id
    ]

    # STEP 1 — destroy the key FIRST, outside the DB tx. This is the load-bearing
    # act. It is the ONLY thing that can make the guarantee fail closed (if the
    # key store is unreachable we must NOT proceed and NOT fabricate an
    # attestation).
    case Kms.shred(subject_id) do
      {:ok, attestation} ->
        seal_db_tiers(subject_id, attestation, :from_state, actor_id, org_id, r, rollup_opts, file_opts)

      {:error, :absent} ->
        # Subject never had a key. Still redact any non_pii! rows and write a
        # report so an erasure request for a plaintext-only subject is honored
        # and attested (outcome: "absent").
        absent_att = %{
          subject_id: subject_id,
          state: :absent,
          destroyed_at: nil,
          attestation_id: nil,
          km_version: nil,
          checked_at: DateTime.utc_now()
        }

        seal_db_tiers(subject_id, absent_att, "absent", actor_id, org_id, r, rollup_opts, file_opts)

      {:error, reason} ->
        # Key store unreachable (outage) — FAIL CLOSED. No sentinel, no report,
        # no fabricated attestation. The caller retries when the store heals.
        {:error, {:kms_shred_failed, reason}}
    end
  end

  # STEP 2–5 in one transaction. `outcome_mode` is `:from_state` (derive from the
  # seal result — "shredded" on the first call that seals rows, "already_shredded"
  # on an idempotent later call) or a fixed string (e.g. "absent").
  defp seal_db_tiers(subject_id, attestation, outcome_mode, actor_id, org_id, r, rollup_opts, file_opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    multi =
      Ecto.Multi.new()
      # STEP 2 — SHREDDED sentinel on vault rows. Idempotent (only stamps rows
      # not already sealed). Returns the number newly sealed.
      |> Ecto.Multi.update_all(
        :seal_vault,
        from(v in VaultRow, where: v.subject_id == ^subject_id and v.state != "shredded"),
        set: [state: "shredded", erased_at: now, updated_at: now]
      )
      # STEP 3 — redact registered non_pii! plaintext columns (the carve-out).
      |> Ecto.Multi.run(:redact_non_pii, fn repo, _changes ->
        {:ok, count, details} = NonPii.redact_for_subject(subject_id, repo)
        {:ok, %{count: count, details: details}}
      end)
      # STEP 3b — rebuild-or-exclude-on-erasure for every registered rollup (T2.3
      # (b)). A derived aggregate computed BEFORE the shred can still encode the
      # subject (key-shred does not touch a count) — so each rollup is governed
      # separately: REBUILD without the subject where the raw partitions are
      # retained, or EXCLUDE/SUPPRESS the derived row where the window is
      # archived/detached. Runs INSIDE the erasure tx so it commits atomically
      # with the sentinel/redaction/report.
      |> Ecto.Multi.run(:rollups, fn repo, _changes ->
        {:ok, Samen.Rollup.erase_subject(subject_id, repo, rollup_opts)}
      end)
      # STEP 3c — file-blob erasure arm (ADR-046 §4.3 D4). Raw stored file bytes live
      # OUTSIDE the per-subject-DEK envelope, so key-shred does not reach them: this arm
      # deletes the subject's file blobs through the governed, ref-counted, fail-honest
      # Samen.Files.delete_file/3 chokepoint (last-reference-aware — a blob a NON-erased
      # clone still references survives, T130). Fail-soft: a file whose blob cannot be
      # reached is recorded, never rolls back the subject's vault erasure.
      |> Ecto.Multi.run(:file_blobs, fn repo, _changes ->
        {:ok, Samen.Files.Erasure.erase_subject(subject_id, repo, file_opts)}
      end)
      # STEP 5 (built here, needs step 2/3/3b/3c results) — the erasure report.
      |> Ecto.Multi.run(:report, fn repo, changes ->
        {sealed, _} = changes.seal_vault
        %{count: redacted, details: redaction_details} = changes.redact_non_pii
        rollup_report = changes.rollups
        file_report = changes.file_blobs

        tiers =
          build_tiers(subject_id, attestation, sealed, redaction_details, rollup_report, file_report, repo)
        outcome = resolve_outcome(outcome_mode, subject_id, sealed, repo)

        report_attrs = %{
          subject_id: subject_id,
          attestation_id: attestation[:attestation_id],
          outcome: outcome,
          tiers: tiers,
          vault_rows_sealed: sealed,
          non_pii_rows_redacted: redacted,
          recorded_at: now
        }

        %Report{}
        |> Ecto.Changeset.cast(report_attrs, [
          :subject_id,
          :attestation_id,
          :outcome,
          :tiers,
          :vault_rows_sealed,
          :non_pii_rows_redacted,
          :recorded_at
        ])
        |> repo.insert()
      end)
      # STEP 4a — audit row on the reveal lifecycle log (event "erased").
      |> Ecto.Multi.run(:audit, fn repo, changes ->
        {sealed, _} = changes.seal_vault
        %{count: redacted} = changes.redact_non_pii
        outcome = changes.report.outcome

        Grants.write_audit(repo, %{
          event: "erased",
          subject_id: subject_id,
          actor_id: actor_id,
          detail:
            "outcome=#{outcome} attestation_id=#{attestation[:attestation_id] || "none"} " <>
              "vault_sealed=#{sealed} non_pii_redacted=#{redacted}"
        })
      end)
      # STEP 4b — append-only event tier row (T2.2: erasure events mirror to
      # aud_event carrying tokens only, never plaintext PII).
      |> Ecto.Multi.run(:aud_event, fn repo, changes ->
        {sealed, _} = changes.seal_vault
        %{count: redacted} = changes.redact_non_pii
        outcome = changes.report.outcome

        # Emit to the aud_event tier AND seal into the T4.3 hash chain (ADR-002).
        # Post-shred the erasure event survives on the tamper-evident chain (its hash
        # is over tokens, not plaintext) while the subject stays unrecoverable — the
        # doc's "immutable AND crypto-shreddable" resolution, proven by the shred test.
        Samen.AuditChain.Writer.write(repo, %{
          org_id: org_id,
          event_type: "erasure",
          subject_id: subject_id,
          actor_id: actor_id,
          detail:
            "outcome=#{outcome} vault_sealed=#{sealed} non_pii_redacted=#{redacted} " <>
              "attestation_id=#{attestation[:attestation_id] || "none"}",
          occurred_at: now
        })
      end)

    case r.transaction(multi) do
      {:ok, %{report: report}} ->
        {:ok, %{attestation: attestation, report: report}}

      {:error, _step, reason, _changes} ->
        {:error, {:erasure_tx_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Tier descriptors — what the T2.9 oracle reads (D7 report).
  # ---------------------------------------------------------------------------

  defp build_tiers(subject_id, attestation, sealed, redaction_details, rollup_report, file_report, repo) do
    remaining_active =
      repo.aggregate(
        from(v in VaultRow, where: v.subject_id == ^subject_id and v.state == "active"),
        :count
      )

    total_vault =
      repo.aggregate(from(v in VaultRow, where: v.subject_id == ^subject_id), :count)

    %{
      "kms" => %{
        "state" => to_string(attestation[:state]),
        "attestation_id" => attestation[:attestation_id],
        # Oracle check-3: a positive :shredded tombstone is required. We surface
        # the state so the oracle can assert it (:absent/:active => FAIL there).
        "positive_tombstone" => attestation[:state] == :shredded,
        # Oracle check-2b (Gate-0 P2 shred defence-in-depth): the wrapped DEK must
        # be ACTUALLY destroyed, not merely tombstoned. false == key gone == good.
        "key_material_present" => Kms.adapter().key_material_present?(subject_id)
      },
      "vault" => %{
        "rows_total" => total_vault,
        "rows_sealed_this_call" => sealed,
        # The invariant the oracle asserts: NO vault row for the subject is still
        # "active" after erasure. (0 active == sealed.)
        "rows_still_active" => remaining_active
      },
      "registered_non_pii" => %{
        # The carve-out tier: assert row-level redaction ran.
        "columns" => redaction_details
      },
      # Derived-aggregate tier (T2.3): the per-rollup rebuild-or-exclude report —
      # each entry is `%{"rollup" => name, "arm" => "rebuild"|"suppress",
      # "rows_affected" => n}`. The oracle asserts every registered rollup was
      # governed (rebuilt subject-free or the subject's derived rows suppressed);
      # a registered rollup ABSENT from this list on a post-shred report is a
      # fail-closed gap.
      "rollups" => rollup_report,
      # File-blob tier (ADR-046 §4.3 D4): the per-file-resource report of blobs the
      # erasure arm deleted for the subject (last-reference-aware). Empty when no file
      # erasure spec is registered. Token-only (counts + resource name, never a key).
      "file_blobs" => file_report
    }
  end

  # ---------------------------------------------------------------------------
  # Read side — the oracle / operator consumes these.
  # ---------------------------------------------------------------------------

  @doc """
  The most recent erasure report for a subject (T2.9 consumes this), or `nil`.
  """
  @spec latest_report(String.t(), keyword()) :: Report.t() | nil
  def latest_report(subject_id, opts \\ []) do
    r = Keyword.get(opts, :repo) || default_repo()

    r.one(
      from(rep in Report,
        where: rep.subject_id == ^subject_id,
        order_by: [desc: rep.recorded_at],
        limit: 1
      )
    )
  end

  @doc """
  Has `subject_id` been erased? True iff ALL of:

    1. the KMS attests `:shredded` (positive tombstone — system of record), AND
    2. the wrapped DEK is **actually gone** from the key store
       (`key_material_present?/1 == false`) — defence in depth over the tombstone
       (Gate-0 vault-stack fix, P2): a tombstone written while the key survives is
       NOT a real erasure, so we key on ACTUAL key-material destruction, not the
       tombstone alone, AND
    3. no vault row for the subject is still `"active"` (DB-tier sentinel witness).

  Any of these failing → `false` (fail closed).
  """
  @spec erased?(String.t(), keyword()) :: boolean()
  def erased?(subject_id, opts \\ []) do
    r = Keyword.get(opts, :repo) || default_repo()

    with {:ok, %{state: :shredded}} <- Kms.adapter().attest(subject_id),
         # P2 defence-in-depth: the key material must ACTUALLY be destroyed, not
         # merely tombstoned. A surviving DEK means the ciphertext is recoverable.
         false <- Kms.adapter().key_material_present?(subject_id) do
      active =
        r.aggregate(
          from(v in VaultRow, where: v.subject_id == ^subject_id and v.state == "active"),
          :count
        )

      active == 0
    else
      _ -> false
    end
  end

  # Resolve the report outcome. A fixed string (e.g. "absent") passes through.
  # For `:from_state` we distinguish the FIRST erasure (rows newly sealed > 0)
  # from an idempotent later call (0 newly sealed but the subject already has
  # sealed vault rows) — so the report/audit trail shows both calls faithfully.
  defp resolve_outcome(mode, _subject_id, _sealed, _repo) when is_binary(mode), do: mode

  defp resolve_outcome(:from_state, subject_id, sealed, repo) do
    cond do
      sealed > 0 ->
        "shredded"

      repo.aggregate(from(v in VaultRow, where: v.subject_id == ^subject_id), :count) > 0 ->
        # All rows already sealed by a prior call — idempotent re-run.
        "already_shredded"

      true ->
        # Key shredded, no vault rows at all (plaintext-only subject or already
        # cleaned). Still a positive erasure.
        "shredded"
    end
  end

  defp default_repo do
    Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      Application.get_env(:samen_core, :verify_repo) ||
      raise """
      Samen.Erasure needs a repo. Configure it:

          config :samen_core, :non_pii_repo, MyApp.Repo
      """
  end
end
