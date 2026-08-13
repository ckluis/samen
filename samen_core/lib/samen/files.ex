defmodule Samen.Files do
  @moduledoc """
  The files engine chokepoint (ADR-026 §2, decision 2 · AC-G14-1/2/6).

  `upload/3` is the **single governed create path** for a `File` row that carries a
  `storage_key`. Everything a file needs to be governed happens here, in order:

    1. **Size/type enforcement (deny-by-default) — BEFORE storage.** The upload's
       `content_type` must be in the bounded `allowed_content_types` allowlist and
       its byte size must be `<= max_bytes`. An over-size or non-allowlisted upload
       is refused BEFORE `Storage.put/3` is ever called — no byte is written for a
       rejected upload (RP-FI-5). An empty/unknown content_type is refused; the
       allowlist is never `*`.
    2. **`Storage.put/3`** through the configured fail-honest adapter. If the store
       does not return `{:ok, meta}` the whole upload fails — no `File` row is
       created for bytes that did not land (fail-honest end to end).
    3. **Governed Ash create** of the host's concrete `File` resource, org-scoped,
       with the returned `storage_key`. A fresh file lands `:quarantined` (the
       resource default; ADR-026 decision 3) — this engine never overrides that to
       `:active` (RP-FI-3).
    4. **`file_uploaded/3` audit event** via the existing Primitives audit writer
       (`Samen.Scopes.Primitives.Audit`) — a token-only row (status enum + ids),
       never the filename or storage_key.

  Because this is the ONLY path that mints a `storage_key`, "no ungoverned file row"
  is true **by construction** — and structurally, not by convention: this chokepoint
  stamps the create changeset with the private `Samen.Files.ChokepointGuard` marker,
  and that guard (a `before_action` on the `File` create) REFUSES any create that sets a
  `storage_key` WITHOUT the marker. So a `storage_key` cannot appear on a row without
  having passed size/type enforcement, the org-scoped create, and the audit write — a
  direct `Ash.create` bypassing this function is refused (AC-G14-2, RP-FI-1). Sabotaging
  the pre-storage size/type guard, removing the chokepoint marker, or defaulting a fresh
  file to `:active`, FAILS the corresponding red-path.

  ## Quarantine → active promotion, gated on a scan (AC-G14-4 · RP-FI-3)

  A fresh file is `:quarantined` and is NOT previewable/downloadable. It becomes
  `:active` ONLY through `promote/3`, which is the single promotion chokepoint:

    1. it re-reads the bytes from storage (via the file's `storage_key`),
    2. hands them to the configured `Samen.Files.Scanner` (default
       `Samen.Files.Scanner.Reject`, which holds EVERYTHING — fail-closed),
    3. promotes to `:active` ONLY on a `{:ok, :clean}` verdict, and
    4. writes a `primitives.file.promoted` audit row (scanner + verdict, token-only).

  A `{:ok, :held}` verdict (the `Reject` default) or a `{:error, _}` scan failure leaves
  the file `:quarantined` — fail-closed. Auto-promotion of unscanned files requires an
  explicit operator opt-in to `Samen.Files.Scanner.Noop`; it is never the default.
  Promoting a file WITHOUT a clean scan verdict (sabotaging the gate) FAILS RP-FI-3.

  `previewable?/1` reports whether a file may be previewed/downloaded (only `:active`),
  and `fetch_bytes/3` refuses to serve the bytes of a non-`:active` file
  (`{:error, :not_previewable}`) — the download path enforces the same gate.

  ## Host-wired resource + repo + storage (injectable seams)

  Like `Samen.Notifications.Engine` and `Samen.Scopes.Marketing.SendWorker`, the
  engine resolves the host's concrete `File` module, `repo`, and storage adapter +
  config from config — never a hardcoded namespace (the kernel is mount-agnostic):

      config :samen_core, Samen.Files,
        file_module:    Demo.PrimitivesScope.File,
        repo:           Demo.Repo,
        storage:        Samen.Files.Storage.Local,
        storage_config: %{root: "/var/lib/app/files"},
        scanner:        Samen.Files.Scanner.Reject,   # DEFAULT; Noop = explicit opt-in
        scanner_config: %{},
        max_bytes:      26_214_400,
        allowed_content_types: ~w(image/png image/jpeg application/pdf text/plain text/csv)

  `upload/3` also accepts each of these as an explicit opt (a test/caller override);
  opts win over config. When no `:file_module` is reachable the engine fails closed:
  it returns `{:error, :no_file_module}` rather than silently dropping the upload — an
  unrecorded file is an honest failure, not a fake success.

  ## Web-dep-free

  This chokepoint lives in `samen_core` and imposes no web dependency. A LiveView
  uses `allow_upload` + `consume_uploaded_entry` and hands the consumed binary to
  `Samen.Files.upload/3`; the LiveView NEVER writes a `storage_key` directly. The
  web integration is a later WS-E unit — this unit is the kernel chokepoint only.
  """

  require Logger

  alias Samen.Scopes.Primitives.Audit

  # Deny-by-default fallbacks. An empty allowlist means "nothing is uploadable" — a
  # fail-closed default, never `*`. The default `max_bytes` is a conservative 25 MiB.
  @default_max_bytes 26_214_400
  @default_allowed_content_types []

  # Fail-closed default scanner: `Reject` holds EVERYTHING, so absent an explicit
  # operator opt-in nothing promotes and files stay `:quarantined`. Never `Noop`.
  @default_scanner Samen.Files.Scanner.Reject

  @typedoc "An upload payload: the raw bytes plus their claimed filename + content type."
  @type payload :: %{
          required(:filename) => String.t(),
          required(:content_type) => String.t(),
          required(:binary) => binary()
        }

  @doc """
  Upload `payload` for `scope`, storing the bytes and creating a governed, quarantined
  `File` row.

  ## Arguments

    * `scope` — a map/struct carrying at least `:org_id` (the scoping boundary) and,
      optionally, `:actor_id`/`:user_id` (the uploader, recorded on the row + audit).
    * `payload` — `%{filename:, content_type:, binary:}` (see `t:payload/0`).
    * `opts` — override the config seams: `:file_module`, `:repo`, `:storage`,
      `:storage_config`, `:max_bytes`, `:allowed_content_types`, `:key` (an explicit
      storage key; one is generated when absent).

  ## Returns

    * `{:ok, file}` — bytes stored, row created (`:quarantined`), audit written.
    * `{:error, :no_file_module}`     — no `File` resource wired (fail-closed).
    * `{:error, :incomplete_payload}` — filename/content_type/binary missing.
    * `{:error, :missing_org}`        — no org_id on the scope.
    * `{:error, {:content_type_not_allowed, ct}}` — deny-by-default type refusal
      (BEFORE storage; RP-FI-5).
    * `{:error, {:too_large, size, max}}` — size refusal (BEFORE storage; RP-FI-5).
    * `{:error, reason}`              — a `Storage.put/3` or Ash create failure
      (fail-honest — never a fake ok for bytes that did not land).
  """
  @spec upload(map(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def upload(scope, payload, opts \\ []) when is_map(scope) and is_map(payload) do
    file_mod = opt(opts, :file_module)
    repo = opt(opts, :repo)
    storage = opt(opts, :storage) || Samen.Files.Storage.Local
    storage_config = opt(opts, :storage_config) || %{}
    max_bytes = opt(opts, :max_bytes) || @default_max_bytes
    allowed = opt(opts, :allowed_content_types) || @default_allowed_content_types

    org_id = fetch(scope, :org_id)
    actor_id = fetch(scope, :actor_id) || fetch(scope, :user_id)

    filename = Map.get(payload, :filename) || Map.get(payload, "filename")
    content_type = Map.get(payload, :content_type) || Map.get(payload, "content_type")
    binary = Map.get(payload, :binary) || Map.get(payload, "binary")

    cond do
      is_nil(file_mod) ->
        {:error, :no_file_module}

      is_nil(filename) or is_nil(content_type) or not is_binary(binary) ->
        {:error, :incomplete_payload}

      is_nil(org_id) ->
        {:error, :missing_org}

      true ->
        # RP-FI-5: size/type enforcement runs BEFORE Storage.put — a rejected upload
        # never touches storage. `enforce/3` returns :ok only when the type is
        # allowlisted AND the size is within bound.
        with :ok <- enforce(content_type, byte_size(binary), allowed, max_bytes) do
          key = opt(opts, :key) || generate_key(org_id, filename)

          result =
            store_and_create(storage, storage_config, key, binary, %{
              file_mod: file_mod,
              repo: repo,
              org_id: org_id,
              actor_id: actor_id,
              filename: filename,
              content_type: content_type,
              size_bytes: byte_size(binary)
            })

          emit_upload_telemetry(result, byte_size(binary))
          result
        end
    end
  end

  # WS-F5 F5.2 — a byte-size histogram sample on a stored upload, through the same
  # bounded Samen.Metrics machinery (`samen.files.upload.byte_size`). Bytes are a
  # measurement, never a label; the only tag is the bounded `:result`. Best-effort:
  # an observability emit never fails an upload.
  defp emit_upload_telemetry({:ok, _file}, byte_size) do
    :telemetry.execute([:samen, :files, :upload, :stop], %{byte_size: byte_size}, %{result: :ok})
  rescue
    _ -> :ok
  end

  defp emit_upload_telemetry(_other, _byte_size), do: :ok

  @doc """
  Deny-by-default size/type gate (RP-FI-5). Returns `:ok` only when `content_type` is
  in `allowed` (a non-empty allowlist) AND `size_bytes <= max_bytes`. An empty/unknown
  content type, or a size over the bound, is refused. Widening `allowed` to include `*`
  or `""` would break the deny-by-default contract — the allowlist is exact-match only.

  Exposed so the deny-by-default guarantee can be asserted directly AND so the LiveView
  can pre-validate an entry before consuming it.
  """
  @spec enforce(term(), non_neg_integer(), [String.t()], non_neg_integer()) ::
          :ok | {:error, term()}
  def enforce(content_type, size_bytes, allowed, max_bytes) do
    cond do
      not is_binary(content_type) or content_type == "" ->
        {:error, {:content_type_not_allowed, content_type}}

      content_type not in allowed ->
        {:error, {:content_type_not_allowed, content_type}}

      size_bytes > max_bytes ->
        {:error, {:too_large, size_bytes, max_bytes}}

      true ->
        :ok
    end
  end

  @doc """
  Returns `true` when `file` may be previewed/downloaded, `false` otherwise.

  ONLY an `:active` file is previewable. A `:quarantined` file (the fresh-upload
  default) is held; `:archived`/`:deleted` files are not served either. This is the
  fail-closed preview gate — a status the function does not explicitly clear is refused.
  """
  @spec previewable?(map()) :: boolean()
  def previewable?(file) when is_map(file), do: Map.get(file, :status) == :active
  def previewable?(_), do: false

  @doc """
  Promote a `:quarantined` `File` to `:active` — the single scan-gated promotion path
  (AC-G14-4 · RP-FI-3).

  Re-reads the file's bytes from storage, hands them to the configured
  `Samen.Files.Scanner`, and promotes to `:active` ONLY on a `{:ok, :clean}` verdict.
  A `{:ok, :held}` verdict (the `Reject` default) or a scan `{:error, _}` leaves the
  file `:quarantined` — fail-closed. On a clean verdict it writes a
  `primitives.file.promoted` audit row (scanner + verdict, token-only).

  ## Arguments

    * `scope` — a map/struct carrying `:org_id` and, optionally, `:actor_id`/`:user_id`.
    * `file`  — the `File` struct/row to promote (must carry `:id`, `:status`,
      `:storage_key`, `:org_id`).
    * `opts`  — override the config seams: `:scanner`, `:scanner_config`, `:file_module`,
      `:repo`, `:storage`, `:storage_config`.

  ## Returns

    * `{:ok, file}`            — scan was clean; the file is now `:active`.
    * `{:ok, :held, file}`     — scanner declined (`:held`); the file STAYS `:quarantined`.
    * `{:error, :already_active}` — the file was already `:active` (idempotent no-op).
    * `{:error, :no_file_module}` — no `File` resource wired (fail-closed).
    * `{:error, :missing_storage_key}` — the row carries no key to scan.
    * `{:error, {:scan_failed, reason}}` — the scanner could not run; file stays held.
    * `{:error, reason}`       — a storage read or Ash update failure.
  """
  @spec promote(map(), map(), keyword()) ::
          {:ok, struct()} | {:ok, :held, struct()} | {:error, term()}
  def promote(scope, file, opts \\ []) when is_map(scope) and is_map(file) do
    file_mod = opt(opts, :file_module)
    repo = opt(opts, :repo)
    storage = opt(opts, :storage) || Samen.Files.Storage.Local
    storage_config = opt(opts, :storage_config) || %{}
    scanner = opt(opts, :scanner) || @default_scanner
    scanner_config = opt(opts, :scanner_config) || %{}

    org_id = fetch(scope, :org_id) || Map.get(file, :org_id)
    actor_id = fetch(scope, :actor_id) || fetch(scope, :user_id)
    storage_key = Map.get(file, :storage_key)

    cond do
      is_nil(file_mod) ->
        {:error, :no_file_module}

      Map.get(file, :status) == :active ->
        {:error, :already_active}

      not is_binary(storage_key) or storage_key == "" ->
        {:error, :missing_storage_key}

      true ->
        scan_and_promote(file, %{
          storage: storage,
          storage_config: storage_config,
          scanner: scanner,
          scanner_config: scanner_config,
          storage_key: storage_key,
          file_mod: file_mod,
          repo: repo,
          org_id: org_id,
          actor_id: actor_id
        })
    end
  end

  @doc """
  Fetch the bytes of `file` for preview/download — refused unless the file is `:active`.

  This is the download/preview byte path's fail-closed gate: a `:quarantined` (or any
  non-`:active`) file returns `{:error, :not_previewable}` BEFORE storage is ever
  touched, so an unscanned file's bytes can never be served. Only when `previewable?/1`
  is `true` does it read through the configured storage adapter.
  """
  @spec fetch_bytes(map(), map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch_bytes(scope, file, opts \\ []) when is_map(scope) and is_map(file) do
    storage = opt(opts, :storage) || Samen.Files.Storage.Local
    storage_config = opt(opts, :storage_config) || %{}
    storage_key = Map.get(file, :storage_key)

    cond do
      not previewable?(file) ->
        # Fail-closed: refuse a non-:active file's bytes BEFORE storage is touched.
        {:error, :not_previewable}

      not is_binary(storage_key) or storage_key == "" ->
        {:error, :missing_storage_key}

      true ->
        storage.get(storage_key, storage_config)
    end
  end

  @doc """
  The **governed blob-deletion chokepoint** (ADR-046 §4.3 · D4/T130) — the delete twin
  of `upload/3` (the only `storage_key` MINT). This is the ONLY path in `lib/` that ever
  calls the storage adapter's `delete/2`, so blob deletion is governed-by-construction,
  exactly as `Samen.Files.ChokepointGuard` makes minting governed.

  It removes ONE reference to a blob (the `file` row) and physically deletes the blob
  bytes ONLY when it was the **last** reference (`Samen.Clone` re-links `storage_key`
  verbatim, so N `File` rows can alias one blob — T130). Everything a blob delete must be
  is enforced here, in order, inside ONE transaction:

    1. **Advisory-lock the blob key** (`pg_advisory_xact_lock(hashtext(key))`) so the
       count-then-delete critical section is mutually exclusive across concurrent deletes
       of the SAME blob. This is what makes ref-counting correct under concurrency: two
       transactions deleting the last two references SERIALIZE on the lock, so exactly one
       sees `refs_remaining == 0` and deletes — never both (no double-delete), never
       neither (no orphaned live blob), never a delete while a reference remains (no
       premature delete). The count is DERIVED from the physical rows (not a stored
       counter that could drift): the rows ARE the references.
    2. **Governed destroy of the reference row** through the resource's real terminal
       destroy action (`:destroy_permanently` on an archivable resource, else `:destroy`)
       — the same governed, audited, chokepoint-guarded path a normal destroy takes (the
       destroy sets no `storage_key`, so `ChokepointGuard` passes it structurally).
    3. **Count remaining references** — every physical row (live, archived, quarantined)
       still pointing at `storage_key`, archive-state-inclusive (an archived alias still
       references its bytes and must keep the blob alive).
    4. **Last-reference delete** — when `refs_remaining == 0`, call the configured
       fail-honest adapter's `delete/2`. **Fail-honest + fail-closed** (ADR-026): an
       unconfigured/unimplemented adapter returns `{:error, _}` — a delete that did NOT
       happen must not report success on a compliance path. On such an error the whole
       transaction ROLLS BACK, so the last reference is NOT dropped while the blob
       survives (no silent orphan) and the caller sees the honest error.
    5. **Audit** — a token-only `primitives.file.blob_deleted` event, org-attributed
       (`correlation_id = org_id`), carrying only `blob_deleted?`/`refs_remaining` — never
       the filename or `storage_key`.

  ## Who may call it

  The internal erasure/retention driver (`Samen.Files.Erasure`, wired into
  `Samen.Erasure.shred/2`) and a host's governed File-destroy path. Never an ad-hoc raw
  `storage.delete` — that would bypass the ref-count and could destroy a still-referenced
  clone's bytes (T130). Because this is the only `storage.delete` caller, "no ungoverned
  blob delete" holds by construction.

  ## Arguments / returns

    * `scope` — a map/struct carrying `:org_id` and, optionally, `:actor_id`/`:user_id`.
    * `file`  — the `File` struct to delete (must carry `:id`, `:storage_key`, `:org_id`).
    * `opts`  — `:file_module`, `:repo`, `:storage`, `:storage_config` (opts win over config).

    * `{:ok, %{blob_deleted: boolean, refs_remaining: non_neg_integer, file_id: term}}` —
      the reference was removed; `blob_deleted` is `true` iff it was the last reference AND
      the adapter deleted the bytes.
    * `{:error, :no_file_module | :no_repo | :missing_storage_key}` — fail-closed.
    * `{:error, {:blob_delete_failed, reason}}` — last reference, but the fail-honest
      adapter refused; the transaction rolled back (reference preserved).
  """
  @spec delete_file(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_file(scope, file, opts \\ []) when is_map(scope) and is_map(file) do
    file_mod = opt(opts, :file_module)
    repo = opt(opts, :repo)
    storage = opt(opts, :storage) || Samen.Files.Storage.Local
    storage_config = opt(opts, :storage_config) || %{}

    org_id = fetch(scope, :org_id) || Map.get(file, :org_id)
    actor_id = fetch(scope, :actor_id) || fetch(scope, :user_id)
    storage_key = Map.get(file, :storage_key)

    cond do
      is_nil(file_mod) ->
        {:error, :no_file_module}

      is_nil(repo) ->
        {:error, :no_repo}

      not is_binary(storage_key) or storage_key == "" ->
        {:error, :missing_storage_key}

      true ->
        do_delete_file(file, %{
          file_mod: file_mod,
          repo: repo,
          storage: storage,
          storage_config: storage_config,
          storage_key: storage_key,
          org_id: org_id,
          actor_id: actor_id
        })
    end
  end

  # ---------------------------------------------------------------------------
  # Governed blob delete — the transactional, advisory-locked, last-reference core.
  # ---------------------------------------------------------------------------
  defp do_delete_file(file, ctx) do
    ctx.repo.transaction(fn ->
      # (1) Serialize concurrent deletes of THIS blob (see delete_file/3 §1).
      lock_blob(ctx.repo, ctx.storage_key)

      # (2) Remove this reference through the resource's real terminal destroy action.
      case destroy_reference(file, ctx) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> ctx.repo.rollback({:reference_destroy_failed, reason})
      end

      # (3) Count remaining physical references to the blob (archive-inclusive).
      remaining = count_refs(ctx.repo, ctx.file_mod, ctx.storage_key)

      # (4) Last-reference delete — fail-honest, fail-closed.
      blob_deleted =
        if remaining == 0 do
          case ctx.storage.delete(ctx.storage_key, ctx.storage_config) do
            :ok ->
              true

            {:error, reason} ->
              # A delete that did NOT happen must not report success, and the last
              # reference must not be dropped while the blob survives: roll back.
              ctx.repo.rollback({:blob_delete_failed, reason})
          end
        else
          false
        end

      # (5) Token-only, org-attributed audit of the blob deletion.
      emit_delete_audit(ctx, file, blob_deleted, remaining)

      %{blob_deleted: blob_deleted, refs_remaining: remaining, file_id: Map.get(file, :id)}
    end)
  end

  # A transaction-scoped advisory lock keyed on the blob storage_key. Held until the
  # surrounding transaction commits/rolls back, so it serializes the count-then-delete
  # critical section across concurrent delete transactions for the same blob.
  defp lock_blob(repo, key) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  # Hard-remove the reference row: `:destroy_permanently` on an archivable resource (its
  # primary `:destroy` is SOFT — it would only archive, leaving the row referencing the
  # blob), else the plain `:destroy`. Neither sets a `storage_key`, so ChokepointGuard
  # passes them structurally.
  defp destroy_reference(file, ctx) do
    action = if Samen.Info.archivable?(ctx.file_mod), do: :destroy_permanently, else: :destroy

    file
    |> Ash.Changeset.for_destroy(action, %{})
    |> Ash.destroy(authorize?: false)
  end

  # DERIVED reference count: every physical row still pointing at `storage_key`, counted
  # over the raw table so it is archive-state-inclusive (an archived alias still keeps the
  # blob alive) and cannot be hidden by an archival read preparation. The table name comes
  # from AshPostgres introspection (never user input) and is charset-validated before
  # interpolation.
  defp count_refs(repo, file_mod, key) do
    table = AshPostgres.DataLayer.Info.table(file_mod)
    # The physical column is abbrev-prefixed (e.g. `sca_storage_key`), NOT the logical
    # attribute name — resolve its `source` from Ash introspection.
    column = attribute_source(file_mod, :storage_key)

    unless safe_identifier?(table) and safe_identifier?(column) do
      raise ArgumentError,
            "unsafe or missing table/column for #{inspect(file_mod)}: " <>
              "#{inspect(table)} / #{inspect(column)}"
    end

    %{rows: [[n]]} =
      repo.query!("SELECT count(*) FROM \"#{table}\" WHERE \"#{column}\" = $1", [key])

    n
  end

  defp attribute_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end

  # Identifiers come from Ash introspection (never user input); validate the charset
  # before interpolation as belt-and-braces against a malformed abbrev.
  defp safe_identifier?(id), do: is_binary(id) and Regex.match?(~r/\A[a-z0-9_]+\z/, id)

  defp emit_delete_audit(ctx, file, blob_deleted, remaining) do
    audit_repo = ctx.repo || Application.get_env(:samen_core, :verify_repo)

    if audit_repo do
      try do
        Audit.file_blob_deleted(
          audit_repo,
          %{id: Map.get(file, :id), org_id: ctx.org_id},
          ctx.actor_id,
          %{blob_deleted: blob_deleted, refs_remaining: remaining}
        )
      rescue
        e ->
          Logger.warning(
            "[Samen.Files] blob-delete audit emit failed for file " <>
              "#{inspect(Map.get(file, :id))}: #{Exception.message(e)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------

  defp scan_and_promote(file, ctx) do
    with {:ok, binary} <- ctx.storage.get(ctx.storage_key, ctx.storage_config),
         {:ok, verdict} <- run_scan(ctx.scanner, binary, ctx.scanner_config) do
      case verdict do
        :clean ->
          # A clean verdict is the ONLY path to :active. The gate is here: promote is
          # never reached without `{:ok, :clean}` from the configured scanner.
          do_promote(file, ctx)

        :held ->
          # The scanner declined (the `Reject` default). Fail-closed: the file stays
          # :quarantined. Return the file unchanged so the caller sees it was held.
          {:ok, :held, file}
      end
    else
      {:error, reason} -> {:error, {:scan_failed, reason}}
    end
  end

  # Normalize a scanner return into `{:ok, verdict}` | `{:error, reason}`. A scanner that
  # returns anything other than a clean/held verdict is treated as fail-closed error —
  # an unrecognized verdict never promotes.
  defp run_scan(scanner, binary, scanner_config) do
    case scanner.scan(binary, scanner_config) do
      {:ok, :clean} -> {:ok, :clean}
      {:ok, :held} -> {:ok, :held}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_verdict, other}}
    end
  end

  defp do_promote(file, ctx) do
    result =
      file
      |> Ash.Changeset.for_update(:update, %{status: :active})
      |> Ash.update(authorize?: false)

    case result do
      {:ok, promoted} ->
        emit_promote_audit(
          ctx.repo,
          %{id: promoted.id, org_id: ctx.org_id, scanner: ctx.scanner, verdict: :clean},
          ctx.actor_id
        )

        {:ok, ensure_loaded(promoted, ctx.org_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------

  defp store_and_create(storage, storage_config, key, binary, meta) do
    case storage.put(key, binary, storage_config) do
      {:ok, _put_meta} ->
        create_row(key, meta)

      {:error, reason} ->
        # Fail-honest: bytes did not land, so NO File row is created. The upload is
        # an honest error, never a governed row pointing at a key that was never
        # written.
        {:error, reason}
    end
  end

  defp create_row(storage_key, meta) do
    attrs =
      %{
        filename: meta.filename,
        content_type: meta.content_type,
        size_bytes: meta.size_bytes,
        storage_key: storage_key,
        uploaded_by_id: meta.actor_id,
        org_id: meta.org_id
        # status is DELIBERATELY not set — the resource default (`:quarantined`,
        # fail-closed) governs. This engine never promotes a fresh file to :active
        # (RP-FI-3).
      }
      |> reject_nil()

    result =
      meta.file_mod
      |> Ash.Changeset.for_create(:create, attrs)
      # Stamp the governed-path marker so Samen.Files.ChokepointGuard admits this
      # storage_key create (ADR-026 RP-FI-1 / AC-G14-2). A direct Ash.create that does
      # NOT pass through this chokepoint carries no marker and is refused — that is what
      # makes "no ungoverned file row" structural, not convention.
      |> Ash.Changeset.set_context(%{private: %{Samen.Files.ChokepointGuard.marker_key() => true}})
      |> Ash.create(authorize?: false)

    case result do
      {:ok, file} ->
        # The audit writer reads `org_id`/`status`; Ash may return those as
        # NotLoaded on the fresh create struct. Emit the audit against a plain map
        # built from values we already hold (the org_id in hand + the resource's
        # quarantine default) so the token-only row lands regardless of load state.
        emit_audit(meta.repo, %{id: file.id, org_id: meta.org_id, status: :quarantined}, meta.actor_id)
        {:ok, ensure_loaded(file, meta.org_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Return a struct whose org_id is populated for the caller. Ash may hand back a
  # create result with org_id as NotLoaded; reload the org_id (a cheap read) so the
  # caller always sees the scoping boundary on the returned row.
  defp ensure_loaded(file, org_id) do
    case Map.get(file, :org_id) do
      %Ash.NotLoaded{} -> %{file | org_id: org_id}
      nil -> %{file | org_id: org_id}
      _ -> file
    end
  rescue
    _ -> file
  end

  # ---------------------------------------------------------------------------
  # Audit (rides the aud_event tier via the Primitives writer; token-only).

  defp emit_audit(repo, file, actor_id) do
    audit_repo = repo || Application.get_env(:samen_core, :verify_repo)

    if audit_repo do
      try do
        Audit.file_uploaded(audit_repo, file, actor_id)
      rescue
        e ->
          Logger.warning(
            "[Samen.Files] audit emit failed for file " <>
              "#{inspect(Map.get(file, :id))}: #{Exception.message(e)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp emit_promote_audit(repo, file, actor_id) do
    audit_repo = repo || Application.get_env(:samen_core, :verify_repo)

    if audit_repo do
      try do
        Audit.file_promoted(audit_repo, file, actor_id)
      rescue
        e ->
          Logger.warning(
            "[Samen.Files] promote audit emit failed for file " <>
              "#{inspect(Map.get(file, :id))}: #{Exception.message(e)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Storage key generation. The key is opaque + org-namespaced; the sanitized
  # filename tail is a convenience only (the storage adapter enforces its own
  # deny-by-default key charset). Never a raw, caller-controlled path.

  defp generate_key(org_id, filename) do
    ext =
      filename
      |> Path.extname()
      |> String.replace(~r{[^A-Za-z0-9.]}, "")

    "#{org_id}/#{Ash.UUID.generate()}#{ext}"
  end

  # ---------------------------------------------------------------------------
  # Config / opt resolution (opts win over config).

  defp opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(config(), key)
    end
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])

  defp fetch(scope, key), do: Map.get(scope, key) || Map.get(scope, to_string(key))

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
