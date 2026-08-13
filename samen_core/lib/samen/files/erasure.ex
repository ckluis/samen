defmodule Samen.Files.Erasure do
  @moduledoc """
  The **file-blob erasure arm** (ADR-046 §4.3 · D4) — the arm that makes crypto-shred
  reach raw stored file bytes.

  `Samen.Erasure.shred/2` is a key-destruction job: it makes every *vaulted* value for a
  subject undecryptable at once. But a stored file **blob** is raw bytes in object storage
  — it lives OUTSIDE the per-subject-DEK envelope, so key-shred does not reach it (the same
  class of residue as the `non_pii!` plaintext carve-out). This module is that carve-out's
  erasure arm: on shred of a subject it locates the subject's `File` rows and deletes their
  blobs through the governed, ref-counted, fail-honest `Samen.Files.delete_file/3`
  chokepoint — so an erased subject's file bytes are actually removed.

  ## Last-reference-aware (T130)

  Because `Samen.Clone` re-links `storage_key` verbatim, an erased subject's file may share
  a blob with a NON-erased clone in another context. Deletion rides
  `Samen.Files.delete_file/3`, whose reference count destroys the physical blob ONLY when
  the LAST referencing row is gone — so erasing one subject NEVER destroys a blob a
  non-erased clone still references, and the blob IS removed once the final reference goes.

  ## Spec-driven, framework-first (the registry)

  The kernel does not know a host's `File` resource modules, so the arm is expressed as a
  list of specs the host registers (`config :samen_core, :file_erasure_specs`), exactly
  like the retention and rollup-erasure spec registries. Each spec is a map:

      %{
        file_module:    MyApp.PrimitivesScope.File,  # the File resource
        subject_field:  :uploaded_by_id,             # column carrying the subject id
        storage:        Samen.Files.Storage.Local,   # optional; default Local
        storage_config: %{root: "/var/lib/app/files"} # optional; default %{}
      }

  Absent any spec the arm is a no-op (returns `[]`) — a host that has not registered file
  erasure is unchanged, exactly as `Samen.NonPii` redacts nothing until a column is
  registered. (The forthcoming erasure-completeness verifier (ADR-046 §6) will assert every
  `storage_key` column has such an arm, so a future one cannot ship unregistered.)

  ## Fail-soft inside the erasure transaction

  Called as a step inside `Samen.Erasure.shred/2`'s transaction, this arm is **fail-soft**:
  a single file whose blob cannot be deleted (e.g. an unconfigured S3 adapter) is RECORDED
  as an error in the arm's report but never rolls back the subject's vault erasure — the
  subject's key is already destroyed; a raw blob that could not be reached is an honest
  residue for the operator to retry, not a reason to abort the crypto-shred. Each
  per-file delete runs in its own savepoint (`Samen.Files.delete_file/3`'s transaction),
  so its rollback on a blob-delete failure is contained.
  """

  require Logger
  require Ash.Query

  @doc """
  Delete the blobs of `subject_id`'s files across every registered file-erasure spec.

  `repo` is the erasure transaction's repo (the per-file governed delete runs in a
  savepoint on it). `opts`:

    * `:file_specs` — override the registered specs (tests pass this).
    * `:org_id`     — the subject's org, for the blob-delete audit attribution.
    * `:actor_id`   — who initiated the erasure (recorded in the audit row).

  Returns a per-spec report list (each entry a token-only map) the erasure report embeds.
  """
  @spec erase_subject(String.t(), module(), keyword()) :: [map()]
  def erase_subject(subject_id, repo, opts \\ []) when is_binary(subject_id) do
    specs = Keyword.get(opts, :file_specs) || Application.get_env(:samen_core, :file_erasure_specs, [])
    org_id = Keyword.get(opts, :org_id)
    actor_id = Keyword.get(opts, :actor_id)

    Enum.map(specs, &erase_one_spec(&1, subject_id, repo, org_id, actor_id))
  end

  defp erase_one_spec(spec, subject_id, repo, org_id, actor_id) do
    file_mod = Map.fetch!(spec, :file_module)
    subject_field = Map.fetch!(spec, :subject_field)
    storage = Map.get(spec, :storage, Samen.Files.Storage.Local)
    storage_config = Map.get(spec, :storage_config, %{})

    rows = find_subject_files(file_mod, subject_field, subject_id)

    results =
      Enum.map(rows, fn row ->
        scope = %{org_id: org_id || Map.get(row, :org_id), actor_id: actor_id}

        case Samen.Files.delete_file(scope, row,
               file_module: file_mod,
               repo: repo,
               storage: storage,
               storage_config: storage_config
             ) do
          {:ok, res} ->
            res

          {:error, reason} ->
            Logger.warning(
              "[Samen.Files.Erasure] blob delete failed for file " <>
                "#{inspect(Map.get(row, :id))} (#{inspect(file_mod)}): #{inspect(reason)}"
            )

            %{file_id: Map.get(row, :id), blob_deleted: false, error: reason}
        end
      end)

    %{
      "file_resource" => inspect(file_mod),
      "files_erased" => length(results),
      "blobs_deleted" => Enum.count(results, &(Map.get(&1, :blob_deleted) == true)),
      "errors" => Enum.count(results, &Map.has_key?(&1, :error))
    }
  end

  # Find ALL the subject's File rows, archive-state-inclusive (an archived file of an
  # erased subject must still have its blob reached). The default read is live-only and
  # the `:archived` read is archived-only (`Samen.Archival.OnlyArchived`), so for an
  # archivable resource we union both — a row is either live or archived, never both, so
  # the two sets are disjoint.
  defp find_subject_files(file_mod, subject_field, subject_id) do
    live = read_subject_files(file_mod, subject_field, subject_id)

    archived =
      if Samen.Info.archivable?(file_mod) do
        read_subject_files(Samen.Archival.archived_query(file_mod), subject_field, subject_id)
      else
        []
      end

    live ++ archived
  end

  defp read_subject_files(queryable, subject_field, subject_id) do
    queryable
    |> Ash.Query.filter(^Ash.Expr.ref(subject_field) == ^subject_id)
    |> Ash.Query.ensure_selected([:storage_key, :org_id, subject_field])
    |> Ash.read!(authorize?: false)
  rescue
    e ->
      Logger.error(
        "[Samen.Files.Erasure] read of subject files failed for #{inspect(queryable)}: #{inspect(e)}"
      )

      []
  end
end
