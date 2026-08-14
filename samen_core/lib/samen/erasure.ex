defmodule Samen.Erasure do
  @moduledoc """
  Crypto-shred orchestration (doc D7/D8; §data; §limits erasure bullet; T1.7).

  `shred/2` is the one entry point that erases a subject. It is a *key-destruction*
  job — NOT a copy-chasing / destruction-by-eventual-consistency job. One key shred
  makes every vaulted value undecryptable across live/replica/backup-PITR/CDC/
  rollup/audit at once (the ciphertext stays; the DEK is gone). The residues that
  live OUTSIDE the per-subject-DEK envelope — so key-shred does NOT reach them — are
  handled by explicit arms here (ADR-046 makes this carve-out list complete):
  trace-sink pseudonyms (unlink with the same DEK), review-gated `non_pii!` plaintext
  columns (redacted row-level), stored file blobs (deleted via the governed
  ref-counted `Samen.Files` chokepoint — §4.3 D4), the recomputable `email_bidx`
  blind index (tombstoned to a random sentinel on principal-account erasure — §4.1 D1),
  and Tier-1 `pii_declared: true` custom-bag plaintext (per-key redacted from the sealed
  jsonb bag via `Samen.CustomFields.Erasure` — §4.2 D3).

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
  DERIVE the canonical erasure specs for a host from its LIVE Ash schema.

  The framework-first activation seam (the erasure analogue of
  `Samen.Jobs.default_queue_config/0` + `install_defaults/1`): rather than every host
  hand-wiring which of its abbrev-prefixed tables carry `email_bidx` / `storage_key`,
  the specs are DERIVED from the host's own materialized resources so a fresh `gen.app`
  is erasure-complete by construction.

  Returns `%{blind_index_erasure_specs: [...], file_erasure_specs: [...]}`:

    * one `blind_index_erasure_spec` per **registered** derived-linkable column
      (`Samen.DerivedLinkable`) — `email_bidx` on Credential/Invitation (subject_column
      `"id"`), `sent_to_bidx` on AuthToken (subject_column `"credential_id"`). An
      UNregistered `_bidx` column is deliberately NOT auto-covered — the completeness
      gate fails it so a new blind index must be registered, never silently activated.
    * one `file_erasure_spec` per **subject-linked** `storage_key` resource (one carrying
      a data-subject field — `uploaded_by_id` for a blob *uploaded BY* a subject, or a
      domain subject-FK like `person_id` for a blob *ABOUT* a subject, ADR-046 §7 #5).
      Org-asset blobs (no subject field, e.g. CMS `Media`) are org-lifecycle, not
      per-subject-erasure residues, and get no subject-keyed spec. (A host with a
      legitimate retention obligation on some about-a-subject blobs adds a `:hold?`
      predicate to the derived spec — the retention-hold exception; see `Samen.Files.Erasure`.)

  Options are passed to `Samen.Erasure.Completeness.resources/1` (`:resources`/`:domains`/
  `:otp_app`) so tests can derive against an explicit resource list.

  A2 (ADR-047 §7.4, §9#4 TAKEN): the derived map also carries one `retention_specs`
  entry per **vault-routed transcript** resource (a `pii do` block declaring
  `:transcript` — `Samen.AI.Agent.Run` is the first) — the default 90-day `:shred`
  retention arm keyed on the row's OWN id (the per-row crypto-shred unit), because a
  transcript's DEK is keyed on the run, not on any person the run discussed, so
  subject-level reach is by retention only. The window is host-configurable
  (`config :samen_core, Samen.AI.Agent, transcript_retention_days: n`); the derived arm
  is what makes `mix samen.gen.app` erasure-complete by construction and what the
  erasure-completeness gate's transcript arm asserts.
  """
  @spec default_specs(keyword()) :: %{
          blind_index_erasure_specs: [map()],
          file_erasure_specs: [map()],
          retention_specs: [map()]
        }
  def default_specs(opts \\ []) do
    residues = Samen.Erasure.Completeness.discover(opts)

    bidx =
      for r <- residues.derived_linkable, r.registered? do
        %{
          table_name: r.table,
          bidx_column: r.column,
          subject_column: r.subject_column,
          label: spec_label(r.resource)
        }
      end

    files =
      for r <- residues.storage_key, r.subject_field do
        %{file_module: r.resource, subject_field: r.subject_field}
      end

    transcripts =
      for r <- residues.transcript do
        %{
          resource: r.resource,
          ttl_seconds: transcript_retention_days() * 86_400,
          action: :shred,
          subject_field: :id,
          timestamp_field: :inserted_at
        }
      end

    %{blind_index_erasure_specs: bidx, file_erasure_specs: files, retention_specs: transcripts}
  end

  # The ratified transcript retention window (ADR-047 §9#4 TAKEN: 90 days; hosts may
  # lengthen or shorten). Fail-closed shape: junk config degrades to the ratified 90.
  defp transcript_retention_days do
    case Application.get_env(:samen_core, Samen.AI.Agent, [])[:transcript_retention_days] do
      n when is_integer(n) and n > 0 -> n
      _ -> 90
    end
  end

  @doc """
  Install the derived erasure specs into `:samen_core` application env, so the erasure
  ARMS (`Samen.Auth.BlindIndexErasure` / `Samen.Files.Erasure`) actually fire for this
  host's resources. Called once at `application.ex` start (the Oban `install_defaults/1`
  seam's twin) and by `mix samen.verify.erasure_completeness` before it checks.

  Idempotent. Returns the installed spec map.

  A2: the derived transcript `retention_specs` are MERGED into `:samen_core,
  :retention_specs` — appended only for resources the host has not already registered a
  spec for (host entries always win; a host tightening the window is never clobbered
  back to the default). The `Samen.Retention.SweepWorker` daily cron then enforces them
  with zero host wiring.
  """
  @spec install_default_specs(keyword()) :: %{
          blind_index_erasure_specs: [map()],
          file_erasure_specs: [map()],
          retention_specs: [map()]
        }
  def install_default_specs(opts \\ []) do
    specs = default_specs(opts)
    Application.put_env(:samen_core, :blind_index_erasure_specs, specs.blind_index_erasure_specs)
    Application.put_env(:samen_core, :file_erasure_specs, specs.file_erasure_specs)

    existing = Application.get_env(:samen_core, :retention_specs, [])

    host_covered =
      MapSet.new(existing, fn spec -> spec |> Samen.Retention.Spec.normalize() |> Map.get(:resource) end)

    derived_new =
      Enum.reject(specs.retention_specs, fn spec -> MapSet.member?(host_covered, spec.resource) end)

    Application.put_env(:samen_core, :retention_specs, existing ++ derived_new)
    specs
  end

  # A short human label for the token-only erasure report (never PII).
  defp spec_label(resource) do
    resource |> Module.split() |> List.last() |> Macro.underscore()
  end

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

    # The blind-index erasure arm (ADR-046 §4.1 D1; amends ADR-035 §4.1): the registered
    # `email_bidx` specs (or the config default). Fires ONLY on principal-account erasure
    # (subject == the credential/invitation owner — matched on the row's own key), never a
    # per-tenant data-subject shred (which would break the org-less human's cross-org login).
    bidx_specs = Keyword.get(opts, :bidx_specs)

    # The Tier-1 custom-bag erasure arm (ADR-046 §4.2 D3): the registered `custom` bag
    # specs (or the config default). Per-KEY redaction of `pii_declared: true` plaintext
    # keys in the sealed jsonb bag (key-shred cannot reach plaintext-in-bag; NonPii is
    # whole-column). Empty when no spec is registered.
    custom_bag_specs = Keyword.get(opts, :custom_bag_specs)

    # STEP 1 — destroy the key FIRST, outside the DB tx. This is the load-bearing
    # act. It is the ONLY thing that can make the guarantee fail closed (if the
    # key store is unreachable we must NOT proceed and NOT fabricate an
    # attestation).
    case Kms.shred(subject_id) do
      {:ok, attestation} ->
        seal_db_tiers(subject_id, attestation, :from_state, actor_id, org_id, r, rollup_opts, file_opts, bidx_specs, custom_bag_specs)

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

        seal_db_tiers(subject_id, absent_att, "absent", actor_id, org_id, r, rollup_opts, file_opts, bidx_specs, custom_bag_specs)

      {:error, reason} ->
        # Key store unreachable (outage) — FAIL CLOSED. No sentinel, no report,
        # no fabricated attestation. The caller retries when the store heals.
        {:error, {:kms_shred_failed, reason}}
    end
  end

  # STEP 2–5 in one transaction. `outcome_mode` is `:from_state` (derive from the
  # seal result — "shredded" on the first call that seals rows, "already_shredded"
  # on an idempotent later call) or a fixed string (e.g. "absent").
  defp seal_db_tiers(subject_id, attestation, outcome_mode, actor_id, org_id, r, rollup_opts, file_opts, bidx_specs, custom_bag_specs) do
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
      # STEP 3d — blind-index erasure arm (ADR-046 §4.1 D1; amends ADR-035 §4.1). The
      # recomputable `email_bidx` HMAC lives OUTSIDE the per-subject-DEK envelope (it is
      # keyed on the shared, permanently-un-shreddable `sys:bidx`), so key-shred does not
      # reach it: left as-is it keeps an erased subject's email confirmable forever via an
      # equality oracle. This arm tombstones `email_bidx` to a fresh random sentinel — but
      # ONLY on principal-account erasure (the arm matches the credential/invitation OWNER's
      # own key; a per-tenant data-subject shred matches zero rows, so the org-less human's
      # cross-org login is never broken). Runs INSIDE the tx, fail-closed (pure in-DB write).
      |> Ecto.Multi.run(:blind_index, fn repo, _changes ->
        {:ok, Samen.Auth.BlindIndexErasure.erase_subject(subject_id, repo, bidx_specs: bidx_specs)}
      end)
      # STEP 3e — Tier-1 custom-bag erasure arm (ADR-046 §4.2 D3). A `pii_declared: true`
      # custom field stores PLAINTEXT in the sealed `custom` jsonb bag (never vaulted), so
      # key-shred does not reach it and NonPii (whole-column) cannot redact it key-by-key.
      # This arm removes exactly the org's pii_declared keys from the subject's bag rows.
      # Runs INSIDE the tx, fail-closed (pure in-DB write).
      |> Ecto.Multi.run(:custom_bag, fn repo, _changes ->
        {:ok, Samen.CustomFields.Erasure.erase_subject(subject_id, repo, custom_bag_specs: custom_bag_specs)}
      end)
      # STEP 5 (built here, needs step 2/3/3b/3c results) — the erasure report.
      |> Ecto.Multi.run(:report, fn repo, changes ->
        {sealed, _} = changes.seal_vault
        %{count: redacted, details: redaction_details} = changes.redact_non_pii
        rollup_report = changes.rollups
        file_report = changes.file_blobs
        blind_index_report = changes.blind_index
        custom_bag_report = changes.custom_bag

        tiers =
          build_tiers(subject_id, attestation, sealed, redaction_details, rollup_report, file_report, blind_index_report, custom_bag_report, repo)
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

  defp build_tiers(subject_id, attestation, sealed, redaction_details, rollup_report, file_report, blind_index_report, custom_bag_report, repo) do
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
      "file_blobs" => file_report,
      # Blind-index tier (ADR-046 §4.1 D1): the per-resource report of `email_bidx`
      # columns tombstoned for the subject (principal-account erasure only). Empty when
      # no blind-index spec is registered, or when this is a per-tenant data-subject shred
      # (no owning-principal row matches). Token-only (counts + resource label).
      "blind_index" => blind_index_report,
      # Custom-bag tier (ADR-046 §4.2 D3): the per-resource report of `pii_declared`
      # bag keys redacted from the subject's rows. Empty when no custom-bag spec is
      # registered. Token-only (row/key counts + resource label, never a key value).
      "custom_bag" => custom_bag_report
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
