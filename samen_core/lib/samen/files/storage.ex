defmodule Samen.Files.Storage do
  @moduledoc """
  Pluggable object-storage contract for the files engine (ADR-026 §2, decision 1).

  A host application selects a storage adapter per environment. The kernel ships:

    * `Samen.Files.Storage.Local` — the CI/dev default. A REAL implementation:
      it writes bytes to a configured root directory and round-trips them back.
      `configured?/1` is `true` whenever a root dir is resolvable (it always is,
      via `System.tmp_dir!/0`), so the local engine works out of the box.
    * `Samen.Files.Storage.S3` — a **skeleton** (operator TODO). No `ex_aws`/`req`
      dependency is added (ADR-026, ratified). `configured?/1` returns `false`
      absent creds, and every write/read/presign returns `{:error, :not_configured}`
      rather than faking success. Real S3 wiring is an operator TODO.

  ## The fail-honest contract

  This is the same load-bearing rule the `Samen.Delivery.Provider` (ADR-014/ADR-038) shipped:
  an adapter that is not configured must NEVER return `{:ok, _}` for an operation it
  did not actually perform. For storage that means `put/3` on an unconfigured
  adapter MUST return `{:error, reason}` and MUST NOT return `{:ok, _}` — a stub
  that reports success for a no-op is exactly the tautological lie this contract
  exists to abolish. `configured?/1` is the honest gate: it reports whether the
  adapter has real backing (creds, endpoint, a writable root), never a fixed `true`
  for a backend that cannot actually store a byte.

  ## Web-dep-free

  This contract lives in `samen_core` and imposes no web dependency. An adapter that
  needs HTTP (e.g. a real S3 client) pulls its own client in the host app; the
  behaviour references none.
  """

  @typedoc "The opaque storage key that locates the bytes for a file."
  @type key :: String.t()

  @typedoc "Adapter configuration (root dir, bucket, creds, …) supplied by the host."
  @type config :: map()

  @typedoc "Metadata a successful `put/3` returns to the caller (size, backend, …)."
  @type put_meta :: map()

  @doc """
  Returns `true` when the adapter has everything it needs to actually store and
  serve bytes (a writable root, a bucket + creds, …), `false` otherwise. An
  adapter that answers `false` here MUST NOT be asked to `put/3` — the caller
  treats an unconfigured adapter as a fail-honest error, never a silent no-op
  success.
  """
  @callback configured?(config()) :: boolean()

  @doc """
  Store `binary` under `key`. Returns `{:ok, meta}` ONLY when the bytes were
  actually written to durable backing; returns `{:error, reason}` otherwise. It
  must NEVER return `{:ok, _}` for a no-op — the byte-level round-trip
  (`put/3` then `get/2` returns the same bytes) is the observable proof the store
  did its job.
  """
  @callback put(key(), binary(), config()) :: {:ok, put_meta()} | {:error, term()}

  @doc """
  Fetch the bytes stored under `key`. Returns `{:ok, binary}` when the object
  exists, `{:error, reason}` (e.g. `:not_found`, `:not_configured`) otherwise.
  """
  @callback get(key(), config()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Delete the object stored under `key`. Returns `:ok` on success (idempotently —
  deleting a missing key is `:ok`), `{:error, reason}` otherwise.
  """
  @callback delete(key(), config()) :: :ok | {:error, term()}

  @doc """
  Produce a URL that grants time-bounded read access to `key`. For `Local` this is
  a framework-served route; for `S3` a real presigned URL once creds exist. Returns
  `{:error, :not_configured}` when the adapter has no backing.
  """
  @callback presign_get(key(), config()) :: {:ok, String.t()} | {:error, term()}
end
