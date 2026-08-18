defmodule Samen.Scopes.Chat.Attachments do
  @moduledoc """
  Chat attachments (T61 / C7) — files attached to a chat message, minted ONLY through
  the Files chokepoint.

  ## Chokepoint, quarantine, org-scope (by construction)

  `upload/3` is a thin, honest passthrough to `Samen.Files.upload/3` — the ONLY path that
  mints a `storage_key`. It NEVER writes a `storage_key` itself, so `Samen.Files.ChokepointGuard`
  structurally refuses any bypass (a direct `Ash.create`/`Ash.update` that sets a
  `storage_key` is aborted in-transaction). The minted File lands `:quarantined`
  (fail-closed): it is NOT viewable/downloadable until a clean scan promotes it to
  `:active` (`Samen.Files.promote/3`, `Scanner.Reject` default). The File carries the
  message's `org_id`, so its own `OrgScope` read policy makes an attachment on org A's
  message unreachable from org B.

  ## The attach idiom (matches `Samen.Support.Inbound.Ingest.store_attachments/2`)

    1. `{:ok, file} = Attachments.upload(scope, %{filename:, content_type:, binary:}, opts)`
       — the file is `:quarantined`.
    2. Collect `file.storage_key`.
    3. Write the collected keys onto the `ChatMessage.attachments` `{:array, :string}`
       attribute at message-create time (NEVER a `storage_key` on any other resource
       directly — the guard refuses it).
    4. Serve/preview through the framework `/files/:id` `BytesController` (org-scoped +
       plane-gated + quarantine-gated) — zero new download code.

  `opts` are the mount's file facts (`:file_module`, `:repo`, `:storage`,
  `:storage_config`, `:allowed_content_types`, `:max_bytes`, ...), forwarded verbatim to
  `Samen.Files.upload/3`. A vertical that `use Samen.Scopes.Chat`s adopts this at ≈0
  authored LOC — the web upload wiring passes the facts from the `Mount`.
  """

  require Ash.Query

  @doc """
  Upload one attachment blob for a chat message THROUGH the Files chokepoint.

  Returns `{:ok, file}` where `file.status == :quarantined` (fail-closed), or
  `{:error, reason}` from `Samen.Files.upload/3` (fail-honest — never a faked `:ok`).
  """
  @spec upload(map(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def upload(scope, payload, opts \\ []) do
    Samen.Files.upload(file_scope(scope), payload, opts)
  end

  # The Files chokepoint stamps `uploaded_by_id` (a `:uuid`) from `:actor_id` — include it
  # ONLY when the acting id is a bare UUID (a plane actor id like `"broker:<uuid>"` is a
  # display id, not a stored uuid, so it is omitted rather than coerced).
  defp file_scope(scope) do
    org_id = org_id_of(scope)
    actor_id = actor_id_of(scope)

    if is_binary(actor_id) and match?({:ok, _}, Ecto.UUID.cast(actor_id)) do
      %{org_id: org_id, actor_id: actor_id}
    else
      %{org_id: org_id}
    end
  end

  @doc """
  Load the File rows for a message's `attachments` storage_keys, ORG-SCOPED to the actor.

  Reads through `Ash.read!(scope: scope)` so the File's `OrgScope` read policy applies —
  a cross-org storage_key returns nothing (never reachable from another org). Bounded by
  the caller-supplied key list. `opts` require `:file_module` (the host's File resource).
  """
  @spec load(map(), [String.t()], keyword()) :: [struct()]
  def load(_scope, [], _opts), do: []

  def load(scope, storage_keys, opts) when is_list(storage_keys) do
    file_module = Keyword.fetch!(opts, :file_module)
    keys = Enum.filter(storage_keys, &is_binary/1)

    case keys do
      [] ->
        []

      keys ->
        file_module
        |> Ash.Query.new()
        |> Ash.Query.filter(storage_key in ^keys)
        |> Ash.read!(scope: scope)
    end
  end

  # -- scope helpers -----------------------------------------------------------

  defp org_id_of(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp org_id_of(%{org_id: org_id}), do: org_id
  defp org_id_of(%{actor: %{org_id: org_id}}), do: org_id
  defp org_id_of(_), do: nil

  defp actor_id_of(%Samen.Scope{actor: %{id: id}}), do: id
  defp actor_id_of(%{actor: %{id: id}}), do: id
  defp actor_id_of(%{actor_id: id}), do: id
  defp actor_id_of(_), do: nil
end
