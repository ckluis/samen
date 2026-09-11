defmodule Samen.FilesDeleteTest do
  @moduledoc """
  E4 (ADR-046 §4.3 · D4/T130) — the governed, ref-counted, fail-honest blob-deletion
  chokepoint `Samen.Files.delete_file/3` and the erasure arm that makes crypto-shred reach
  raw stored file bytes.

  Proven here (each with an anti-tautology positive control):

    * **Erasure reaches bytes.** After a subject's file is erased (its LAST reference),
      the physical blob is GONE (`Storage.get` is `:not_found`). Positive control: a
      NON-erased subject's blob remains readable.
    * **T130 direction A (no premature delete).** A source + its clone SHARE a blob
      (`Samen.Clone` re-links `storage_key` verbatim). Deleting ONE (the clone) leaves the
      blob INTACT and the OTHER (source) still reads its bytes.
    * **T130 direction B (last-reference deletes).** After BOTH references are gone, the
      blob bytes ARE removed — no orphaned live blob.
    * **Governance.** The governed path structurally REFUSES to over-delete a
      still-referenced blob (the chokepoint holds — a raw `Storage.delete` WOULD destroy
      it, the governed path does not); the delete is AUDITED (a token-only, org-attributed
      `primitives.file.blob_deleted` event, never the `storage_key`).
    * **Fail-honest.** An UNCONFIGURED adapter's delete returns `{:error, _}`, NEVER a fake
      `{:ok}` — and the reference is PRESERVED (the transaction rolls back), so the last
      reference is never dropped while the blob survives. Positive control: a CONFIGURED
      (Local) adapter DOES delete the last-reference blob.

  The aliasing pair uses `SamenCore.Support.CrmScopeFixture.Attachment` (abbrev `sca`), a
  real `storage_key`-bearing, non-chokepoint resource — exactly the clone-aliasing vector
  ADR-046 §3 names — backed by REAL `Samen.Files.Storage.Local` bytes.
  """
  use ExUnit.Case, async: false

  alias Samen.Files
  alias Samen.Files.Storage.{Local, S3}
  alias Samen.Clone
  alias Samen.Erasure
  alias Samen.Retention
  alias Samen.AuditEvent
  alias SamenCore.TestRepo
  alias SamenCore.Support.CrmScopeFixture.{Attachment, Person}

  require Ash.Query

  @repo TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    Samen.Kms.FileBacked.init!()
    root = Path.join(System.tmp_dir!(), "files_delete_test_#{System.unique_integer([:positive])}")
    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    org = Ash.UUID.generate()
    %{org: org, scope: tenant_scope(org), storage_config: %{root: root}}
  end

  defp tenant_scope(org, role \\ :member) do
    %Samen.Scope{actor: %{id: "u:#{org}", org_id: org, role: role, kind: :tenant, plane: :tenant}}
  end

  # Create a governed Attachment row carrying `key`, and put REAL bytes at that key.
  defp attach_with_blob(org, scope, cfg, key, bytes) do
    assert {:ok, _} = Local.put(key, bytes, cfg)

    Attachment
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, file_name: "doc.bin", content_type: "application/octet-stream", storage_key: key},
      scope: scope
    )
    |> Ash.create!()
  end

  defp del_opts(cfg, storage \\ Local) do
    [file_module: Attachment, repo: @repo, storage: storage, storage_config: cfg]
  end

  defp attachment_exists?(id) do
    Attachment
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_ | _] -> true
    end
  end

  defp uniq, do: System.unique_integer([:positive])

  # A REAL CRM Person (a data subject — its PII is vaulted under subject_id == its own id).
  defp person!(org) do
    attrs = Map.merge(%{org_id: org, display_name: "Data Subject #{uniq()}"}, Samen.Factory.person("Data", "Subject"))
    Samen.Factory.create!(Person, attrs, authorize?: false)
  end

  # A CRM Attachment *ABOUT* a person (person_id domain subject-FK), carrying REAL bytes at
  # `key` — the "scanned ID / signed contract about a person" vector of ADR-046 §7 #5.
  defp attach_about(org, scope, cfg, person_id, key, bytes) do
    assert {:ok, _} = Local.put(key, bytes, cfg)

    Attachment
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, file_name: "id-scan.bin", content_type: "application/octet-stream", storage_key: key, person_id: person_id},
      scope: scope
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # T130 — clone/source blob aliasing, both directions.
  # ---------------------------------------------------------------------------

  describe "T130 — ref-counted last-reference delete (both directions)" do
    test "A: deleting the clone leaves the shared blob INTACT; the source still reads it, then B: deleting the source removes it",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "#{org}/shared-#{System.unique_integer([:positive])}.bin"
      bytes = :crypto.strong_rand_bytes(2048)

      source = attach_with_blob(org, scope, cfg, key, bytes)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      # The clone ALIASES the same blob (storage_key re-linked verbatim).
      assert clone.id != source.id
      assert clone.storage_key == key

      # ── Direction A: delete the CLONE. Two references → after removing one, the blob
      # still has a live reference (the source), so it is NOT deleted.
      assert {:ok, a} = Files.delete_file(%{org_id: org, actor_id: "sys"}, clone, del_opts(cfg))
      assert a.blob_deleted == false
      assert a.refs_remaining == 1

      # The blob is intact and the SOURCE still reads its bytes (no premature delete).
      assert {:ok, ^bytes} = Local.get(key, cfg)
      assert attachment_exists?(source.id)
      refute attachment_exists?(clone.id)

      # ── Direction B: delete the SOURCE (the last reference). Now no row references the
      # blob → the bytes ARE removed (no orphaned live blob).
      assert {:ok, b} = Files.delete_file(%{org_id: org, actor_id: "sys"}, source, del_opts(cfg))
      assert b.blob_deleted == true
      assert b.refs_remaining == 0

      assert {:error, :not_found} = Local.get(key, cfg)
      refute attachment_exists?(source.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Governance — the chokepoint holds + the delete is audited.
  # ---------------------------------------------------------------------------

  describe "governance — ungoverned over-delete refused; delete audited" do
    test "the governed path structurally REFUSES to over-delete a still-referenced blob (a raw Storage.delete WOULD destroy it)",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "#{org}/guarded-#{System.unique_integer([:positive])}.bin"
      bytes = :crypto.strong_rand_bytes(512)

      source = attach_with_blob(org, scope, cfg, key, bytes)
      {:ok, _clone} = Clone.clone(source, scope, repo: @repo)

      # Governed delete of ONE reference does NOT touch the blob — the ref-count guard
      # refuses the over-delete that a raw, ungoverned `Storage.delete` would perform.
      assert {:ok, res} = Files.delete_file(%{org_id: org, actor_id: "sys"}, source, del_opts(cfg))
      assert res.blob_deleted == false
      assert {:ok, ^bytes} = Local.get(key, cfg)

      # ANTI-TAUTOLOGY positive control: the blob IS physically there and deletable — a
      # raw ungoverned delete WOULD have destroyed it (the exact hazard the chokepoint
      # prevents). Proven by doing it last: after a raw delete the bytes are gone.
      assert :ok = Local.delete(key, cfg)
      assert {:error, :not_found} = Local.get(key, cfg)
    end

    test "the blob delete writes a token-only, org-attributed audit event (never the storage_key)",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "#{org}/audited-#{System.unique_integer([:positive])}.bin"
      att = attach_with_blob(org, scope, cfg, key, "payload")

      assert {:ok, res} = Files.delete_file(%{org_id: org, actor_id: "sys"}, att, del_opts(cfg))
      assert res.blob_deleted == true

      events = AuditEvent.for_subject(@repo, to_string(att.id))
      blob_event = Enum.find(events, &String.contains?(&1.detail, "primitives.file.blob_deleted"))

      assert blob_event, "a blob-deletion audit event must be written"
      assert blob_event.correlation_id == org, "the event must be org-attributed"
      assert String.contains?(blob_event.detail, "blob_deleted=true")
      # Token-only: the storage_key (a credential-shaped reference) never appears.
      refute String.contains?(blob_event.detail, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-honest — unconfigured adapter refuses; reference preserved.
  # ---------------------------------------------------------------------------

  describe "fail-honest — an unconfigured adapter never fakes {:ok}" do
    test "a last-reference delete through an UNCONFIGURED S3 adapter returns {:error, _} and PRESERVES the reference",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "#{org}/failhonest-#{System.unique_integer([:positive])}.bin"
      att = attach_with_blob(org, scope, cfg, key, "bytes")

      # S3 is unconfigured (no creds) → its delete/2 is fail-honest {:error, :not_configured},
      # NEVER a fake {:ok}. delete_file must surface that AND roll back so the last
      # reference is not dropped while the blob survives.
      assert {:error, {:blob_delete_failed, :not_configured}} =
               Files.delete_file(%{org_id: org, actor_id: "sys"}, att, del_opts(%{}, S3))

      # The reference row is PRESERVED (transaction rolled back) — no silent orphan.
      assert attachment_exists?(att.id)

      # POSITIVE CONTROL: the SAME last-reference delete through the CONFIGURED Local
      # adapter DOES delete the blob and remove the reference — so the refusal above
      # keys on the adapter being unconfigured, not on some incidental failure.
      assert {:ok, ok} = Files.delete_file(%{org_id: org, actor_id: "sys"}, att, del_opts(cfg))
      assert ok.blob_deleted == true
      assert {:error, :not_found} = Local.get(key, cfg)
      refute attachment_exists?(att.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Erasure reaches file bytes.
  # ---------------------------------------------------------------------------

  describe "erasure reaches file bytes (D4)" do
    test "shredding a subject deletes its file blob; a NON-erased subject's blob remains",
         %{org: org, scope: scope, storage_config: cfg} do
      key_a = "#{org}/subject-a-#{System.unique_integer([:positive])}.bin"
      key_b = "#{org}/subject-b-#{System.unique_integer([:positive])}.bin"
      bytes_a = :crypto.strong_rand_bytes(1024)
      bytes_b = :crypto.strong_rand_bytes(1024)

      file_a = attach_with_blob(org, scope, cfg, key_a, bytes_a)
      file_b = attach_with_blob(org, scope, cfg, key_b, bytes_b)

      # Each attachment is keyed as its own erasure subject (subject_field: :id).
      specs = [%{file_module: Attachment, subject_field: :id, storage: Local, storage_config: cfg}]

      assert {:ok, %{report: report}} =
               Erasure.shred(to_string(file_a.id), repo: @repo, org_id: org, file_specs: specs)

      # Subject A's blob bytes are GONE (erasure reached them).
      assert {:error, :not_found} = Local.get(key_a, cfg)
      refute attachment_exists?(file_a.id)

      # POSITIVE CONTROL: the NON-erased subject B's blob is untouched and still reads.
      assert {:ok, ^bytes_b} = Local.get(key_b, cfg)
      assert attachment_exists?(file_b.id)

      # The erasure report surfaces the file-blob arm as reached.
      file_tier = report.tiers["file_blobs"]
      assert is_list(file_tier)
      assert Enum.sum(Enum.map(file_tier, &Map.get(&1, "blobs_deleted", 0))) >= 1
    end

    test "erasure is last-reference-aware: a blob shared with a NON-erased clone survives the subject's shred",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "#{org}/eras-shared-#{System.unique_integer([:positive])}.bin"
      bytes = :crypto.strong_rand_bytes(768)

      subject_file = attach_with_blob(org, scope, cfg, key, bytes)
      {:ok, clone} = Clone.clone(subject_file, scope, repo: @repo)
      assert clone.storage_key == key

      # Erase ONLY the subject_file (subject_field: :id → matches subject_file, not the clone).
      specs = [%{file_module: Attachment, subject_field: :id, storage: Local, storage_config: cfg}]

      assert {:ok, _} =
               Erasure.shred(to_string(subject_file.id), repo: @repo, org_id: org, file_specs: specs)

      # The shared blob SURVIVES — the non-erased clone still references it (T130-safe).
      assert {:ok, ^bytes} = Local.get(key, cfg)
      assert attachment_exists?(clone.id)
      refute attachment_exists?(subject_file.id)
    end
  end

  # ---------------------------------------------------------------------------
  # About-a-subject reach (ADR-046 §7 #5) — a Person's erasure deletes their
  # person_id-linked Attachment blobs through the SAME governed delete_file path.
  # ---------------------------------------------------------------------------

  describe "about-a-subject reach — shredding a Person deletes their person_id-linked blob (D5/§7#5)" do
    test "shredding a Person deletes their person_id-linked Attachment blob; a non-erased person's blob remains; a blob shared with a non-erased row survives",
         %{org: org, scope: scope, storage_config: cfg} do
      p1 = person!(org)
      p2 = person!(org)

      key1 = "#{org}/about-p1-#{uniq()}.bin"
      key2 = "#{org}/about-p2-#{uniq()}.bin"
      key_shared = "#{org}/about-shared-#{uniq()}.bin"
      b1 = :crypto.strong_rand_bytes(1024)
      b2 = :crypto.strong_rand_bytes(1024)
      bs = :crypto.strong_rand_bytes(1024)

      att1 = attach_about(org, scope, cfg, p1.id, key1, b1)
      att2 = attach_about(org, scope, cfg, p2.id, key2, b2)

      # A blob shared by an about-p1 attachment AND an about-p2 attachment (two rows, one key).
      shared_p1 = attach_about(org, scope, cfg, p1.id, key_shared, bs)
      # Re-link the SAME key on a second row about the NON-erased p2 (no re-upload).
      shared_p2 =
        Attachment
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, file_name: "id-scan.bin", content_type: "application/octet-stream", storage_key: key_shared, person_id: p2.id},
          scope: scope
        )
        |> Ash.create!()

      # The about-a-subject arm: keyed on the DOMAIN subject-FK :person_id, not uploaded_by_id.
      specs = [%{file_module: Attachment, subject_field: :person_id, storage: Local, storage_config: cfg}]

      assert {:ok, %{report: report}} =
               Erasure.shred(to_string(p1.id), repo: @repo, org_id: org, file_specs: specs)

      # p1's about-them blob is GONE — right-to-be-forgotten reached a document ABOUT them.
      assert {:error, :not_found} = Local.get(key1, cfg)
      refute attachment_exists?(att1.id)

      # POSITIVE CONTROL: the NON-erased p2's blob is untouched.
      assert {:ok, ^b2} = Local.get(key2, cfg)
      assert attachment_exists?(att2.id)

      # LAST-REFERENCE-AWARE (T130): the shared blob SURVIVES — p2's row still references it —
      # while p1's referencing row is destroyed.
      assert {:ok, ^bs} = Local.get(key_shared, cfg)
      assert attachment_exists?(shared_p2.id)
      refute attachment_exists?(shared_p1.id)

      # The report surfaces the about-a-subject arm as reached (≥1 blob deleted for p1).
      file_tier = report.tiers["file_blobs"]
      assert Enum.sum(Enum.map(file_tier, &Map.get(&1, "blobs_deleted", 0))) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Retention-hold exception (ADR-046 §7 #5 safety valve) — fail-honest.
  # ---------------------------------------------------------------------------

  describe "retention-hold exception — a held blob is NOT deleted by erasure (fail-honest, visible)" do
    test "an Attachment blob under a retention hold is NOT deleted by the Person's erasure and the hold-skip is recorded; without a hold it IS deleted",
         %{org: org, scope: scope, storage_config: cfg} do
      p = person!(org)

      key_held = "#{org}/held-#{uniq()}.bin"
      key_free = "#{org}/free-#{uniq()}.bin"
      b_held = :crypto.strong_rand_bytes(512)
      b_free = :crypto.strong_rand_bytes(512)

      att_held = attach_about(org, scope, cfg, p.id, key_held, b_held)
      att_free = attach_about(org, scope, cfg, p.id, key_free, b_free)

      # The retention hold — a per-spec predicate over the row (the MINIMAL mechanism, no
      # schema column). Here it holds exactly the one blob; a real host reads its own
      # legal_hold / retained_until field off the row.
      held_key = att_held.storage_key
      specs = [
        %{
          file_module: Attachment,
          subject_field: :person_id,
          storage: Local,
          storage_config: cfg,
          hold?: fn row -> row.storage_key == held_key end
        }
      ]

      assert {:ok, %{report: report}} =
               Erasure.shred(to_string(p.id), repo: @repo, org_id: org, file_specs: specs)

      # The HELD blob SURVIVES and its row is preserved — erasure overridden by the
      # legitimate retention obligation, never silently deleted-under-hold.
      assert {:ok, ^b_held} = Local.get(key_held, cfg)
      assert attachment_exists?(att_held.id)

      # POSITIVE CONTROL: the UN-held blob for the SAME person IS deleted (erasure reaches it) —
      # so the survival above keys on the hold, not on some incidental skip.
      assert {:error, :not_found} = Local.get(key_free, cfg)
      refute attachment_exists?(att_free.id)

      # FAIL-HONEST + VISIBLE: the report records the hold-skip AND the real delete.
      file_tier = report.tiers["file_blobs"]
      assert Enum.sum(Enum.map(file_tier, &Map.get(&1, "holds_skipped", 0))) >= 1
      assert Enum.sum(Enum.map(file_tier, &Map.get(&1, "blobs_deleted", 0))) >= 1
    end
  end

  # ==========================================================================
  # I2 (ADR-046 §8 residual #3) — retention `:delete` generic-purge routes the blob
  # through the GOVERNED, ref-counted `delete_file/3` chokepoint (never a raw destroy).
  # ==========================================================================

  # Attachment is archivable, so retention `:delete` purges the TRASH — archived rows keyed
  # on `archived_at` ("purge N days after archive", ADR-040 §5.6). Soft-delete then backdate
  # `sca_archived_at` to `age_days` ago to make an archived row past its retention cutoff.
  defp archive_and_age!(att, age_days) do
    Ash.destroy!(att, authorize?: false)
    ts = DateTime.add(DateTime.utc_now(), -age_days * 24 * 60 * 60, :second) |> DateTime.truncate(:microsecond)
    @repo.query!("UPDATE sca_attachment SET sca_archived_at = $1 WHERE sca_id = $2", [ts, Ecto.UUID.dump!(att.id)])
  end

  # PHYSICAL row existence (archive-inclusive) — an archived-but-not-purged row is absent
  # from `attachment_exists?/1` (the live read) but still physically present, so distinguish
  # "archived" (row present) from "purged" (row physically gone) over the raw table.
  defp attachment_row_present?(id) do
    %{rows: [[n]]} = @repo.query!("SELECT count(*) FROM sca_attachment WHERE sca_id = $1", [Ecto.UUID.dump!(id)])
    n > 0
  end

  describe "retention :delete blob purge (governed chokepoint)" do
    test "an expired :delete sweep of a blob-backed resource PURGES the blob AND the row (governed + audited)",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "ret-del-#{uniq()}"
      bytes = "retention-purge-me-#{uniq()}"
      att = attach_with_blob(org, scope, cfg, key, bytes)
      assert {:ok, ^bytes} = Local.get(key, cfg)

      # A blob-backed resource IS routed through the governed chokepoint on :delete.
      assert Retention.blob_backed?(Attachment)

      # Trash it, then age it past the retention window.
      archive_and_age!(att, 400)
      assert attachment_row_present?(att.id)

      spec = %{
        resource: Attachment,
        ttl_seconds: 90 * 24 * 3600,
        action: :delete,
        timestamp_field: :archived_at,
        storage: Local,
        storage_config: cfg
      }

      assert %{swept: 1} = Retention.sweep([spec], now: DateTime.utc_now(), repo: @repo)

      # GOVERNED reach: the raw blob bytes are GONE and the row is physically destroyed.
      assert {:error, :not_found} = Local.get(key, cfg)
      refute attachment_row_present?(att.id)

      # The delete went through the chokepoint's token-only audit (never the storage_key).
      events = AuditEvent.for_subject(@repo, to_string(att.id))
      refute Enum.any?(events, fn e -> inspect(e) =~ key end)
    end

    test "POSITIVE CONTROL: an in-TTL archived blob-backed row is NEVER touched (blob + row survive)",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "ret-keep-#{uniq()}"
      bytes = "retention-keep-me-#{uniq()}"
      att = attach_with_blob(org, scope, cfg, key, bytes)

      # Trashed just now — well within a 100-year window.
      archive_and_age!(att, 1)

      spec = %{
        resource: Attachment,
        ttl_seconds: 100 * 365 * 24 * 3600,
        action: :delete,
        timestamp_field: :archived_at,
        storage: Local,
        storage_config: cfg
      }

      assert %{swept: 0} = Retention.sweep([spec], now: DateTime.utc_now(), repo: @repo)

      assert {:ok, ^bytes} = Local.get(key, cfg)
      assert attachment_row_present?(att.id)
    end

    test "T130 REF-COUNT SAFETY: sweeping ONE aliasing row leaves a still-referenced blob (governed, not raw)",
         %{org: org, scope: scope, storage_config: cfg} do
      key = "ret-alias-#{uniq()}"
      bytes = "retention-shared-#{uniq()}"
      source = attach_with_blob(org, scope, cfg, key, bytes)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      # The clone ALIASES the same blob; trash + age ONLY the clone (source stays live, so it
      # is never in the archived-trash read the sweep purges).
      assert clone.storage_key == key
      archive_and_age!(clone, 400)

      spec = %{
        resource: Attachment,
        ttl_seconds: 30 * 24 * 3600,
        action: :delete,
        timestamp_field: :archived_at,
        storage: Local,
        storage_config: cfg
      }

      assert %{swept: 1} = Retention.sweep([spec], now: DateTime.utc_now(), repo: @repo)

      # The expired clone's row is physically gone, but the live SOURCE still references the
      # blob — so the ref-counted governed delete leaves the bytes INTACT (a raw delete would
      # have destroyed a still-referenced blob — exactly the T130 lie the chokepoint prevents).
      refute attachment_row_present?(clone.id)
      assert attachment_exists?(source.id)
      assert {:ok, ^bytes} = Local.get(key, cfg)
    end
  end
end
