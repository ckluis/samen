defmodule Samen.Files.Storage.S3 do
  @moduledoc """
  S3 object-storage adapter — **skeleton** (ADR-026 §2, decision 1; operator TODO).

  This mirrors the shipped `Samen.Delivery.Smtp` fail-honest precedent (ADR-014 §2):
  the seam is real, but its default is honest, not a lie.

  `configured?/1` returns `true` ONLY when the S3 creds (`:bucket` + `:access_key_id`
  + `:secret_access_key`) are present in the adapter config; otherwise `false`.
  Because no `ex_aws`/`req`/`finch` dependency is added to the tree (ADR-026,
  ratified), the actual S3 dispatch is not yet wired:

    * `put/3` returns `{:error, :not_configured}` when creds are absent, and
      `{:error, :not_implemented}` once creds exist — it NEVER returns `{:ok, _}`,
      because no byte is ever actually stored. A stub that returned `{:ok}` here
      would be the exact tautological lie the fail-honest contract abolishes.
    * `get/2`, `delete/2`, and `presign_get/2` follow the same rule.

  This is the fail-honest seam: an unconfigured S3 adapter refuses the operation
  rather than pretending it stored the bytes. Real S3 wiring (a host-supplied HTTP
  client using Erlang `:httpc` or a client pulled in the host app) is an operator
  TODO.

  Web-dep-free: this module references no HTTP/web library.
  """
  @behaviour Samen.Files.Storage

  @impl Samen.Files.Storage
  def configured?(config) when is_map(config) do
    present?(config, :bucket) and
      present?(config, :access_key_id) and
      present?(config, :secret_access_key)
  end

  def configured?(_), do: false

  @impl Samen.Files.Storage
  def put(key, binary, config)
      when is_binary(key) and is_binary(binary) and is_map(config) do
    unconfigured_or_todo(config)
  end

  def put(_key, _binary, _config), do: {:error, :invalid_argument}

  @impl Samen.Files.Storage
  def get(key, config) when is_binary(key) and is_map(config) do
    unconfigured_or_todo(config)
  end

  def get(_key, _config), do: {:error, :invalid_argument}

  @impl Samen.Files.Storage
  def delete(key, config) when is_binary(key) and is_map(config) do
    # delete/2's contract allows :ok, but S3 is fail-honest: absent a real
    # backend it refuses rather than reporting a delete it never performed.
    unconfigured_or_todo(config)
  end

  def delete(_key, _config), do: {:error, :invalid_argument}

  @impl Samen.Files.Storage
  def presign_get(key, config) when is_binary(key) and is_map(config) do
    unconfigured_or_todo(config)
  end

  def presign_get(_key, _config), do: {:error, :invalid_argument}

  # Fail-honest core: absent creds → :not_configured; with creds → :not_implemented
  # (no dep to dispatch with, per ADR-026). NEVER {:ok, _}: no byte is stored.
  defp unconfigured_or_todo(config) do
    if configured?(config) do
      # Operator TODO: real S3 dispatch (PUT/GET/DELETE, SigV4 presign) using
      # config creds. Until wired, this is not-yet-implemented rather than a fake
      # success — a fail-honest refusal.
      {:error, :not_implemented}
    else
      {:error, :not_configured}
    end
  end

  defp present?(config, key) do
    case Map.get(config, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
