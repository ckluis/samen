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
  alias Samen.AuditEvent
  alias SamenCore.TestRepo
  alias SamenCore.Support.CrmScopeFixture.Attachment

  require Ash.Query

  @repo TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)

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
end
