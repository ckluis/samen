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
  alias Samen.Web.Reads.Guard

  # A3 read-bounding (WS-A design §1.1 "read! elimination", AC-G1-5): every chat read
  # carries an explicit limit. The inbox and a thread's messages/participants are
  # single-parent fan-outs bounded to the kit's hard page cap rather than paginated —
  # an unbounded `.read!()` here was a deep-scan/row-transfer DoS bound (A3-GATE-1),
  # not a masking hole (PII still resolves through `PiiResolution` per plane).
  @detail_limit 200

  @participant_fields [
    :party,
    :principal_kind,
    :principal_id,
    :handle,
    :identity_shared,
    :role,
    :full_name,
    :online_at,
    :thread_id
  ]

  @doc """
  Read chat threads for `scope`, newest-first. Non-PII (subject/kind/status).
  BOUNDED to `#{@detail_limit}` rows (A3 read-bounding).
  """
  def threads(mount, scope), do: threads_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `threads/2` (WP6): `{:ok, rows}` or `{:error, :unavailable | :forbidden}`; an outage is not an empty inbox."
  def threads_result(mount, scope) do
    Guard.run(:chat_threads, scope, fn ->
      Mount.resource(mount, ChatThread)
      |> Ash.Query.ensure_selected([:subject, :kind, :status, :disclosure_mode, :context_ref])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Read a single thread by id for `scope`. `{:ok, thread}` or `:error`. Non-PII."
  def get_thread(mount, scope, id) do
    case get_thread_result(mount, scope, id) do
      {:ok, thread} -> {:ok, thread}
      {:error, _} -> :error
    end
  end

  @doc """
  Tagged sibling of `get_thread/3` (WP6): `{:ok, thread}`, `{:error, :not_found}` for a missing,
  malformed-id or denied record, and `{:error, :unavailable}` ONLY when the read FAILED.
  """
  def get_thread_result(mount, scope, id) do
    single_result(:chat_get_thread, scope, id, fn uuid ->
      Mount.resource(mount, ChatThread)
      |> Ash.Query.ensure_selected([:subject, :kind, :status, :disclosure_mode, :context_ref])
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  Read a thread's messages for `scope`, oldest-first, with `body` PII plane-resolved
  (tenant clear / operator `••••`). The vaulted body is resolved through the shared
  chokepoint — this is the re-read the `handle_info` broadcast path calls per subscriber.
  BOUNDED to the NEWEST `#{@detail_limit}` rows (A3 read-bounding), shown in display order;
  `messages_window/3` also reports whether older messages were left out.
  """
  def messages(mount, scope, thread_id), do: elem(messages_window(mount, scope, thread_id), 0)

  @doc "Like `messages/3` but `{messages, earlier_hidden?}` — `true` when older messages were cut."
  def messages_window(mount, scope, thread_id),
    do: messages_window_result(mount, scope, thread_id) |> Guard.value({[], false})

  @doc "Tagged sibling of `messages_window/3` (WP6): `{:ok, {messages, earlier_hidden?}}` or `{:error, :unavailable | :forbidden}`; an outage is not an empty conversation."
  def messages_window_result(mount, scope, thread_id) do
    Guard.run(:chat_messages_window, scope, fn ->
      {rows, truncated?} =
        Mount.resource(mount, ChatMessage)
        |> Ash.Query.ensure_selected([:body, :sender_party, :kind, :refs, :participant_id, :thread_id])
        |> Ash.Query.filter(thread_id == ^thread_id)
        |> Samen.Web.Reads.newest_window(@detail_limit, scope: scope)

      {resolve_pii(rows, mount, ChatMessage, scope), truncated?}
    end)
  end

  @doc """
  Read a SINGLE message by id for `scope`, with `body` PII plane-resolved. `{:ok, message}`
  or `:error`. This is the re-read seam a subscriber's `handle_info` calls on a broadcast:
  the SAME message id resolves CLEAR for a tenant subscriber and `••••` for an operator
  subscriber (ADR-012 §3.2 — masking survives the realtime path by construction).
  """
  def get_message(mount, scope, id) do
    case get_message_result(mount, scope, id) do
      {:ok, message} -> {:ok, message}
      {:error, _} -> :error
    end
  end

  @doc "Tagged sibling of `get_message/3` (WP6); same contract as `get_thread_result/3`."
  def get_message_result(mount, scope, id) do
    single_result(:chat_get_message, scope, id, fn uuid ->
      Mount.resource(mount, ChatMessage)
      |> Ash.Query.ensure_selected([:body, :sender_party, :kind, :refs, :participant_id, :thread_id])
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> resolve_pii(mount, ChatMessage, scope)
    end)
  end

  @doc """
  Read a thread's participants for `scope`. `full_name` is NOT resolved here — the identity
  model (`Samen.Web.Chat.Identity`) chooses WHICH plane's actor resolves each participant's
  identity per the stored disclosure state (§5.1). This function returns the raw rows
  (`full_name` still `%Masked{}`); `Samen.Web.Chat.Identity.resolve_participant/4` does the
  plane-choice resolve. The non-PII `handle`/`party` are always present.
  BOUNDED to `#{@detail_limit}` rows (A3 read-bounding).
  """
  def participants(mount, scope, thread_id),
    do: participants_result(mount, scope, thread_id) |> Guard.value([])

  @doc "Tagged sibling of `participants/3` (WP6): `{:ok, rows}` or `{:error, :unavailable | :forbidden}`."
  def participants_result(mount, scope, thread_id) do
    Guard.run(:chat_participants, scope, fn ->
      Mount.resource(mount, ChatParticipant)
      |> Ash.Query.ensure_selected(@participant_fields)
      |> Ash.Query.filter(thread_id == ^thread_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Read a single participant by id for `scope` (raw; identity NOT resolved). `{:ok, p}` or `:error`."
  def get_participant(mount, scope, id) do
    case get_participant_result(mount, scope, id) do
      {:ok, participant} -> {:ok, participant}
      {:error, _} -> :error
    end
  end

  @doc "Tagged sibling of `get_participant/3` (WP6); same contract as `get_thread_result/3`."
  def get_participant_result(mount, scope, id) do
    single_result(:chat_get_participant, scope, id, fn uuid ->
      Mount.resource(mount, ChatParticipant)
      |> Ash.Query.ensure_selected(@participant_fields)
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  Read the org's `ChatDisclosureSetting` (§5 state 3). Returns the row or `nil` if none set
  (the masked floor). Non-PII — a policy flag. BOUNDED to 1 row (A3 read-bounding — the
  caller only ever takes the first row).
  """
  def disclosure_setting(mount, scope), do: disclosure_setting_result(mount, scope) |> Guard.value(nil)

  @doc """
  Tagged sibling of `disclosure_setting/2` (WP6): `{:ok, row | nil}`, or `{:error, :unavailable |
  :forbidden}`. The legacy shim stays on the MASKED floor when the read fails (fail-closed: never
  discloses identity on a guess), but a screen that SHOWS the setting uses this to say so.
  """
  def disclosure_setting_result(mount, scope) do
    Guard.run(:chat_disclosure_setting, scope, fn ->
      Mount.resource(mount, ChatDisclosureSetting)
      |> Ash.Query.ensure_selected([:expose_identity_to_support])
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> List.first()
    end)
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
    e ->
      # Fail-closed (no plaintext downgrade), but not silent: a resolver outage is logged.
      Guard.report(:chat_resolve_pii, scope, e)
      records
  end

  # One record by id: a malformed id is a plain not-found (no read is attempted), an empty
  # result is not-found, a denial is not-found (no existence oracle), and only a FAILED read is
  # `:unavailable`. `read` returns the (<= 1 row) list.
  defp single_result(key, scope, id, read) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, rows} <- Guard.run(key, scope, fn -> read.(uuid) end) do
      case rows do
        [record | _] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
