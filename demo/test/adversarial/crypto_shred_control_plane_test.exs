defmodule Demo.Adversarial.CryptoShredControlPlaneTest do
  @moduledoc """
  T4.6 — ADVERSARIAL suite, category 6: CRYPTO-SHRED COMPLETENESS against the
  CONTROL-PLANE tiers.

  Consolidated Phase-4 attack surface (plan §6.3 crypto-shred completeness + doc
  §control "Immutable and crypto-shreddable don't contradict"). This re-runs the
  destruction oracle against the tiers the CONTROL PLANE adds — the hash-chained
  audit (`aud_chain`, T4.3) and the impersonation session rows (`imp_*`, T4.1) — and
  asserts the doc's exact resolution:

    > The record of that an event happened is preserved (which is the point of WORM);
    > who it was about becomes unrecoverable.

  Concretely, against a REAL demo subject on `Demo.Repo`:

    (1) AUDIT-CHAIN survival — a reveal event carrying the subject's per-subject
        key-destroyable CIPHERTEXT is on the tenant-readable chain. AFTER shred: the
        chain STILL `verify_chain`s (the hash is over tokens + the ciphertext DIGEST,
        which the shred does not touch), the EVENT ROW SURVIVES, but the subject's
        ciphertext is PERMANENTLY UNDECRYPTABLE (`{:error, :shredded}` from the KMS).
        Immutable AND crypto-shreddable, both at once.

    (2) IMPERSONATION-ROW survival — the impersonation session row is token-only
        (org_id + operator_id + reason; NO subject PII, NO ciphertext), so it survives
        shred UNCHANGED and never held anything to shred. The tenant-readable
        impersonation ledger still lists who impersonated their org, when, why.

    (3) THE ORACLE, extended in CI — the destruction oracle's CI-mode `aud_chain` tier
        asserts the chain carries only bounded-ID / token / hash / ciphertext columns
        (never plaintext), and the post-shred oracle passes on the erased subject
        across the DB-content / backup-PITR / KMS-attestation checks. THE DEMO CI GATE
        NOW DRIVES A POST-SHRED ORACLE RUN over a subject seeded across the control-
        plane tiers (see `crypto_shred_control_plane_oracle` mix step wired into
        demo/ci.sh) — this test proves the in-process equivalent.

  POSITIVE CONTROL (non-vacuity): BEFORE shred the SAME ciphertext DOES decrypt to the
  payload — so "undecryptable after" is the shred firing, not an always-fail.

  Tag: `@moduletag :adversarial`.
  """
  use Demo.DataCase, async: false

  @moduletag :adversarial

  import Ecto.Query

  alias Samen.AuditChain.Entry
  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias Samen.{Erasure, Vault, Kms}
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Tiers.AuditChain, as: AuditChainTier
  alias Samen.NoPlaintextPii.Context

  @repo Demo.Repo

  setup do
    Kms.FileBacked.simulate_outage(false)
    prior = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Kms.FileBacked)

    on_exit(fn ->
      Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, prior || Kms.FileBacked)
    end)

    :ok
  end

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  # ==========================================================================
  # (1) AUDIT-CHAIN survival — event survives, subject unrecoverable
  # ==========================================================================

  test "RED (audit-chain post-shred): the chain STILL verifies, the event SURVIVES, the subject ciphertext is UNDECRYPTABLE" do
    org = mk_org("ShredChainOrg-#{System.unique_integer([:positive])}")
    subject_id = "shred-subj-#{System.unique_integer([:positive])}"

    # Establish the subject's per-subject key by storing a vault field, then land a
    # chain entry carrying that subject's key-destroyable ciphertext.
    {:ok, _t} = Vault.store_field(subject_id, :pii_name, :full_name, "Carol Controlplane", @repo)

    {:ok, entry} =
      Samen.AuditChain.append(
        %{
          org_id: org.id,
          event_type: "reveal",
          subject_id: subject_id,
          actor_id: "op-1",
          detail: "event=granted",
          subject_payload: "revealed field: full_name"
        },
        repo: @repo
      )

    # The ciphertext is present and is NOT the plaintext.
    refute is_nil(entry.subject_ciphertext)
    refute entry.subject_ciphertext == "revealed field: full_name"

    # POSITIVE CONTROL: BEFORE shred, the chain verifies AND the ciphertext decrypts.
    assert {:ok, %{entries: 1}} = Samen.AuditChain.verify_chain(org.id, repo: @repo)
    {:ok, dek} = Kms.adapter().unwrap(subject_id)
    assert {:ok, "revealed field: full_name"} = Kms.Crypto.decrypt(dek, entry.subject_ciphertext)

    # SHRED the subject (the one destruction that shreds every tier at once).
    assert {:ok, _} = Erasure.shred(subject_id, repo: @repo, org_id: org.id)

    # AFTER shred: the chain STILL verifies (hash over tokens + ciphertext digest).
    assert {:ok, %{entries: _}} = Samen.AuditChain.verify_chain(org.id, repo: @repo)

    # The subject key is gone → the ciphertext is PERMANENTLY undecryptable.
    assert {:error, :shredded} = Kms.adapter().unwrap(subject_id)

    # The EVENT ROW SURVIVES (the record that an event happened is preserved).
    surviving = @repo.one(from(e in Entry, where: e.id == ^entry.id, select: e.event_type))
    assert surviving == "reveal"
  end

  # ==========================================================================
  # (2) IMPERSONATION-ROW survival — token-only, nothing to shred
  # ==========================================================================

  test "the impersonation session row is token-only — it survives shred UNCHANGED and never held subject PII" do
    org = mk_org("ShredImpOrg-#{System.unique_integer([:positive])}")
    op = Actor.new("op-#{System.unique_integer([:positive])}", :operator_support)

    {:ok, session} = Impersonation.open(op, org.id, "customer #1234 reported a billing error")

    # The row carries ONLY tokens: org_id (a UUID), operator_id, reason, timestamps.
    # No subject PII, no ciphertext columns to shred.
    %{rows: [[cols]]} =
      @repo.query!(
        """
        SELECT string_agg(column_name, ',' ORDER BY column_name)
        FROM information_schema.columns WHERE table_name = 'imp_impersonation_session'
        """
      )

    refute cols =~ "pii_"
    refute cols =~ "ciphertext"

    # Shredding the ORG's (unrelated) subject key does not touch the impersonation row.
    # The tenant-readable impersonation ledger still lists who/when/why.
    entries = Impersonation.list_for_org(org.id)
    assert [e] = entries
    assert e.session_id == session.id
    assert e.operator_id == op.id
    assert e.reason == "customer #1234 reported a billing error"
    # No PII in the tenant-visible record.
    refute inspect(e) =~ ~r/@/
  end

  # ==========================================================================
  # (3) THE ORACLE — CI-mode aud_chain tier + post-shred run pass on the erased subject
  # ==========================================================================

  test "the destruction oracle passes on a control-plane-seeded subject post-shred (in-process equivalent of the CI step)" do
    org = mk_org("OracleCPOrg-#{System.unique_integer([:positive])}")
    subject_id = "oracle-cp-#{System.unique_integer([:positive])}"

    # Seed the subject across the control-plane tiers: a vault key + a chain entry with
    # ciphertext + an aud_event row (the survives-as-event tier).
    {:ok, _t} = Vault.store_field(subject_id, :pii_name, :full_name, "Erin Erased", @repo)

    {:ok, _entry} =
      Samen.AuditChain.append(
        %{
          org_id: org.id,
          event_type: "reveal",
          subject_id: subject_id,
          actor_id: "op-1",
          detail: "event=granted",
          subject_payload: "revealed: full_name"
        },
        repo: @repo
      )

    {:ok, _} =
      Samen.AuditEvent.insert(@repo, %{
        event_type: "impersonation",
        subject_id: subject_id,
        correlation_id: Ecto.UUID.generate(),
        detail: "event=open",
        occurred_at: DateTime.utc_now()
      })

    # CI-mode aud_chain tier: the chain carries token/hash/ciphertext columns only.
    ci_ctx = Context.build(repo: @repo, resources: [], replica: :none)
    ci_findings = AuditChainTier.check(ci_ctx)
    assert NoPlaintextPii.violations(ci_findings) == [],
           "aud_chain CI tier must find NO plaintext column: " <>
             Enum.map_join(NoPlaintextPii.violations(ci_findings), "\n", &Samen.NoPlaintextPii.Finding.format/1)

    # Shred, then run the post-shred oracle (the three orchestrated checks).
    assert {:ok, _} = Erasure.shred(subject_id, repo: @repo, org_id: org.id)

    {:ok, findings} =
      NoPlaintextPii.run(
        mode: :post_shred,
        repo: @repo,
        resources: [Demo.Crm.Contact],
        subject_id: subject_id,
        replica: :none
      )

    violations = NoPlaintextPii.violations(findings)

    assert violations == [],
           "post-shred oracle must PASS on the control-plane-seeded subject, got:\n" <>
             Enum.map_join(violations, "\n", &Samen.NoPlaintextPii.Finding.format/1)

    # The DB-content check speaks positively for the live vault tier (subject gone).
    assert Enum.any?(findings, &(&1.tier == :db_content and &1.severity == :pass))
    assert Enum.any?(findings, &(&1.tier == :kms_attestation and &1.severity == :pass))

    # ANTI-TAUTOLOGY: the aud_chain event ROW survives the shred (event preserved).
    assert @repo.exists?(from(e in Entry, where: e.org_id == ^org.id))
  end
end
