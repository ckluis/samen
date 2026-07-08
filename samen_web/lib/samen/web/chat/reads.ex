defmodule Samen.Web.Chat.Reads do
  @moduledoc """
  The framework read layer for chat (ADR-012 §6.1) — every function reads the host's
  materialized Chat resources through Ash (so `OrgScope` narrows to the viewer's org) and
  resolves every PII field through `Samen.Api.PiiResolution` for the scope's plane (tenant
  clear / operator `••••`). The SAME discipline as `Samen.Web.CRM.Reads`.

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a vault token out of a
  `%Masked{}`, and NEVER introduces a "show plaintext" code path. Plaintext only reaches the
  LiveView if the resolver already resolved it through the shared chokepoint for the viewer's
  plane. A resolver failure keeps `%Masked{}` (no plaintext downgrade). This is why the
  id-only PubSub envelope (ADR-012 §3.1) is safe: each subscriber re-reads through THIS layer
  with its OWN scope, so the body resolves per the RECEIVING viewer's plane — a masked
  operator session cannot obtain plaintext even by listening on the topic.

  Note the read functions take the HOST namespace off the `mount` (never a hardcoded host
  module), so the SAME code reads driftwood's chat inside driftwood and pawchart's inside
  pawchart.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @doc "Read all chat threads for `scope`, newest-first. Non-PII (subject/kind/status)."
  def threads(mount, scope) do
    Mount.resource(mount, ChatThread)
    |> Ash.Query.ensure_selected([:subject, :kind, :status, :disclosure_mode, :context_ref])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a single thread by id for `scope`. `{:ok, thread}` or `:error`. Non-PII."
  def get_thread(mount, scope, id) do
    Mount.resource(mount, ChatThread)
    |> Ash.Query.ensure_selected([:subject, :kind, :status, :disclosure_mode, :context_ref])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(scope: scope)
    |> case do
      [thread | _] -> {:ok, thread}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Read a thread's messages for `scope`, oldest-first, with `body` PII plane-resolved
  (tenant clear / operator `••••`). The vaulted body is resolved through the shared
  chokepoint — this is the re-read the `handle_info` broadcast path calls per subscriber.
  """
  def messages(mount, scope, thread_id) do
    Mount.resource(mount, ChatMessage)
    |> Ash.Query.ensure_selected([:body, :sender_party, :kind, :refs, :participant_id, :thread_id])
    |> Ash.Query.filter(thread_id == ^thread_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, ChatMessage, scope)
  rescue
    _ -> []
  end

  @doc """
  Read a SINGLE message by id for `scope`, with `body` PII plane-resolved. `{:ok, message}`
  or `:error`. This is the re-read seam a subscriber's `handle_info` calls on a broadcast:
  the SAME message id resolves CLEAR for a tenant subscriber and `••••` for an operator
  subscriber (ADR-012 §3.2 — masking survives the realtime path by construction).
  """
  def get_message(mount, scope, id) do
    Mount.resource(mount, ChatMessage)
    |> Ash.Query.ensure_selected([:body, :sender_party, :kind, :refs, :participant_id, :thread_id])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, ChatMessage, scope)
    |> case do
      [message | _] -> {:ok, message}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Read a thread's participants for `scope`. `full_name` is NOT resolved here — the identity
  model (`Samen.Web.Chat.Identity`) chooses WHICH plane's actor resolves each participant's
  identity per the stored disclosure state (§5.1). This function returns the raw rows
  (`full_name` still `%Masked{}`); `Samen.Web.Chat.Identity.resolve_participant/4` does the
  plane-choice resolve. The non-PII `handle`/`party` are always present.
  """
  def participants(mount, scope, thread_id) do
    Mount.resource(mount, ChatParticipant)
    |> Ash.Query.ensure_selected([
      :party,
      :principal_kind,
      :principal_id,
      :handle,
      :identity_shared,
      :role,
      :full_name,
      :online_at,
      :thread_id
    ])
    |> Ash.Query.filter(thread_id == ^thread_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a single participant by id for `scope` (raw; identity NOT resolved). `{:ok, p}` or `:error`."
  def get_participant(mount, scope, id) do
    Mount.resource(mount, ChatParticipant)
    |> Ash.Query.ensure_selected([
      :party,
      :principal_kind,
      :principal_id,
      :handle,
      :identity_shared,
      :role,
      :full_name,
      :online_at,
      :thread_id
    ])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(scope: scope)
    |> case do
      [participant | _] -> {:ok, participant}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Read the org's `ChatDisclosureSetting` (§5 state 3). Returns the row or `nil` if none set
  (the masked floor). Non-PII — a policy flag.
  """
  def disclosure_setting(mount, scope) do
    Mount.resource(mount, ChatDisclosureSetting)
    |> Ash.Query.ensure_selected([:expose_identity_to_support])
    |> Ash.read!(scope: scope)
    |> List.first()
  rescue
    _ -> nil
  end

  # -- private -----------------------------------------------------------------

  # Resolve PII fields through the shared chokepoint; resource + repo from the mount.
  # Fail-safe: on any resolver error the fields stay %Masked{} (no plaintext downgrade).
  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
