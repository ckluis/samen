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

    # WS-B / B7 (ADR-021): register the `pae` token-blind clearances so the cdc_mirror
    # oracle tier sees ALL of `pae`'s columns as projectable (AC-G12-3). These record
    # `track/1`'s capture-time PII refusal at the physical tier.
    :ok = Demo.Analytics.NonPiiSetup.register_all()

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

    # WS-B / B2 (ADR-018): seed the subject's `mov` subscription-movement ledger rows
    # (the DOMAIN source of the `mrr_revenue_rollup`). The subject is the CUSTOMER —
    # `mov_customer_id = subject_id` — so the domain REBUILD arm's `subject_delete_sql`
    # (keyed on mov_customer_id) erases exactly this subject's ledger rows. This proves
    # crypto-shred stays true THROUGH the domain rollup (AC-G7-7): after the shred, the
    # `mov` ledger AND the recomputed `mrr` rollup contain nothing re-identifying.
    seed_mov(subject_id)

    {c, subject_id}
  end

  # Seed a subject's subscription-movement ledger: a :new + an :expansion in the same
  # period (so the subject contributes a clear, re-identifiable delta to the rollup
  # BEFORE the shred). Written as a direct insert (the `mov` :append action requires
  # an Ash actor/org context; here we only need the physical rows the rollup sums).
  defp seed_mov(subject_id) do
    # Use the subject id as the mov org id so the rollup (grain: org/period/kind)
    # isolates this subject's contribution to its own org partition — the helper can
    # then sum `mrr_revenue_rollup WHERE mrr_org_id = subject_id` to observe the
    # subject's delta appear pre-shred and vanish post-rebuild.
    org_id = subject_id

    for {kind, delta, before, aft} <- [
          {"new", 9_900, 0, 9_900},
          {"expansion", 5_000, 9_900, 14_900}
        ] do
      Repo.query!(
        """
        INSERT INTO mov_subscription_event
          (mov_id, mov_org_id, mov_subscription_id, mov_customer_id, mov_plan_id,
           mov_kind, mov_mrr_delta_cents, mov_mrr_before_cents, mov_mrr_after_cents,
           mov_occurred_at, mov_inserted_at, mov_updated_at)
        VALUES
          (gen_random_uuid(), $1, gen_random_uuid(), $2, gen_random_uuid(),
           $3, $4, $5, $6, now(), now(), now())
        """,
        [
          Ecto.UUID.dump!(org_id),
          Ecto.UUID.dump!(subject_id),
          kind,
          delta,
          before,
          aft
        ]
      )
    end

    :ok
  end

  # The subject's total delta currently materialised in the `mrr_revenue_rollup`
  # (summed across periods/kinds for this subject's org). After a shred + rebuild the
  # subject's mov rows are gone, so their deltas drop out of the recomputed rollup.
  defp mov_rows(subject_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM mov_subscription_event WHERE mov_customer_id::text = $1",
        [subject_id]
      )

    n
  end

  # The subject's total delta currently summed into `mrr_revenue_rollup` (its org
  # partition — seed_mov keys the mov org on the subject id). Appears pre-shred,
  # drops to 0 after the domain REBUILD arm recomputes subject-free.
  defp subject_delta_in_rollup(subject_id) do
    %{rows: [[sum]]} =
      Repo.query!(
        "SELECT COALESCE(SUM(mrr_delta_cents),0)::int FROM mrr_revenue_rollup WHERE mrr_org_id::text = $1",
        [subject_id]
      )

    sum
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
          # WS-B / B7: `pae` joins the cdc_mirror schema-assertion tier. Because every
          # `pae` column projects (token-blind by construction + the clearances), a
          # non-projected physical column would be a violation here (AC-G12-3).
          resources: [
            Demo.Crm.Org,
            Demo.Crm.Membership,
            Demo.Crm.Contact,
            Demo.Analytics.ProductEvent
          ],
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
  # GREEN — crypto-shred stays true THROUGH the :domain rollup (ADR-018 / AC-G7-7)
  # ======================================================================

  describe "GREEN — the mov/mrr domain tiers are token-blind through rollup + shred" do
    test "--tiers all traverses mov+mrr; post-shred they contain nothing re-identifying" do
      {_c, subject_id} = seed_subject_across_tiers()

      # Refresh BOTH rollups: the aud_event daily-count AND the DOMAIN-sourced
      # revenue rollup (recomputed from the subject's `mov` ledger rows).
      {:ok, results} = Samen.Rollup.rebuild_all(Repo)
      assert Map.has_key?(results, :revenue_rollup),
             "the :domain revenue_rollup must be in the registry the worker refreshes (AC-G7-6)"

      # Pre-shred: the subject's mov rows exist and feed a re-identifiable delta into
      # the mrr rollup (14_900 = 9_900 new + 5_000 expansion, one org/period).
      assert mov_rows(subject_id) == 2
      assert subject_delta_in_rollup(subject_id) == 14_900

      # The one destruction that shreds every tier at once — including the domain arm.
      assert {:ok, %{report: report}} = Erasure.shred(subject_id, repo: Repo)

      # The oracle passes across ALL tiers (mov/mrr are token-blind by B1
      # construction; the oracle proves it STAYS true through the domain rebuild).
      findings = run_oracle(subject_id)
      assert NoPlaintextPii.violations(findings) == [],
             "the destruction oracle must PASS post-shred across mov/mrr, got:\n" <>
               Enum.map_join(NoPlaintextPii.violations(findings), "\n", &Finding.format/1)

      # B2-P1: the CONTENT scan affirmatively cleared the mov domain ledger (the
      # oracle proved 0 surviving subject rows by scanning it, not by trusting the
      # report's arm label). This is the pass the red-path above flips to a violation.
      assert Enum.any?(
               findings,
               &(&1.tier == :db_content and &1.subject == "rollup:revenue_rollup:domain_ledger" and
                   &1.severity == :pass)
             ),
             "the DbContent rollup sub-tier must AFFIRMATIVELY attest the mov ledger is " <>
               "subject-free (content-verified) post-shred"

      # The report records the DOMAIN rebuild arm for the revenue rollup (the oracle's
      # rollup-tier witness — a registered rollup ABSENT from this list would be a gap).
      revenue_entry = Enum.find(report.tiers["rollups"], &(&1["rollup"] == "revenue_rollup"))
      assert revenue_entry["arm"] == "rebuild"
      assert revenue_entry["source"] == "domain"
      assert revenue_entry["rows_affected"] == 2

      # Crypto-shred proof: the subject's `mov` ledger rows are physically gone, and
      # the recomputed `mrr` rollup no longer carries their delta — nothing left to
      # re-identify across the domain ledger OR the derived rollup.
      assert mov_rows(subject_id) == 0
      assert subject_delta_in_rollup(subject_id) == 0
    end
  end

  # ======================================================================
  # GREEN — the `pae` product-event tier (WS-B / B7; ADR-021 §4.4)
  # ======================================================================

  describe "GREEN — the pae ledger is token-blind + erasure-covered (AC-G12-3 / AC-G12-5)" do
    test "the cdc_mirror schema tier asserts pae is token-blind (all columns project)" do
      {_c, subject_id} = seed_subject_across_tiers()

      # A pae row keyed on the subject's HMAC pseudonym (the actor_ref) + an org-scoped
      # event — pae is org-scoped-only, no subject COLUMN.
      {:ok, _} = Samen.Kms.adapter().generate_subject_key(subject_id)

      {:ok, _pae} =
        Samen.Analytics.track(%{
          org_id: Ash.UUID.generate(),
          event_name: "record.created",
          subject_id: subject_id,
          entity_ref: "rec-#{:erlang.unique_integer([:positive])}",
          props: %{"resource" => "crm.contact"}
        })

      {:ok, _} = Erasure.shred(subject_id, repo: Repo)

      findings = run_oracle(subject_id)

      # The oracle is clean AND the cdc_mirror tier speaks positively (its schema
      # assertion covers pae for free — a non-projected pae column would be a violation).
      assert NoPlaintextPii.violations(findings) == [],
             Enum.map_join(NoPlaintextPii.violations(findings), "\n", &Finding.format/1)

      assert Enum.any?(findings, &(&1.tier == :cdc_mirror and &1.severity == :pass))
    end

    test "erasure for free: post-shred the pae actor_ref pseudonym unlinks (AC-G12-5)" do
      org_id = Ash.UUID.generate()
      subject_id = Ash.UUID.generate()
      {:ok, _} = Samen.Kms.adapter().generate_subject_key(subject_id)

      {:ok, pae} =
        Samen.Analytics.track(%{org_id: org_id, event_name: "session.signed_in", subject_id: subject_id})

      # Pre-shred: the stored actor_ref IS the subject's computable pseudonym.
      assert {:ok, pseudonym} = Samen.WideEvent.for_subject(subject_id)
      assert pae.actor_ref == pseudonym

      {:ok, _} = Erasure.shred(subject_id, repo: Repo)

      # Post-shred: the pseudonym is UNRECONSTRUCTABLE — the actor_ref is a dangling
      # one-way handle whose key is gone, across live + mirror at once. pae is
      # org-scoped-only (no subject column), so the KEY destruction IS the erasure —
      # proven STRUCTURALLY, per ADR-021 §4.4.
      assert {:error, :shredded} = Samen.WideEvent.for_subject(subject_id)
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
    test "ADR-018 erasure red-path: a sabotaged domain arm that retains the subject's delta survives the shred" do
      {_c, subject_id} = seed_subject_across_tiers()

      # SABOTAGE: a revenue_rollup spec whose subject_delete_sql never matches the
      # subject (a broken erasure hook — the "recompute still counts the subject" bug
      # ADR-018 §5 / AC-G7-7 forbids). Keep the $1 placeholder ($1::text IS NULL is
      # false for every real subject) so the arm's binding is unchanged — only the
      # predicate is mis-scoped.
      prior = Application.get_env(:samen_core, :rollups)

      sabotaged_specs =
        Enum.map(prior, fn spec ->
          if Map.get(spec, :name) == :revenue_rollup do
            Map.put(spec, :subject_delete_sql, "DELETE FROM mov_subscription_event WHERE $1::text IS NULL")
          else
            spec
          end
        end)

      Application.put_env(:samen_core, :rollups, sabotaged_specs)

      try do
        {:ok, _} = Samen.Rollup.rebuild_all(Repo)
        assert subject_delta_in_rollup(subject_id) == 14_900

        {:ok, %{report: _}} = Erasure.shred(subject_id, repo: Repo)

        # THE PROOF the domain arm is load-bearing: with a broken delete hook, the
        # subject's mov rows survive AND their delta stays in the recomputed rollup —
        # a re-identifying residue the destruction oracle must never permit. The
        # correct spec (the GREEN test) drives both to 0; the sabotaged spec leaves
        # them → the guarantee is NOT tautological.
        assert mov_rows(subject_id) == 2,
               "sabotaged (no-op) delete hook must leave the subject's mov rows — proving the erasure hook is load-bearing"

        assert subject_delta_in_rollup(subject_id) == 14_900,
               "sabotaged domain rebuild must leave the subject's re-identifying delta in the mrr rollup"

        # B2-P1: and — critically — the AUDITOR-FACING ORACLE must EMIT A VIOLATION on
        # this residue, not merely the direct SQL helpers above. The report will
        # self-attest revenue_rollup arm=rebuild (the delete hook still ran, deleting
        # 0 rows), but the DbContent rollup sub-tier scans the mov ledger directly and
        # catches the 2 surviving subject rows. This is the "FAILS the oracle" bar
        # ADR-018 §3/§5 + AC-G7-7 + the Samen.Rollup moduledoc all state — now met by
        # the oracle, not just a probe helper.
        findings = run_oracle(subject_id)
        violations = NoPlaintextPii.violations(findings)

        assert violations != [],
               "a sabotaged :domain delete hook that leaves the subject's ledger residue must " <>
                 "FAIL the destruction oracle (B2-P1), not pass silently"

        assert Enum.any?(
                 violations,
                 &(&1.tier == :db_content and &1.subject == "rollup:revenue_rollup:domain_ledger")
               ),
               "the DbContent rollup sub-tier must flag the surviving mov_subscription_event " <>
                 "subject rows as the violation, got:\n" <>
                 Enum.map_join(violations, "\n", &Finding.format/1)
      after
        Application.put_env(:samen_core, :rollups, prior)
      end
    end

    @tag :red_path
    test "oracle CI tier: a plaintext PII column on the mrr rollup table FAILS the build" do
      # A rollup is a derived aggregate dashboards read directly AND it survives
      # crypto-shred — so a plaintext PII column on it is a leak the Rollup CI tier
      # must catch. Add an offending column to the real mrr table and assert failure.
      Repo.query!("ALTER TABLE mrr_revenue_rollup ADD COLUMN IF NOT EXISTS mrr_email TEXT", [])

      try do
        findings = Samen.NoPlaintextPii.Tiers.Rollup.check(ctx(Ash.UUID.generate()))
        violations = Enum.filter(findings, &(&1.severity == :violation))

        assert Enum.any?(violations, &(&1.subject == "mrr_revenue_rollup.mrr_email")),
               "a plaintext PII column on the :domain revenue rollup must be a CI-mode violation, got: #{inspect(violations)}"
      after
        Repo.query!("ALTER TABLE mrr_revenue_rollup DROP COLUMN IF EXISTS mrr_email", [])
      end
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
