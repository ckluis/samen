defmodule Samen.CdcMirrorTest do
  @moduledoc """
  T6.5 — the OPTIONAL ClickHouse CDC tier: mechanism + faithful local simulation.

  There is NO ClickHouse in this environment (plan HARD note), so the wired adapter
  is `Samen.Cdc.LocalPostgres`, which mirrors the token-blind projection into a
  second local Postgres schema (`cdc_mirror`) standing in for ClickHouse. The
  safety property proven — token-only-downstream + post-shred dangling tokens — is
  adapter-independent (the projection is pure structure), so the same proof holds
  for a real ClickHouse mirror in production.

  Structure (plan HARD RULE: every guarantee ships a red-path + an anti-tautology
  probe):

    * GREEN — a fully-vaulted resource projects token-blind; the mirror table
      carries only tokens/bounded-IDs/enums; post-shred the mirror holds only
      DANGLING tokens; the oracle's cdc_mirror tier emits zero violations.

    * RED PATHS —
        RP-A  a plaintext PII column in the CDC projection request FAILS
              (`assert_no_plaintext!` raises).
        RP-B  a plaintext column physically present in the mirror table (bypassing
              the projection) FAILS the oracle's cdc_mirror schema scan.
        RP-C  post-shred, a mirror token that STILL decrypts (shred didn't reach)
              FAILS the oracle's content scan.
        RP-D  a legacy :cdc_mirror_repo with no :cdc adapter is a fail-closed gap.

    * ANTI-TAUTOLOGY — the same oracle tier that FAILS RP-B/RP-C PASSES the green
      mirror, proving the tier discriminates (not "never fires").
  """
  use ExUnit.Case, async: false

  alias Samen.Cdc
  alias Samen.Cdc.{Projection, LocalPostgres}
  alias Samen.{Vault, Erasure}
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.NoPlaintextPii.Tiers.PostShred.CdcMirror

  @repo SamenCore.TestRepo
  @schema "cdc_mirror"
  @patient SamenCore.Support.Clinical.Patient
  @patient_table "pat_patient"

  # The mirror DDL (CREATE SCHEMA / CREATE TABLE) is transactional in Postgres, so
  # it rolls back cleanly with the sandbox transaction — nothing leaks between
  # tests. The vault writes + shred also roll back. The `cdc_mirror` schema is
  # created fresh inside each test's sandbox transaction.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    on_exit(fn ->
      Application.delete_env(:samen_core, :cdc)
      Application.delete_env(:samen_core, :cdc_mirror_repo)
      Samen.Kms.FileBacked.simulate_outage(false)
    end)

    :ok
  end

  defp enable_cdc! do
    Application.put_env(:samen_core, :cdc, adapter: LocalPostgres, repo: @repo)
  end

  defp subj, do: Ecto.UUID.generate()

  # Store a couple of vault fields and return the tokens (the mirror will carry
  # these vt_* tokens, never the plaintext).
  defp seed_vault(subject_id) do
    {:ok, dob_token} = Vault.store_field(subject_id, :pii_dob, :dob, "1990-01-01", @repo)
    {:ok, mrn_token} = Vault.store_field(subject_id, :pii_mrn, :mrn, "MRN-42", @repo)
    [dob_token, mrn_token]
  end

  # Mirror one token-blind row for the subject into the cdc_mirror schema.
  defp mirror_patient_row(subject_id, tokens) do
    :ok = Cdc.ensure_mirror_for(@patient)

    [dob_token, mrn_token] = tokens

    values = %{
      "cdc_subject_id" => subject_id,
      "pat_id" => subject_id,
      "pat_org_id" => Ecto.UUID.generate(),
      "pat_consent_on_file" => "true",
      "pii_pat_dob" => dob_token,
      "pii_pat_mrn" => mrn_token
    }

    :ok = Cdc.mirror(@patient, values)
  end

  defp post_shred_ctx(subject_id) do
    Context.build(
      repo: @repo,
      subject_id: subject_id,
      resources: [@patient],
      replica: :none
    )
  end

  # ======================================================================
  # Projection — token-blind by construction
  # ======================================================================

  describe "token-blind projection" do
    test "a fully-vaulted resource projects only token/bounded-ID/enum columns" do
      projected = Projection.project(@patient)
      kinds = projected |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

      refute :plaintext_pii in kinds
      assert :token in kinds

      cols = Enum.map(projected, &elem(&1, 0))
      # vault-routed columns appear as tokens; the plaintext job_title is EXCLUDED.
      assert "pii_pat_dob" in cols
      assert "pat_full_name" in cols
      refute "pat_job_title" in cols
    end

    test "classify_columns marks the un-vaulted plaintext string as :plaintext_pii" do
      classified = Map.new(Projection.classify_columns(@patient))
      assert classified["pat_job_title"] == :plaintext_pii
      assert classified["pii_pat_dob"] == :token
      assert classified["pat_org_id"] == :bounded_id
    end
  end

  # ======================================================================
  # GREEN — mirror carries tokens; post-shred dangling; oracle passes
  # ======================================================================

  describe "GREEN — token-only mirror, post-shred dangling tokens" do
    test "the mirror table has only token-blind columns (no plaintext PII column)" do
      enable_cdc!()
      :ok = Cdc.ensure_mirror_for(@patient)

      {:ok, cols} = Cdc.mirrored_columns(@patient_table)
      # cdc_subject_id + the projected token-blind columns; job_title is absent.
      refute "pat_job_title" in cols
      assert "cdc_subject_id" in cols
      assert "pii_pat_dob" in cols
    end

    test "post-shred: the mirror holds only DANGLING tokens; oracle tier passes clean" do
      enable_cdc!()
      subject_id = subj()
      tokens = seed_vault(subject_id)
      mirror_patient_row(subject_id, tokens)

      # Before shred the mirror tokens DECRYPT (the vault key is live) — the tier's
      # content scan must therefore FAIL pre-shred (this is the discriminating half).
      pre = CdcMirror.check(post_shred_ctx(subject_id))
      assert Enum.any?(NoPlaintextPii.violations(pre), &(&1.subject == "content"))

      # Now shred: the per-subject key is destroyed.
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      # The mirror STILL holds the tokens (append-only) — but they are DANGLING.
      dangling = LocalPostgres.dangling_tokens(subject_id)
      assert length(dangling) == 2, "the mirror keeps the vt_* tokens after shred"

      findings = CdcMirror.check(post_shred_ctx(subject_id))
      assert NoPlaintextPii.violations(findings) == [],
             "post-shred oracle cdc_mirror tier must be clean:\n" <>
               Enum.map_join(NoPlaintextPii.violations(findings), "\n", &Finding.format/1)

      passes = NoPlaintextPii.passes(findings)
      subjects = Enum.map(passes, & &1.subject)
      assert "content" in subjects
      assert "never_read_current" in subjects
      content = Enum.find(passes, &(&1.subject == "content"))
      assert content.detail =~ "DANGLING"
    end

    test "full --tiers all roster runs the ACTIVE cdc_mirror tier with zero violations" do
      enable_cdc!()
      subject_id = subj()
      tokens = seed_vault(subject_id)
      mirror_patient_row(subject_id, tokens)
      # Seed the OTHER tiers minimally so the whole roster is exercised is out of
      # scope here — the T2.9 suite owns that. Here we drive ONLY the cdc tier
      # through the shared roster to prove registration + activation.
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      {:ok, findings} =
        NoPlaintextPii.run(
          mode: :post_shred,
          tiers: [CdcMirror],
          repo: @repo,
          subject_id: subject_id,
          resources: [@patient],
          replica: :none
        )

      assert NoPlaintextPii.violations(findings) == []
      assert Enum.any?(findings, &(&1.tier == :cdc_mirror and &1.severity == :pass))
    end
  end

  # ======================================================================
  # RED PATHS
  # ======================================================================

  describe "RED PATHS" do
    @tag :red_path
    test "RP-A: a plaintext PII column named in the mirror request is REFUSED" do
      assert_raise Projection.PlaintextInProjectionError, ~r/plaintext PII column/, fn ->
        Projection.assert_no_plaintext!(@patient, ["pat_id", "pat_job_title"])
      end

      # And the fully-verbatim request is also refused (job_title is plaintext).
      assert_raise Projection.PlaintextInProjectionError, fn ->
        Projection.assert_no_plaintext!(@patient, :all)
      end
    end

    @tag :red_path
    test "RP-A': a token-blind column set passes assert_no_plaintext!" do
      assert :ok =
               Projection.assert_no_plaintext!(@patient, ["pat_id", "pii_pat_dob", "pat_org_id"])
    end

    @tag :red_path
    test "RP-B: a plaintext column physically in the mirror table FAILS the oracle schema scan" do
      enable_cdc!()
      :ok = Cdc.ensure_mirror_for(@patient)

      # Sabotage: an operator (or a mis-scoped ClickPipes allow-list) adds a
      # plaintext column to the mirror table, bypassing the projection.
      Ecto.Adapters.SQL.query!(
        @repo,
        ~s|ALTER TABLE "#{@schema}"."#{@patient_table}" ADD COLUMN pat_job_title text|,
        []
      )

      subject_id = subj()
      findings = CdcMirror.check(post_shred_ctx(subject_id))

      schema_violation =
        Enum.find(
          findings,
          &(&1.severity == :violation and String.starts_with?(&1.subject, "schema"))
        )

      assert schema_violation != nil,
             "a non-projected physical column in the mirror must be a schema violation"

      assert schema_violation.detail =~ "pat_job_title"
      assert schema_violation.detail =~ "token-only-downstream invariant is broken"
    end

    @tag :red_path
    test "RP-C: post-shred a mirror token that STILL decrypts FAILS the content scan" do
      enable_cdc!()
      subject_id = subj()
      tokens = seed_vault(subject_id)
      mirror_patient_row(subject_id, tokens)

      # NO shred — the vault key is live, so the mirror tokens still decrypt. The
      # oracle's content scan must FAIL (a mirror that still yields plaintext is a
      # violation).
      findings = CdcMirror.check(post_shred_ctx(subject_id))

      content_violation =
        Enum.find(findings, &(&1.severity == :violation and &1.subject == "content"))

      assert content_violation != nil
      assert content_violation.detail =~ "STILL HOLDS decryptable content"
    end

    @tag :red_path
    test "RP-D: a legacy :cdc_mirror_repo with no :cdc adapter is a fail-closed gap" do
      Application.put_env(:samen_core, :cdc_mirror_repo, :some_clickhouse_repo)
      subject_id = subj()

      findings = CdcMirror.check(post_shred_ctx(subject_id))
      assert [%Finding{severity: :violation} = v] = findings
      assert v.detail =~ "fail-closed GAP"
    end

    @tag :red_path
    test "read_current/3 on the analytics mirror ALWAYS raises (never-read-current runtime guard)" do
      enable_cdc!()

      assert_raise Samen.Cdc.NeverReadCurrent.Violation, ~r/read a 'current' value/, fn ->
        LocalPostgres.read_current(@patient_table, "some-key", [])
      end
    end

    # -----------------------------------------------------------------------
    # RP-E — the scan is FAIL-CLOSED on an infrastructure failure it cannot
    # classify. `Vault.reveal/2` answers a legitimately shredded/missing token
    # with an ERROR TUPLE (`{:error, :shredded | :absent | :not_found |
    # :unavailable | :decrypt_failed}`) — it does NOT raise — so a RAISE out of
    # the reveal path is never "this token is safely undecryptable"; it is "the
    # scan did not run". This oracle is the erasure-completeness verifier
    # (`erasure_test.exs`, `shred_key_material_test.exs`, driftwood's crypto-shred
    # gameday read its verdict as proof of erasure), so a vault that was merely
    # unreachable must never come back as a proven erasure (ADR-014/024/026
    # fail-honest: an error you cannot classify fails CLOSED).
    # -----------------------------------------------------------------------
    @tag :red_path
    test "RP-E: a reveal that RAISES mid-scan is a LEAK, never {:ok, :no_plaintext}" do
      enable_cdc!()
      subject_id = subj()
      tokens = seed_vault(subject_id)
      mirror_patient_row(subject_id, tokens)

      # The mirror holds real tokens; now the KMS transport blows up mid-scan
      # (socket closed / adapter misconfigured / a bug under the reveal path).
      # Nothing at all has been proven about this subject's erasure.
      on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)
      Application.put_env(:samen_core, :kms_adapter, Samen.CdcMirrorTest.RaisingKms)

      assert {:leaks, [leak]} = LocalPostgres.scan_no_plaintext(subject_id, [])
      assert leak =~ "cdc mirror scan failed"
      assert leak =~ "kms transport closed"
    end

    @tag :red_path
    test "RP-E control A: a genuinely SHREDDED token still scans {:ok, :no_plaintext}" do
      enable_cdc!()
      subject_id = subj()
      tokens = seed_vault(subject_id)
      mirror_patient_row(subject_id, tokens)
      {:ok, _} = Erasure.shred(subject_id, repo: @repo)

      # The distinction RP-E turns on: a shredded token DENIES with an error tuple,
      # it does not raise. An undecryptable token is the CORRECT safe outcome — the
      # scan's whole purpose — and must keep reading as :no_plaintext.
      assert {:error, :shredded} =
               Vault.reveal(%Samen.Masked{token: hd(tokens), label: "cdc"}, @repo)

      assert {:ok, :no_plaintext} = LocalPostgres.scan_no_plaintext(subject_id, [])
    end

    @tag :red_path
    test "RP-E control B: a genuinely DECRYPTABLE mirror token still scans as a leak" do
      enable_cdc!()
      subject_id = subj()
      tokens = seed_vault(subject_id)
      mirror_patient_row(subject_id, tokens)

      # No shred — the per-subject key is live, so both mirror tokens decrypt. The
      # scan must name each one (this is the arm that proves it still detects).
      assert {:leaks, leaks} = LocalPostgres.scan_no_plaintext(subject_id, [])
      assert length(leaks) == 2
      assert Enum.all?(leaks, &(&1 =~ "still decrypts"))
      assert Enum.any?(leaks, &(&1 =~ hd(tokens)))
    end
  end

  # ======================================================================
  # ANTI-TAUTOLOGY — the oracle tier discriminates
  # ======================================================================

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: the cdc_mirror tier PASSES the green mirror it FAILS when sabotaged" do
    enable_cdc!()
    subject_id = subj()
    tokens = seed_vault(subject_id)
    mirror_patient_row(subject_id, tokens)
    {:ok, _} = Erasure.shred(subject_id, repo: @repo)

    # GREEN: clean mirror, post-shred → the content + schema sub-tiers PASS.
    green = CdcMirror.check(post_shred_ctx(subject_id))
    assert NoPlaintextPii.violations(green) == []
    assert Enum.any?(green, &(&1.subject == "content" and &1.severity == :pass))

    # SABOTAGE the SAME tier two ways and confirm each flips to :violation.
    Ecto.Adapters.SQL.query!(
      @repo,
      ~s|ALTER TABLE "#{@schema}"."#{@patient_table}" ADD COLUMN pat_job_title text|,
      []
    )

    sabotaged = CdcMirror.check(post_shred_ctx(subject_id))

    assert Enum.any?(
             sabotaged,
             &(&1.severity == :violation and String.starts_with?(&1.subject, "schema"))
           ),
           "the tier that PASSED the clean mirror must FAIL the sabotaged one — proving it " <>
             "discriminates rather than always-passing"
  end
