defmodule Samen.Files.Storage.Local do
  @moduledoc """
  Local-filesystem storage adapter — a REAL implementation (ADR-026 §2, decision 1).

  This is the CI/dev default for the files engine. It writes bytes to a configured
  root directory and reads them back — a genuine byte round-trip, not a stub. It is
  single-node (fine for dev/CI/a single Fly machine); multi-node deployments wire
  `Samen.Files.Storage.S3` (operator TODO).

  ## Root resolution

  The storage root is taken from `config[:root]` (a host- or per-env-supplied
  directory). Absent an explicit root it falls back to a stable subdirectory of the
  system temp dir, so the adapter is always `configured?/1 == true` and works out of
  the box in dev/CI. Keys are stored as files beneath the root.

  ## Key safety

  A storage `key` is an opaque string the chokepoint generates; it is joined onto
  the root as a relative path. Keys are constrained to a safe charset and any `..`
  path-traversal segment is refused (`{:error, :invalid_key}`) so a caller can never
  read or write outside the configured root. This is the fail-closed posture applied
  to path handling: an ambiguous/unsafe key is rejected, never silently coerced.

  ## Fail-honest

  `put/3` returns `{:ok, meta}` ONLY after the bytes are actually on disk (the write
  is verified by the subsequent `get/2` round-trip in tests); a write that fails
  returns `{:error, reason}` — never a faked success.

  Web-dep-free: this module references no HTTP/web library. `presign_get/2` returns
  a framework-served relative path (`/files/…`) the web layer mounts; it does not
  build a URL host here.
  """
  @behaviour Samen.Files.Storage

  @default_subdir "samen_core_files"

  @impl Samen.Files.Storage
  def configured?(config) when is_map(config), do: is_binary(root(config))
  def configured?(_), do: false

  @impl Samen.Files.Storage
  def put(key, binary, config) when is_binary(key) and is_binary(binary) and is_map(config) do
    with {:ok, path} <- resolve_path(key, config),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, binary) do
      {:ok, %{backend: __MODULE__, key: key, size_bytes: byte_size(binary)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def put(_key, _binary, _config), do: {:error, :invalid_argument}

  @impl Samen.Files.Storage
  def get(key, config) when is_binary(key) and is_map(config) do
    with {:ok, path} <- resolve_path(key, config) do
      case File.read(path) do
        {:ok, binary} -> {:ok, binary}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def get(_key, _config), do: {:error, :invalid_argument}

  @impl Samen.Files.Storage
  def delete(key, config) when is_binary(key) and is_map(config) do
    with {:ok, path} <- resolve_path(key, config) do
      # rm/1 returns :ok for a missing file's parent? No — File.rm on a missing
      # path is {:error, :enoent}; treat that as idempotent success.
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def delete(_key, _config), do: {:error, :invalid_argument}

  @impl Samen.Files.Storage
  def presign_get(key, config) when is_binary(key) and is_map(config) do
    # Local storage serves bytes through the app's plane-gated /files route; there
    # is no external signed URL. Return the framework-relative path the web layer
    # mounts. Fail-closed on an unsafe key.
    case safe_relative_key(key) do
      {:ok, safe} -> {:ok, "/files/" <> safe}
      {:error, reason} -> {:error, reason}
    end
  end

  def presign_get(_key, _config), do: {:error, :invalid_argument}

  # ---------------------------------------------------------------------------

  # Resolve the on-disk absolute path for a key, refusing traversal/unsafe keys.
  defp resolve_path(key, config) do
    with {:ok, safe} <- safe_relative_key(key) do
      {:ok, Path.join(root(config), safe)}
    end
  end

  # Deny-by-default key validation: allow a conservative charset for path segments
  # and refuse any empty, absolute, or `..`-containing key.
  defp safe_relative_key(key) do
    cond do
      key == "" -> {:error, :invalid_key}
      String.starts_with?(key, "/") -> {:error, :invalid_key}
      ".." in Path.split(key) -> {:error, :invalid_key}
      not Regex.match?(~r{\A[A-Za-z0-9._/\-]+\z}, key) -> {:error, :invalid_key}
      true -> {:ok, key}
    end
  end

  defp root(config) do
    case Map.get(config, :root) do
      root when is_binary(root) and root != "" -> root
      _ -> Path.join(System.tmp_dir!(), @default_subdir)
    end
  end
end
