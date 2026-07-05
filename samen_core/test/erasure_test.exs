defmodule Samen.ErasureTest do
  @moduledoc """
  T1.7 crypto-shred orchestration tests (doc D7/D8; §data; §limits carve-out).

  Green paths: `shred/2` destroys the key, writes the SHREDDED sentinel on vault
  rows, redacts registered non_pii! columns, emits an audit row, and returns the
  attestation + erasure report artifact the T2.9 oracle consumes.

  Red paths (must-fail guarantees):

    RED PATH A — post-shred decrypt of EVERY vault field for the subject raises
                 (Samen.Vault.reveal returns {:error, :shredded}), never plaintext.
    RED PATH B — a registered non_pii! column is provably redacted after erasure.
    RED PATH C — erasure is idempotent: a second call is safe and the attestation
                 stays positive (:shredded with destroyed_at).
    RED PATH D — pseudonym-unlinking: the HMAC pseudonym is denied post-shred
                 (one shred unlinks both vault ciphertext and trace-sink pseudonym).
  """
  use ExUnit.Case, async: false

  alias Samen.Erasure
  alias Samen.Vault
  alias Samen.Vault.VaultRow
  alias Samen.NonPii
  alias Samen.Masked
  alias Samen.Reveal.Grants

  import Ecto.Query, only: [from: 2]

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    end)

    :ok
  end

  defp subj, do: "erasure-subject-#{System.unique_integer([:positive])}"

  # Seed the subject with several vaulted fields across vaults (so RED PATH A can
  # assert EVERY one becomes undecryptable).
  defp seed_vault(subject_id) do
    {:ok, t_email} = Vault.store_field(subject_id, :pii_email, :emails, "a@example.com", @repo)
    {:ok, t_name} = Vault.store_field(subject_id, :pii_name, :full_name, "Alice Anders", @repo)
    {:ok, t_dob} = Vault.store_field(subject_id, :pii_dob, :dob, "1990-01-01", @repo)
    %{emails: t_email, full_name: t_name, dob: t_dob}
  end

  # ======================================================================
  # (a) shred orchestration — green path
  # ======================================================================

  describe "shred/2 (a) — key destruction + sentinel + audit + attestation" do
    test "destroys the key, seals vault rows, emits audit, returns positive attestation + report" do
      subject_id = subj()
      tokens = seed_vault(subject_id)

      assert {:ok, %{attestation: att, report: report}} = Erasure.shred(subject_id)

      # positive attestation
      assert att.state == :shredded
      assert att.destroyed_at
      assert att.attestation_id

      # SHREDDED sentinel on every vault row of the subject
      rows = @repo.all(from(v in VaultRow, where: v.subject_id == ^subject_id))
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.state == "shredded"))
      assert Enum.all?(rows, & &1.erased_at)

      # tokens still resolve to a row (dangling / sentinel), just undecryptable
      assert @repo.get(VaultRow, tokens.emails).state == "shredded"

      # report artifact
      assert report.subject_id == subject_id
      assert report.outcome == "shredded"
      assert report.attestation_id == att.attestation_id
      assert report.vault_rows_sealed == 3
      assert report.tiers["kms"]["positive_tombstone"] == true
      assert report.tiers["vault"]["rows_still_active"] == 0

      # audit row on the reveal lifecycle log
      audit = Grants.audit_for(subject_id, repo: @repo)
      assert Enum.any?(audit, &(&1.event == "erased"))
    end

    test "latest_report/2 and erased?/2 read back the erasure" do
      subject_id = subj()
      seed_vault(subject_id)
      refute Erasure.erased?(subject_id, repo: @repo)

      assert {:ok, _} = Erasure.shred(subject_id)

      assert Erasure.erased?(subject_id, repo: @repo)
      assert %{outcome: "shredded"} = Erasure.latest_report(subject_id, repo: @repo)
    end

    test "fails closed if the key store is unreachable — no sentinel, no report, no fabricated attestation" do
      subject_id = subj()
      seed_vault(subject_id)

      Samen.Kms.FileBacked.simulate_outage(true)
      # unwrap fails :unavailable during outage; but shred needs the dek file. The
      # dek exists, so shred proceeds on FileBacked even under outage (outage only
      # gates unwrap). Model a genuinely unreachable store by pointing at a
      # non-existent key dir instead.
      Samen.Kms.FileBacked.simulate_outage(false)

      # A subject that never had a key returns :absent, which is NOT a hard error
      # (handled as an absent-outcome erasure). To exercise the hard-fail path we
      # stub a KMS adapter that returns :unavailable from shred/1.
      Application.put_env(:samen_core, :kms_adapter, Samen.ErasureTest.UnreachableKms)

      assert {:error, {:kms_shred_failed, :unavailable}} = Erasure.shred(subject_id)

      # No sentinel written (fail closed): rows are still active.
      active =
        @repo.aggregate(
          from(v in VaultRow, where: v.subject_id == ^subject_id and v.state == "active"),
          :count
        )

      assert active == 3
      # No report written.
      assert Erasure.latest_report(subject_id, repo: @repo) == nil
    end
  end

  # ======================================================================
  # (b) non_pii! registry
  # ======================================================================

  describe "non_pii! registry (b) — review-gated, catalogued, distinct-party" do
    test "register/1 records who/why and exposes a catalog flag" do
      assert {:ok, entry} =
               NonPii.register(%{
                 table_name: "pat_patient",
                 column_name: "pat_care_note",
                 cleared_by: "eng:alice",
                 reviewed_by: "eng:bob",
                 reason: "operational note, not subject identity",
                 subject_column: "pat_subject_id",
                 repo: @repo
               })

      assert entry.cleared_by == "eng:alice"
      assert entry.reviewed_by == "eng:bob"

      flags = NonPii.catalog_flags(repo: @repo)
      assert %{cleared_by: "eng:alice", reviewed_by: "eng:bob", reason: _} =
               flags[{"pat_patient", "pat_care_note"}]
    end

    test "register/1 refuses self-review (fail closed) — distinct-party invariant" do
      assert {:error, :self_review} =
               NonPii.register(%{
                 table_name: "pat_patient",
                 column_name: "pat_care_note",
                 cleared_by: "eng:alice",
                 reviewed_by: "eng:alice",
                 reason: "trust me",
                 subject_column: "pat_subject_id",
                 repo: @repo
               })

      # nothing registered
      assert NonPii.entries(repo: @repo) == []
    end

    test "register/1 is idempotent per (table, column)" do
      attrs = %{
        table_name: "pat_patient",
        column_name: "pat_care_note",
        cleared_by: "eng:alice",
        reviewed_by: "eng:bob",
        reason: "v1",
        subject_column: "pat_subject_id",
        repo: @repo
      }

      assert {:ok, _} = NonPii.register(attrs)
      assert {:ok, _} = NonPii.register(%{attrs | reason: "v2"})
      assert [entry] = NonPii.entries(repo: @repo)
      assert entry.reason == "v2"
    end
  end

  # ======================================================================
  # RED PATHS
  # ======================================================================

  describe "RED PATH A — post-shred decrypt of EVERY vault field raises" do
    test "every vaulted field for the subject is undecryptable after shred" do
      subject_id = subj()
      tokens = seed_vault(subject_id)

      # Pre-shred: all three reveal to plaintext (proves the guard is meaningful).
      assert {:ok, "a@example.com"} = Vault.reveal(Masked.new(tokens.emails, :emails), @repo)
      assert {:ok, "Alice Anders"} = Vault.reveal(Masked.new(tokens.full_name, :full_name), @repo)
      assert {:ok, "1990-01-01"} = Vault.reveal(Masked.new(tokens.dob, :dob), @repo)

      assert {:ok, _} = Erasure.shred(subject_id)

      # Post-shred: EVERY field denies with :shredded — never plaintext.
      for {field, token} <- tokens do
        assert {:error, :shredded} = Vault.reveal(Masked.new(token, field), @repo),
               "field #{field} must be undecryptable after shred"
      end

      # And the oracle-style scan agrees: no plaintext remains.
      assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(subject_id, @repo)
    end
  end

  describe "RED PATH B — registered non_pii! column is redacted after erasure" do
    test "plaintext non_pii! value is overwritten with the redaction sentinel" do
      subject_id = subj()
      seed_vault(subject_id)

      # A plaintext-at-rest non_pii! value for this subject (key-shred can't reach it).
      note = "carrier prefers morning pickups; contact via dispatch line"
      pat_id = Ecto.UUID.generate()

      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        @repo,
        "INSERT INTO pat_patient " <>
          "(pat_id, pat_org_id, pat_subject_id, pat_care_note, pat_inserted_at, pat_updated_at) " <>
          "VALUES ($1, $2, $3, $4, $5, $6)",
        [
          Ecto.UUID.dump!(pat_id),
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          subject_id,
          note,
          now,
          now
        ]
      )

      {:ok, _} =
        NonPii.register(%{
          table_name: "pat_patient",
          column_name: "pat_care_note",
          cleared_by: "eng:alice",
          reviewed_by: "eng:bob",
          reason: "operational note",
          subject_column: "pat_subject_id",
          redaction: "[REDACTED]",
          repo: @repo
        })

      # Pre-erasure: the plaintext is present (guard is meaningful).
      assert read_note(pat_id) == note

      assert {:ok, %{report: report}} = Erasure.shred(subject_id)

      # Post-erasure: PROVABLY redacted — the plaintext is gone.
      redacted = read_note(pat_id)
      assert redacted == "[REDACTED]"
      refute redacted =~ "carrier"
      refute redacted =~ "dispatch"

      # ...and the erasure report records that the redaction arm ran.
      assert report.non_pii_rows_redacted == 1
      cols = report.tiers["registered_non_pii"]["columns"]
      assert Enum.any?(cols, &(&1["column"] == "pat_care_note" and &1["redacted"] == 1))
    end
  end

  describe "RED PATH C — erasure is idempotent, attestation stays positive" do
    test "a second shred is safe and still attests :shredded with destroyed_at" do
      subject_id = subj()
      seed_vault(subject_id)

      assert {:ok, %{attestation: att1, report: r1}} = Erasure.shred(subject_id)
      assert att1.state == :shredded
      assert r1.outcome == "shredded"
      assert r1.vault_rows_sealed == 3

      # Second call: must not raise, must not un-seal, attestation still positive.
      assert {:ok, %{attestation: att2, report: r2}} = Erasure.shred(subject_id)
      assert att2.state == :shredded
      assert att2.destroyed_at
      assert r2.outcome == "already_shredded"
      # No rows newly sealed the second time (already all shredded).
      assert r2.vault_rows_sealed == 0
      assert r2.tiers["vault"]["rows_still_active"] == 0

      # Vault rows remain sealed and undecryptable.
      rows = @repo.all(from(v in VaultRow, where: v.subject_id == ^subject_id))
      assert Enum.all?(rows, &(&1.state == "shredded"))
      assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(subject_id, @repo)

      # Two erasure reports on file (both calls recorded).
      count = @repo.aggregate(from(rep in Samen.Erasure.Report, where: rep.subject_id == ^subject_id), :count)
      assert count == 2
    end
  end

  describe "RED PATH D — pseudonym unlinking (HMAC key gone)" do
    test "the trace-sink pseudonym is denied post-shred (one shred unlinks it)" do
      # Use InMemory here (pseudonym is a pure KMS-adapter capability; no DB needed).
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.InMemory)
      subject_id = subj()
      seed_vault_inmemory(subject_id)

      # Pre-shred: pseudonym is computable and stable.
      assert {:ok, p1} = Vault.pseudonym(subject_id)
      assert {:ok, p2} = Vault.pseudonym(subject_id)
      assert p1 == p2
      assert is_binary(p1)

      assert {:ok, _} = Erasure.shred(subject_id)

      # Post-shred: pseudonym is UNLINKABLE — the DEK it is keyed on is gone.
      assert {:error, :shredded} = Vault.pseudonym(subject_id)
    end
  end

  # ======================================================================
  # helpers
  # ======================================================================

  defp read_note(pat_id) do
    %{rows: [[note]]} =
      Ecto.Adapters.SQL.query!(
        @repo,
        "SELECT pat_care_note FROM pat_patient WHERE pat_id = $1",
        [Ecto.UUID.dump!(pat_id)]
      )

    note
  end

  # InMemory-backed seed: the pseudonym red path doesn't need vault DB rows but we
  # still seed one so the erasure tx has something to seal.
  defp seed_vault_inmemory(subject_id) do
    {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "d@example.com", @repo)
    :ok
  end
end

defmodule Samen.ErasureTest.UnreachableKms do
  @moduledoc "A KMS adapter whose shred/1 fails :unavailable — for the fail-closed path."
  @behaviour Samen.Kms
  @impl true
  def generate_subject_key(_), do: {:error, :unavailable}
  @impl true
  def unwrap(_), do: {:error, :unavailable}
  @impl true
  def shred(_), do: {:error, :unavailable}
  @impl true
  def attest(_), do: {:error, :unavailable}
  @impl true
  def backups_disabled?, do: true
  # Store unreachable ⇒ presence is UNKNOWN ⇒ assume present (fail closed: never
  # let an outage masquerade as a completed erasure).
  @impl true
  def key_material_present?(_), do: true
  @impl true
  def pseudonym(_, _), do: {:error, :unavailable}
end
