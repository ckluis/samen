defmodule Samen.PostShredOracleTest do
  @moduledoc """
  T2.9 — THE DESTRUCTION ORACLE, post-shred mode
  (`mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`).

  Structure (plan HARD RULES: every guarantee ships a red-path + an anti-tautology
  probe):

    * GREEN PATH — create a subject, spread PII across every tier (vault + rollup +
      audit + non_pii!), shred via `Samen.Erasure.shred/2`, run the post-shred
      oracle: ZERO violations, positive `:pass` attestations from all three checks.

    * RED PATHS — one per tier, each MUST produce a `:violation` (the oracle would
      exit 1):
        RP-1  live-tier decryptable ciphertext (no shred)
        RP-1b wrong-key-decryptable ciphertext (a foreign live key decrypts it)
        RP-1c registered_non_pii! row un-redacted after erasure
        RP-1d a registered rollup absent from the erasure report's rebuild/exclude arm
        RP-2  subject key present in a PITR-sim snapshot (decryptable ciphertext there)
        RP-2b backups_disabled? == false
        RP-3  attest returns :absent (positive tombstone required)
        RP-3b attest returns :active (key still exists)
        RP-4  trace-sink schema admits a string field (name-carrier surface)
        RP-4b pseudonym still computable after shred
        RP-replica no replica repo + no `:none` declaration => fail closed

    * ANTI-TAUTOLOGY — the green path proves the oracle is non-vacuous: with a real
      shred, every check emits a `:pass`, so a red-path flip to `:violation` is a
      real discrimination, not "the check never fires". Documented in the report;
      the sabotage-in-scratch-copy probe on checks 1-3 is run OUTSIDE the suite (see
      the report), this suite is the in-code discriminating-pair evidence.
  """
  use ExUnit.Case, async: false

  alias Samen.{Erasure, Vault, NonPii, Kms}
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.{Finding, Context}

  alias Samen.NoPlaintextPii.Tiers.PostShred

  import Ecto.Query, only: [from: 2]

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
      Application.delete_env(:samen_core, :cdc_mirror_repo)
      Application.delete_env(:samen_core, :cdc)
    end)

    :ok
  end

  # UUID subject ids: the vault stores them as strings, AND the non_pii! patient
  # row keys on `pat_patient.id` (a uuid column), so the subject must be a valid
  # UUID for both surfaces.
  defp subj, do: Ecto.UUID.generate()

  # Seed the subject across every key-reachable tier: vault (3 fields) + rollup-
  # feeding aud_event rows + a registered non_pii! plaintext column.
  defp seed_all_tiers(subject_id) do
    {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "gone@t29.test", @repo)
    {:ok, _} = Vault.store_field(subject_id, :pii_name, :full_name, "Gone Subject", @repo)
    {:ok, _} = Vault.store_field(subject_id, :pii_dob, :dob, "1985-05-05", @repo)

    # aud_event rows the rollup summarises (the rebuild-or-exclude arm governs them).
    for i <- 1..3 do
      {:ok, _} =
        Samen.AuditEvent.insert(@repo, %{
          event_type: "system",
          subject_id: subject_id,
          correlation_id: Ecto.UUID.generate(),
          detail: "evt-#{i}",
          occurred_at: DateTime.new!(~D[2026-07-04], ~T[12:00:00.000000], "Etc/UTC")
        })
    end

    :ok
  end

  # Register a non_pii! plaintext column on a scratch table (TEXT subject column,
  # so no uuid casting) and write a subject value into it (the carve-out key-shred
  # cannot reach — must be row-redacted). Idempotent within a test run.
  @non_pii_table "t29_non_pii_scratch"

  defp register_non_pii_with_value!(subject_id) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "CREATE TABLE IF NOT EXISTS #{@non_pii_table} " <>
        "(t29_id serial primary key, t29_subject_id text, t29_op_note text)",
      []
    )

    on_exit(fn ->
      try do
        Ecto.Adapters.SQL.query!(@repo, "DROP TABLE IF EXISTS #{@non_pii_table}", [])
      rescue
        _ -> :ok
      end
    end)

    {:ok, entry} =
      NonPii.register(%{
        table_name: @non_pii_table,
        column_name: "t29_op_note",
        cleared_by: "alice@example.com",
        reviewed_by: "bob@example.com",
        reason: "Operational note reviewed as non-subject PII.",
        subject_column: "t29_subject_id",
        redaction: "[REDACTED]",
        repo: @repo
      })

    # A row carrying the subject value in the non_pii! column.
    Ecto.Adapters.SQL.query!(
      @repo,
      "INSERT INTO #{@non_pii_table} (t29_subject_id, t29_op_note) VALUES ($1, $2)",
      [subject_id, "a sensitive operational note"]
    )

    entry
  end

  # A "PITR snapshot" simulation in-band: a Context that scans the SAME repo the
  # live tier uses. Post-shred, that repo's ciphertext no longer decrypts, so the
  # key-absence assertion holds — the same shape as scanning a restored pg_dump.
  # (The physical pg_dump round-trip is covered by vault_pitr_test.exs; here we
  # exercise the TIER logic against a repo whose key store is gone.)
  defp post_shred_context(subject_id, overrides \\ []) do
    base = [
      repo: @repo,
      subject_id: subject_id,
      resources: [],
      replica: :none
    ]

    Context.build(Keyword.merge(base, overrides))
  end

  # ======================================================================
  # GREEN PATH
  # ======================================================================

  describe "GREEN PATH — post-shred oracle passes on a properly erased subject" do
    test "all three checks + ingress + cdc-stub emit passes, zero violations" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      register_non_pii_with_value!(subject_id)

      {:ok, _} = Samen.Rollup.rebuild_all(@repo)
      assert {:ok, %{report: _}} = Erasure.shred(subject_id, repo: @repo)

      ctx = post_shred_context(subject_id)
      findings = run_all_tiers(ctx)

      violations = NoPlaintextPii.violations(findings)

      assert violations == [],
             "GREEN PATH must have zero violations, got:\n" <>
               Enum.map_join(violations, "\n", &Finding.format/1)

      passes = NoPlaintextPii.passes(findings)

      # Every check must speak positively (fail-closed discipline: no silent tier).
      tiers_that_passed = passes |> Enum.map(& &1.tier) |> Enum.uniq()
      assert :db_content in tiers_that_passed
      assert :backup_pitr in tiers_that_passed
      assert :kms_attestation in tiers_that_passed
      assert :trace_sink in tiers_that_passed
      assert :cdc_mirror in tiers_that_passed

      # DB-content live scan + registered_non_pii + rollup all attested.
      db_subjects = passes |> Enum.filter(&(&1.tier == :db_content)) |> Enum.map(& &1.subject)
      assert "live" in db_subjects
      assert "registered_non_pii" in db_subjects
      assert "rollup" in db_subjects
      assert "wrong_key" in db_subjects
      assert "audit" in db_subjects
    end

    test "the default post_shred_tiers roster is the three checks + ingress + cdc-stub" do
      names = Enum.map(NoPlaintextPii.post_shred_tiers(), & &1.tier_name())
      assert names == [:db_content, :backup_pitr, :kms_attestation, :trace_sink, :cdc_mirror]
      # And they are ALL :post_shred mode.
      assert Enum.all?(NoPlaintextPii.post_shred_tiers(), &(&1.mode() == :post_shred))
    end
  end

  # ======================================================================
  # CHECK 1 — DB-tier content scan red paths
  # ======================================================================

  describe "CHECK 1 (DB content) red paths" do
    @tag :red_path
    test "RP-1: live-tier decryptable ciphertext (NO shred) is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      # No shred → the vault rows still decrypt → live tier must FAIL.

      findings = PostShred.DbContent.check(post_shred_context(subject_id))
      v = live_violation(findings)

      assert v != nil, "live-tier decryptable ciphertext must be a violation"
      assert v.detail =~ "STILL DECRYPT"
    end

    @tag :red_path
    test "RP-1b: ciphertext that decrypts under a WRONG (other live) key is a violation" do
      subject_id = subj()
      other_id = subj()

      # Seed a vault row for `subject_id`, then re-encrypt its ciphertext under a
      # DIFFERENT, still-live subject key (`other_id`) — the "re-wrapped under a
      # foreign key" leak crypto-shred of the original key does not reach.
      {:ok, token} = Vault.store_field(subject_id, :pii_email, :emails, "leak@t29.test", @repo)
      :ok = Vault.ensure_subject_key(other_id, @repo)
      {:ok, other_dek} = Kms.adapter().unwrap(other_id)
      foreign_ct = Samen.Kms.Crypto.encrypt(other_dek, "leak@t29.test")

      @repo.update_all(
        from(r in Samen.Vault.VaultRow, where: r.token == ^token),
        set: [ciphertext: foreign_ct]
      )

      # Now shred the ORIGINAL subject key. Its own key is gone, but `other_id` is
      # live and decrypts the row.
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      findings = PostShred.DbContent.check(post_shred_context(subject_id))
      v = Enum.find(findings, &(&1.tier == :db_content and &1.subject == "wrong_key" and &1.severity == :violation))

      assert v != nil,
             "wrong-key-decryptable ciphertext must be a violation, got:\n" <>
               Enum.map_join(findings, "\n", &Finding.format/1)

      assert v.detail =~ "other than the destroyed one"
    end

    @tag :red_path
    test "RP-1c: an un-redacted registered non_pii! row after erasure is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      register_non_pii_with_value!(subject_id)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      # Sabotage: put the plaintext BACK into the non_pii! column (simulate the
      # redaction arm not having run).
      Ecto.Adapters.SQL.query!(
        @repo,
        "UPDATE #{@non_pii_table} SET t29_op_note = $2 WHERE t29_subject_id = $1",
        [subject_id, "un-redacted plaintext residue"]
      )

      findings = PostShred.DbContent.check(post_shred_context(subject_id))

      v =
        Enum.find(
          findings,
          &(&1.tier == :db_content and &1.subject == "registered_non_pii" and
              &1.severity == :violation)
        )

      assert v != nil, "an un-redacted non_pii! row must be a violation"
      assert v.detail =~ "non-redacted"
    end

    @tag :red_path
    test "RP-1d: a registered rollup absent from the erasure report arm is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      {:ok, %{report: report}} = Erasure.shred(subject_id, repo: @repo)

      # Sabotage the persisted report: drop the rollup arm so a registered rollup
      # is un-governed (the fail-closed gap the tier must catch).
      @repo.update_all(
        from(r in Samen.Erasure.Report, where: r.id == ^report.id),
        set: [tiers: Map.put(report.tiers, "rollups", [])]
      )

      findings = PostShred.DbContent.check(post_shred_context(subject_id))

      v =
        Enum.find(
          findings,
          &(&1.tier == :db_content and &1.subject == "rollup" and &1.severity == :violation)
        )

      assert v != nil,
             "a registered rollup absent from the report must be a fail-closed violation"

      assert v.detail =~ "ABSENT from the erasure report"
    end
  end

  # ======================================================================
  # CHECK 2 — backup/PITR-history scan red paths
  # ======================================================================

  describe "CHECK 2 (backup/PITR) red paths" do
    @tag :red_path
    test "RP-2: decryptable ciphertext in a PITR-sim snapshot is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      # NO shred: the same repo, scanned as a 'PITR snapshot', still decrypts.

      ctx = post_shred_context(subject_id, pitr_repos: [@repo])
      findings = PostShred.BackupPitr.check(ctx)

      v =
        Enum.find(
          findings,
          &(&1.tier == :backup_pitr and &1.subject == "pitr_snapshot_1" and
              &1.severity == :violation)
        )

      assert v != nil,
             "a PITR snapshot whose ciphertext still decrypts must be a violation, got:\n" <>
               Enum.map_join(findings, "\n", &Finding.format/1)
    end

    @tag :red_path
    test "RP-2b: backups_disabled? == false is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      # Swap in an adapter whose backups_disabled?/0 is false.
      Application.put_env(:samen_core, :kms_adapter, __MODULE__.BackupsOnAdapter)
      on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)

      findings = PostShred.BackupPitr.check(post_shred_context(subject_id))

      v =
        Enum.find(
          findings,
          &(&1.tier == :backup_pitr and &1.subject == "kms_store_backups" and
              &1.severity == :violation)
        )

      assert v != nil, "backups_disabled? == false must be a violation"
      assert v.detail =~ "ENABLED"
    end
  end

  # ======================================================================
  # CHECK 3 — KMS destruction attestation red paths
  # ======================================================================

  describe "CHECK 3 (KMS attestation) red paths" do
    @tag :red_path
    test "RP-3: attest returning :absent is a violation (positive tombstone required)" do
      # A subject that was NEVER keyed → attest returns :absent. :absent == FAIL.
      subject_id = subj()

      findings = PostShred.KmsAttestation.check(post_shred_context(subject_id))

      v = Enum.find(findings, &(&1.tier == :kms_attestation and &1.severity == :violation))

      assert v != nil, ":absent must be a violation"

      assert Enum.map_join(findings, "\n", &Finding.format/1) =~ ":absent == FAIL"
    end

    @tag :red_path
    test "RP-3b: attest returning :active (key still exists, no shred) is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      # No shred → the key is :active.

      findings = PostShred.KmsAttestation.check(post_shred_context(subject_id))

      v = Enum.find(findings, &(&1.tier == :kms_attestation and &1.severity == :violation))

      assert v != nil, ":active must be a violation"
      assert Enum.map_join(findings, "\n", &Finding.format/1) =~ ":active == FAIL"
    end
  end

  # ======================================================================
  # INGRESS-CLASS trace-sink red paths
  # ======================================================================

  describe "trace-sink INGRESS-class red paths" do
    @tag :red_path
    test "RP-4: a string field smuggled into the wide-event schema is a tier violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      # Inject a deliberately-broken schema (a :string name-carrier field) via the
      # documented test seam and drive the REAL tier — it must map the schema hole
      # to a :violation.
      Application.put_env(:samen_core, :wide_event_schema_override, [
        {:request_id, :opaque_id, []},
        {:leaked_name, :string, []}
      ])

      on_exit(fn -> Application.delete_env(:samen_core, :wide_event_schema_override) end)

      findings = PostShred.TraceSinkIngress.check(post_shred_context(subject_id))

      v =
        Enum.find(
          findings,
          &(&1.tier == :trace_sink and &1.subject == "schema" and &1.severity == :violation)
        )

      assert v != nil,
             "a :string wide-event field must be a trace-sink ingress violation, got:\n" <>
               Enum.map_join(findings, "\n", &Finding.format/1)

      assert v.detail =~ "name-carrier"

      # Anti-tautology: with the override REMOVED, the same tier passes the schema.
      Application.delete_env(:samen_core, :wide_event_schema_override)
      clean = PostShred.TraceSinkIngress.check(post_shred_context(subject_id))

      assert Enum.any?(
               clean,
               &(&1.tier == :trace_sink and &1.subject == "schema" and &1.severity == :pass)
             ),
             "with the canonical schema the ingress assertion must pass"
    end

    @tag :red_path
    test "RP-4b: a pseudonym still computable after shred is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      # No shred → the pseudonym IS still computable → tier must flag it.

      findings = PostShred.TraceSinkIngress.check(post_shred_context(subject_id))

      v =
        Enum.find(
          findings,
          &(&1.tier == :trace_sink and &1.subject == "pseudonym" and &1.severity == :violation)
        )

      assert v != nil, "a still-computable pseudonym after shred must be a violation"
      assert v.detail =~ "STILL COMPUTABLE"
    end

    test "GREEN: after shred the pseudonym unlinks (a pass, not a violation)" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      findings = PostShred.TraceSinkIngress.check(post_shred_context(subject_id))

      assert Enum.any?(
               findings,
               &(&1.tier == :trace_sink and &1.subject == "pseudonym" and &1.severity == :pass)
             )

      assert NoPlaintextPii.violations(findings) == []
    end
  end

  # ======================================================================
  # replica fail-closed
  # ======================================================================

  describe "replica tier fail-closed" do
    @tag :red_path
    test "RP-replica: no replica repo + no :none declaration is a violation" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      # Build a context WITHOUT declaring the replica (no :replica key at all).
      ctx =
        Context.build(repo: @repo, subject_id: subject_id, resources: [])

      findings = PostShred.DbContent.check(ctx)

      v =
        Enum.find(
          findings,
          &(&1.tier == :db_content and &1.subject == "replica" and &1.severity == :violation)
        )

      assert v != nil, "an undeclared replica in a --tiers all run must fail closed"
      assert v.detail =~ "fail closed"
    end

    test "GREEN: replica: :none passes with a documented seam note" do
      subject_id = subj()
      seed_all_tiers(subject_id)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      findings = PostShred.DbContent.check(post_shred_context(subject_id))

      pass =
        Enum.find(
          findings,
          &(&1.tier == :db_content and &1.subject == "replica" and &1.severity == :pass)
        )

      assert pass != nil
      assert pass.detail =~ "operator TODO"
    end
  end

  # ======================================================================
  # CDC-mirror stub
  # ======================================================================

  describe "CDC-mirror tier (T6.5 — opt-in, default off)" do
    test "inactive by default: a pass stating the mirror is off" do
      subject_id = subj()
      findings = PostShred.CdcMirror.check(post_shred_context(subject_id))
      assert [%Finding{severity: :pass}] = findings
      assert hd(findings).detail =~ "not enabled"
    end

    @tag :red_path
    test "a legacy :cdc_mirror_repo without a :cdc adapter is a fail-closed gap (not a pass)" do
      subject_id = subj()
      Application.put_env(:samen_core, :cdc_mirror_repo, :some_clickhouse_repo)

      findings = PostShred.CdcMirror.check(post_shred_context(subject_id))

      assert [%Finding{severity: :violation}] = findings
      assert hd(findings).detail =~ "fail-closed GAP"
    end
  end

  # ======================================================================
  # ANTI-TAUTOLOGY discriminating pair
  # ======================================================================

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: green shred PASSES the very tiers the red paths FAIL" do
    subject_id = subj()
    seed_all_tiers(subject_id)
    register_non_pii_with_value!(subject_id)
    {:ok, _} = Samen.Rollup.rebuild_all(@repo)
    {:ok, _} = Erasure.shred(subject_id, repo: @repo)

    ctx = post_shred_context(subject_id)

    # The exact tiers the red paths above drove to :violation must here be :pass —
    # proving the checks discriminate (not "never fire" / not "always fire").
    db = PostShred.DbContent.check(ctx)
    assert NoPlaintextPii.violations(db) == []
    assert Enum.any?(db, &(&1.subject == "live" and &1.severity == :pass))
    assert Enum.any?(db, &(&1.subject == "wrong_key" and &1.severity == :pass))
    assert Enum.any?(db, &(&1.subject == "registered_non_pii" and &1.severity == :pass))

    kms = PostShred.KmsAttestation.check(ctx)
    assert NoPlaintextPii.violations(kms) == []
    assert Enum.any?(kms, &(&1.severity == :pass and &1.detail =~ "POSITIVE :shredded"))

    bp = PostShred.BackupPitr.check(ctx)
    assert NoPlaintextPii.violations(bp) == []
    assert Enum.any?(bp, &(&1.subject == "kms_store_backups" and &1.severity == :pass))
  end

  # ======================================================================
  # Exit-code layer (subprocess) — the real CLI contract
  # ======================================================================

  @project_dir Path.expand("../", __DIR__)

  describe "mix task CLI contract (--subject --tiers all)" do
    @tag :exit_code
    test "post-shred mode on a never-keyed subject EXITS 1 (attest :absent == FAIL)" do
      # A random subject that was never keyed → KMS attests :absent → the
      # KmsAttestation check fails → the task exits 1. This proves the full CLI
      # wiring: OptionParser → post-shred dispatch → NoPlaintextPii.run → halt(1).
      # No committed DB rows needed (the KMS store is the FileBacked dir).
      subject_id = Ecto.UUID.generate()

      {output, exit_code} =
        System.cmd(
          "mix",
          [
            "samen.verify.no_plaintext_pii",
            "--subject",
            subject_id,
            "--tiers",
            "all",
            "--replica",
            "none",
            "--domain",
            "SamenCore.Support.Clinical"
          ],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "expected exit 1 for a never-keyed subject (attest :absent), got #{exit_code}.\n#{output}"

      assert output =~ ":absent == FAIL" or output =~ "kms_attestation",
             "expected the KMS attestation failure in output, got:\n#{output}"
    end

    @tag :exit_code
    test "post-shred mode REFUSES --tiers other than all (fail closed)" do
      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.no_plaintext_pii", "--subject", Ecto.UUID.generate(), "--tiers", "some"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code != 0, "a partial-tier post-shred run must be refused"
      assert output =~ "requires `--tiers all`"
    end

    @tag :exit_code
    test "CI mode (no --subject) still exits 0 on the clean app (unchanged)" do
      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.no_plaintext_pii", "--domain", "SamenCore.Support.Clinical"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 0, "CI mode must remain green on the clean app, got:\n#{output}"
      assert output =~ "OK"
    end
  end

  # ======================================================================
  # helpers + fixtures
  # ======================================================================

  defp run_all_tiers(ctx) do
    Enum.flat_map(NoPlaintextPii.post_shred_tiers(), fn tier -> tier.check(ctx) end)
  end

  defp live_violation(findings) do
    Enum.find(
      findings,
      &(&1.tier == :db_content and &1.subject == "live" and &1.severity == :violation)
    )
  end

  # An adapter identical to FileBacked but with backups_disabled?/0 == false
  # (RP-2b). Everything else delegates to FileBacked (which still knows the
  # subject's shredded state from the real shred).
  defmodule BackupsOnAdapter do
    @moduledoc false
    @behaviour Samen.Kms
    alias Samen.Kms.FileBacked

    @impl true
    def generate_subject_key(s), do: FileBacked.generate_subject_key(s)
    @impl true
    def unwrap(s), do: FileBacked.unwrap(s)
    @impl true
    def shred(s), do: FileBacked.shred(s)
    @impl true
    def attest(s), do: FileBacked.attest(s)
    @impl true
    def key_material_present?(s), do: FileBacked.key_material_present?(s)
    @impl true
    def pseudonym(a, b), do: FileBacked.pseudonym(a, b)
    @impl true
    def list_active_subjects, do: FileBacked.list_active_subjects()
    @impl true
    def backups_disabled?, do: false
  end
end
