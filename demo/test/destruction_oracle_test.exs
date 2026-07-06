defmodule Demo.DestructionOracleTest do
  @moduledoc """
  T2.9 END-TO-END on the demo app — THE DESTRUCTION ORACLE
  (`mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`).

  This is the artifact the vision doc says you show an auditor, exercised against
  the demo's OWN resources, repo, config-registered rollup, aud_event tier, and a
  reviewed `non_pii!` column:

    * GREEN — create a Contact subject, spread PII across EVERY tier (vault via the
      real Ash :create action + rollup-feeding aud_event rows + a redacted non_pii!
      column), shred via `Samen.Erasure.shred/2`, run the post-shred oracle
      (`--tiers all`): PASS with positive attestations from all three checks.

    * RED — each seeded violation FAILS the oracle:
        · decryptable ciphertext in the live vault (no shred)
        · an un-redacted non_pii! row after erasure
        · a key present in a PITR-sim snapshot (decryptable ciphertext there)
        · attest :absent
        · backups_disabled? false

  The oracle is driven in-process (sandboxed) via `Samen.NoPlaintextPii.run/1` —
  the SAME code path the `mix samen.verify.no_plaintext_pii --subject --tiers all`
  task drives. The physical committed-data + subprocess exit-code path is covered
  by the T2.5 drill machinery and the kernel `vault_pitr_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Demo.Crm.Contact
  alias Demo.Repo
  alias Samen.{Erasure, NonPii}
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.{Finding, Context}
  alias Samen.NoPlaintextPii.Tiers.PostShred

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    on_exit(fn ->
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
      Application.delete_env(:samen_core, :cdc_mirror_repo)
    end)

    # Register the demo's cnt_notes column as non_pii! (distinct-party reviewers),
    # keyed on the text cnt_subject_id column (the erasure arm matches string ids).
    {:ok, _} =
      NonPii.register(%{
        table_name: "cnt_contact",
        column_name: "cnt_notes",
        cleared_by: "alice@acme.com",
        reviewed_by: "bob@acme.com",
        reason: "Operational notes cleared in security review 2026-07",
        subject_column: "cnt_subject_id",
        redaction: "[REDACTED]",
        repo: Repo
      })

    :ok
  end

  # Create a Contact subject via the real Ash :create action, then spread that
  # subject across every key-reachable tier. Returns {contact, subject_id}.
  # NOTE: the vault subject_id for an Ash-created contact IS the contact's primary
  # key (Samen.Vault.Change keys on the pk), so the subject_id == contact.id.
  defp seed_subject_across_tiers do
    c =
      Contact
      |> Ash.Changeset.for_create(:create, %{
        org_id: Ash.UUID.generate(),
        display_name: "Auditable Contact",
        full_name: %{first: "Erin", last: "Erased"},
        emails: %{primary: "erin@gone.test"},
        dob: ~D[1990-03-03]
      })
      |> Ash.create!()

    subject_id = c.id

    # aud_event rows the demo rollup summarises.
    for i <- 1..4 do
      {:ok, _} =
        Samen.AuditEvent.insert(Repo, %{
          event_type: "system",
          subject_id: subject_id,
          correlation_id: Ecto.UUID.generate(),
          detail: "evt-#{i}",
          occurred_at: DateTime.new!(~D[2026-07-04], ~T[12:00:00.000000], "Etc/UTC")
        })
    end

    # A plaintext note in the non_pii! column + the text subject-id column.
    Repo.query!(
      "UPDATE cnt_contact SET cnt_notes = $1, cnt_subject_id = $2 WHERE cnt_id = $3",
      ["Renewal call notes", subject_id, Ecto.UUID.dump!(subject_id)]
    )

    {c, subject_id}
  end

  defp ctx(subject_id, overrides \\ []) do
    base = [repo: Repo, subject_id: subject_id, resources: [], replica: :none]
    Context.build(Keyword.merge(base, overrides))
  end

  defp run_oracle(subject_id, overrides \\ []) do
    {:ok, findings} =
      NoPlaintextPii.run(
        [
          mode: :post_shred,
          repo: Repo,
          resources: [Demo.Crm.Org, Demo.Crm.Membership, Demo.Crm.Contact],
          subject_id: subject_id,
          replica: :none
        ] ++ overrides
      )

    findings
  end

  # ======================================================================
  # GREEN — the auditor artifact
  # ======================================================================

  describe "GREEN — post-shred oracle passes on a properly erased demo subject" do
    test "--tiers all passes with positive attestations from all three checks" do
      {_c, subject_id} = seed_subject_across_tiers()
      {:ok, _} = Samen.Rollup.rebuild_all(Repo)

      # Erase the subject (the one destruction that shreds every tier at once).
      assert {:ok, %{report: _}} = Erasure.shred(subject_id, repo: Repo)

      findings = run_oracle(subject_id)

      violations = NoPlaintextPii.violations(findings)

      assert violations == [],
             "the demo destruction oracle must PASS post-shred, got:\n" <>
               Enum.map_join(violations, "\n", &Finding.format/1)

      passed_tiers = findings |> NoPlaintextPii.passes() |> Enum.map(& &1.tier) |> Enum.uniq()

      # All three orchestrated checks + ingress + cdc-stub speak positively.
      assert :db_content in passed_tiers
      assert :backup_pitr in passed_tiers
      assert :kms_attestation in passed_tiers
      assert :trace_sink in passed_tiers
      assert :cdc_mirror in passed_tiers
    end
  end

  # ======================================================================
  # RED — each seeded violation FAILS
  # ======================================================================

  describe "RED — each seeded violation fails the demo oracle" do
    @tag :red_path
    test "decryptable ciphertext in the live vault (NO shred) fails" do
      {_c, subject_id} = seed_subject_across_tiers()
      # No shred → live vault still decrypts.

      findings = PostShred.DbContent.check(ctx(subject_id))
      assert NoPlaintextPii.violations(findings) != []

      assert Enum.any?(
               findings,
               &(&1.tier == :db_content and &1.subject == "live" and &1.severity == :violation)
             )
    end

    @tag :red_path
    test "an un-redacted non_pii! row after erasure fails" do
      {_c, subject_id} = seed_subject_across_tiers()
      {:ok, _} = Erasure.shred(subject_id, repo: Repo)

      # Sabotage: write plaintext back into the redacted non_pii! column.
      Repo.query!(
        "UPDATE cnt_contact SET cnt_notes = $1 WHERE cnt_subject_id = $2",
        ["un-redacted residue", subject_id]
      )

      findings = PostShred.DbContent.check(ctx(subject_id))

      assert Enum.any?(
               findings,
               &(&1.tier == :db_content and &1.subject == "registered_non_pii" and
                   &1.severity == :violation)
             )
    end

    @tag :red_path
    test "a key present in a PITR-sim snapshot (decryptable) fails" do
      {_c, subject_id} = seed_subject_across_tiers()
      # No shred: scanning the same repo as a 'PITR snapshot' still decrypts.

      findings = PostShred.BackupPitr.check(ctx(subject_id, pitr_repos: [Repo]))

      assert Enum.any?(
               findings,
               &(&1.tier == :backup_pitr and &1.subject == "pitr_snapshot_1" and
                   &1.severity == :violation)
             )
    end

    @tag :red_path
    test "KMS attestation :absent fails" do
      # A subject never keyed → attest :absent → FAIL (positive tombstone required).
      subject_id = Ash.UUID.generate()

      findings = PostShred.KmsAttestation.check(ctx(subject_id))
      assert NoPlaintextPii.violations(findings) != []
      assert Enum.map_join(findings, "\n", &Finding.format/1) =~ ":absent == FAIL"
    end

    @tag :red_path
    test "backups_disabled? == false fails" do
      {_c, subject_id} = seed_subject_across_tiers()
      {:ok, _} = Erasure.shred(subject_id, repo: Repo)

      Application.put_env(:samen_core, :kms_adapter, Demo.DestructionOracleTest.BackupsOnAdapter)
      on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)

      findings = PostShred.BackupPitr.check(ctx(subject_id))

      assert Enum.any?(
               findings,
               &(&1.tier == :backup_pitr and &1.subject == "kms_store_backups" and
                   &1.severity == :violation)
             )
    end
  end

  # ======================================================================
  # ANTI-TAUTOLOGY discriminating pair (demo)
  # ======================================================================

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: the tiers the RED paths fail here PASS after a real shred" do
    {_c, subject_id} = seed_subject_across_tiers()
    {:ok, _} = Samen.Rollup.rebuild_all(Repo)
    {:ok, _} = Erasure.shred(subject_id, repo: Repo)

    db = PostShred.DbContent.check(ctx(subject_id))
    assert NoPlaintextPii.violations(db) == []
    assert Enum.any?(db, &(&1.subject == "live" and &1.severity == :pass))
    assert Enum.any?(db, &(&1.subject == "registered_non_pii" and &1.severity == :pass))

    bp = PostShred.BackupPitr.check(ctx(subject_id, pitr_repos: [Repo]))
    assert NoPlaintextPii.violations(bp) == []
    assert Enum.any?(bp, &(&1.subject == "pitr_snapshot_1" and &1.severity == :pass))

    kms = PostShred.KmsAttestation.check(ctx(subject_id))
    assert NoPlaintextPii.violations(kms) == []
  end

  # An adapter with backups_disabled?/0 == false, delegating everything else to
  # FileBacked (which retains the subject's real shredded state).
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
