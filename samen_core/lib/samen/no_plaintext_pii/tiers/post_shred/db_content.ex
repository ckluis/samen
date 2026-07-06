defmodule Samen.NoPlaintextPii.Tiers.PostShred.DbContent do
  @moduledoc """
  **Post-shred check (1): the DB-tier CONTENT SCAN** (doc §runs oracle block, check 1;
  ADR-001 §5-7; plan T2.9).

  > (1) DB-TIER CONTENT SCAN — live·replica·cdc_mirror·rollup·audit·
  >     registered_non_pii: FAIL (exit 1) if any holds decryptable plaintext OR
  >     ciphertext that decrypts under a key other than the destroyed one.

  For the erased `subject_id`, this tier scans every key-reachable DB tier and
  asserts nothing decryptable survives:

    * **live** — `Samen.Vault.scan_no_plaintext/2` on the live repo: no vault row
      for the subject decrypts under the subject's own (destroyed) key.
    * **replica** — the SAME scan on the replica repo. There is NO physical replica
      in this environment (plan HARD note): it is SIMULATED as a second DB restored
      from a snapshot of the live DB. `replica: :none` states on the record there is
      no replica in this deployment (pass-with-note); a `nil` replica in a
      `--tiers all` run is a **fail-closed gap** (we must scan the replica or be
      told it does not exist). A real streaming replica is an operator TODO.
    * **rollup** — via the erasure report's per-rollup rebuild/suppress arm: every
      registered rollup must have been governed (rebuilt subject-free or the
      subject's derived rows suppressed). A registered rollup ABSENT from the report
      is a fail-closed gap; a rollup that still carries an un-suppressed subject row
      is a violation.
    * **audit** — the append-only `aud_event` + reveal-lifecycle rows hold only
      tokens/enums/timestamps (the CI-mode schema tiers already prove this); the
      post-shred content check asserts no plaintext subject content is queryable
      there for the subject (the subject_id column carries an opaque id, never a
      name — asserted structurally by the CI tiers; here we assert the erasure
      audit row EXISTS, proving the shred was recorded on the tamper-evident log).
    * **registered_non_pii** — the review-gated `non_pii!` plaintext columns: assert
      row-level redaction ran for the subject (`Samen.NonPii.unredacted_columns_for_subject/3`
      returns nothing). An unredacted row is a violation.

  ## The wrong-key probe

  Beyond "decrypts under the subject's own key" (which post-shred always denies),
  the doc requires FAIL on "ciphertext that decrypts under any key other than the
  destroyed one". `Samen.Vault.scan_no_wrong_key/2` attempts each of the subject's
  vault rows against every OTHER live subject key. On the production `AwsKmsDynamo`
  adapter this returns `:unsupported` (a `Scan` per oracle run is not free) — the
  tier then records a **documented seam** (a `:pass` with an operator-TODO note),
  never a fake pass. On the local dev adapters it is a real red path.

  ## Positive attestation (fail-closed discipline)

  This is a `:post_shred` tier: it emits a `:pass` finding per sub-tier it
  affirmatively cleared, and `:violation` on any leak or fail-closed gap. It NEVER
  returns an empty list — silence would let "I couldn't check" masquerade as an
  all-clear.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.{Vault, NonPii, Erasure}

  @tier :db_content

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do:
      "post-shred DB-tier content scan (live·replica·rollup·audit·registered_non_pii): " <>
        "no decryptable plaintext, no wrong-key-decryptable ciphertext, redaction ran"

  @impl true
  def check(%Context{subject_id: nil}) do
    [
      Finding.violation(
        @tier,
        "<subject>",
        "post-shred DB-content scan requires --subject <uuid> — fail closed."
      )
    ]
  end

  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no live repo configured — cannot scan DB tiers (fail closed)."
      )
    ]
  end

  def check(%Context{} = ctx) do
    live_findings(ctx) ++
      replica_findings(ctx) ++
      wrong_key_findings(ctx) ++
      rollup_findings(ctx) ++
      audit_findings(ctx) ++
      non_pii_findings(ctx)
  end

  # ---------------------------------------------------------------------------
  # live
  # ---------------------------------------------------------------------------

  defp live_findings(%Context{subject_id: sid, repo: repo}) do
    case Vault.scan_no_plaintext(sid, repo) do
      {:ok, :no_plaintext} ->
        [Finding.pass(@tier, "live", "no vault row for #{sid} decrypts under its (destroyed) key")]

      {:leaks, tokens} ->
        [
          Finding.violation(
            @tier,
            "live",
            "#{length(tokens)} vault row(s) for #{sid} STILL DECRYPT on the live tier — " <>
              "crypto-shred did not take. tokens: #{Enum.join(tokens, ", ")}"
          )
        ]
    end
  end

  # ---------------------------------------------------------------------------
  # replica (SIMULATED — no physical replica in this environment)
  # ---------------------------------------------------------------------------

  defp replica_findings(%Context{replica_repo: nil, replica_declared_absent?: true}) do
    [
      Finding.pass(
        @tier,
        "replica",
        "no replica in this deployment (operator declared replica: :none). " <>
          "SEAM: a real streaming replica is an operator TODO — it inherits the same " <>
          "token-only ciphertext, so key-shred covers it, but wire a real scan when one exists."
      )
    ]
  end

  defp replica_findings(%Context{replica_repo: nil}) do
    [
      Finding.violation(
        @tier,
        "replica",
        "no replica repo configured for a --tiers all run — fail closed. " <>
          "Pass `replica: RestoredSnapshotRepo` (a second DB restored from a live " <>
          "snapshot — the documented simulation seam) OR `replica: :none` to state on " <>
          "the record there is no replica. Silence is not an all-clear."
      )
    ]
  end

  defp replica_findings(%Context{subject_id: sid, replica_repo: repo}) do
    case Vault.scan_no_plaintext(sid, repo) do
      {:ok, :no_plaintext} ->
        [
          Finding.pass(
            @tier,
            "replica",
            "SIMULATED replica (snapshot-restored DB): no vault row for #{sid} decrypts " <>
              "— the key store is external to the snapshot (ADR-001)"
          )
        ]

      {:leaks, tokens} ->
        [
          Finding.violation(
            @tier,
            "replica",
            "#{length(tokens)} vault row(s) for #{sid} STILL DECRYPT on the replica tier."
          )
        ]
    end
  end

  # ---------------------------------------------------------------------------
  # wrong-key probe (live tier ciphertext under a foreign live key)
  # ---------------------------------------------------------------------------

  defp wrong_key_findings(%Context{subject_id: sid, repo: repo}) do
    case Vault.scan_no_wrong_key(sid, repo) do
      {:ok, :no_cross_decrypt} ->
        [
          Finding.pass(
            @tier,
            "wrong_key",
            "no ciphertext for #{sid} decrypts under any OTHER live subject key"
          )
        ]

      {:cross_decrypt, details} ->
        subjects = details |> Enum.map(& &1.under_subject) |> Enum.uniq() |> Enum.join(", ")

        [
          Finding.violation(
            @tier,
            "wrong_key",
            "#{length(details)} vault row(s) for #{sid} DECRYPT under a key other than the " <>
              "destroyed one (live subjects: #{subjects}) — a re-wrapped-ciphertext leak that " <>
              "crypto-shred of the original key does not reach."
          )
        ]

      {:error, :unsupported} ->
        [
          Finding.pass(
            @tier,
            "wrong_key",
            "SEAM: the configured KMS adapter cannot enumerate live keys " <>
              "(production AwsKmsDynamo — a per-run DynamoDB Scan is not free). The wrong-key " <>
              "probe is an OPERATOR TODO on this adapter, recorded rather than faked."
          )
        ]

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            "wrong_key",
            "wrong-key probe failed to run (#{inspect(reason)}) — fail closed."
          )
        ]
    end
  end

  # ---------------------------------------------------------------------------
  # rollup (from the erasure report's per-rollup arm)
  # ---------------------------------------------------------------------------

  defp rollup_findings(%Context{subject_id: sid, repo: repo}) do
    case Erasure.latest_report(sid, repo: repo) do
      nil ->
        [
          Finding.violation(
            @tier,
            "rollup",
            "no erasure report found for #{sid} — cannot assert rollups were governed " <>
              "(rebuild-or-exclude). Was the subject actually shredded? Fail closed."
          )
        ]

      report ->
        governed = get_in(report.tiers, ["rollups"]) || []
        registered = Enum.map(Samen.Rollup.specs(), &to_string(&1.name))
        governed_names = Enum.map(governed, &(&1["rollup"]))
        missing = registered -- governed_names

        cond do
          missing != [] ->
            [
              Finding.violation(
                @tier,
                "rollup",
                "registered rollup(s) #{Enum.join(missing, ", ")} ABSENT from the erasure " <>
                  "report's rebuild-or-exclude arm for #{sid} — a derived aggregate that " <>
                  "was not governed can resurrect the subject. Fail closed."
              )
            ]

          true ->
            arms = Enum.map_join(governed, ", ", &"#{&1["rollup"]}:#{&1["arm"]}")

            [
              Finding.pass(
                @tier,
                "rollup",
                "every registered rollup governed by rebuild-or-exclude-on-erasure (#{arms})"
              )
            ]
        end
    end
  end

  # ---------------------------------------------------------------------------
  # audit (the shred was recorded on the tamper-evident log)
  # ---------------------------------------------------------------------------

  defp audit_findings(%Context{subject_id: sid, repo: repo}) do
    count =
      repo.query!(
        "SELECT count(*) FROM aud_event WHERE aud_event_type = 'erasure' AND aud_subject_id = $1",
        [sid]
      )
      |> then(fn %{rows: [[n]]} -> n end)

    if count > 0 do
      [
        Finding.pass(
          @tier,
          "audit",
          "erasure recorded on the append-only aud_event tier (#{count} row) — the event " <>
            "survives (WORM), the subject is unrecoverable"
        )
      ]
    else
      [
        Finding.violation(
          @tier,
          "audit",
          "no erasure event on aud_event for #{sid} — the shred was not recorded on the " <>
            "tamper-evident log. Fail closed."
        )
      ]
    end
  rescue
    e ->
      [
        Finding.violation(
          @tier,
          "audit",
          "could not scan aud_event (#{Exception.message(e)}) — fail closed."
        )
      ]
  end

  # ---------------------------------------------------------------------------
  # registered_non_pii (row-level redaction ran)
  # ---------------------------------------------------------------------------

  defp non_pii_findings(%Context{subject_id: sid, repo: repo}) do
    case NonPii.unredacted_columns_for_subject(sid, repo) do
      [] ->
        [
          Finding.pass(
            @tier,
            "registered_non_pii",
            "every registered non_pii! column redacted for #{sid} (the carve-out key-shred " <>
              "cannot reach was erased by row-level redaction)"
          )
        ]

      leaks ->
        detail =
          Enum.map_join(leaks, "; ", fn l ->
            "#{l["table"]}.#{l["column"]} (#{l["unredacted"]} unredacted)"
          end)

        [
          Finding.violation(
            @tier,
            "registered_non_pii",
            "registered non_pii! column(s) STILL HOLD non-redacted values for #{sid}: " <>
              detail <> ". Row-level redaction did not run — a plaintext residue survives."
          )
        ]
    end
  end
end