end

defmodule Samen.CdcMirrorTest.RaisingKms do
  @moduledoc """
  A KMS adapter whose `unwrap/1` **RAISES** instead of returning `{:error, _}` —
  the shape of an infrastructure failure mid-scan (transport closed, adapter
  misconfigured, a bug under `Samen.Vault.reveal/2`). Deliberately distinct from
  `Samen.ErasureTest.UnreachableKms`, which returns `{:error, :unavailable}`: an
  error TUPLE is a classified answer ("undecryptable" — the safe outcome), a RAISE
  is not, and only a raise can be mistaken for "safely undecryptable" by a rescue
  that swallows it. Drives RP-E.
  """
  @behaviour Samen.Kms

  @blown "kms transport closed"

  @impl true
  def generate_subject_key(_), do: raise(RuntimeError, message: @blown)
  @impl true
  def unwrap(_), do: raise(RuntimeError, message: @blown)
  @impl true
  def shred(_), do: raise(RuntimeError, message: @blown)
  @impl true
  def attest(_), do: raise(RuntimeError, message: @blown)
  @impl true
  def backups_disabled?, do: true
  # Store unreachable ⇒ key presence is UNKNOWN ⇒ assume present (fail closed:
  # an outage never masquerades as a completed erasure).
  @impl true
  def key_material_present?(_), do: true
  @impl true
  def pseudonym(_, _), do: raise(RuntimeError, message: @blown)
end
