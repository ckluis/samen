defmodule Samen.Web.Chat do
  @moduledoc """
  The chat CONTEXT (ADR-012 §6.1) — the framework-level entry points a host LiveView calls to
  drive cross-plane realtime chat + object unfurl. Thin composition over the untouched kernel:
  every write goes through Ash (so `OrgScope` + `RoleAtLeast` + `SameOrgFk` + the vault apply);
  every read goes through `Samen.Web.Chat.Reads` (so PII resolves per plane). This context adds
  NO policy and NO masking of its own.

  ## The send flow (masking BY CONSTRUCTION on the realtime path)

  `post_message/4` is the load-bearing seam:

    1. **Parse object refs on the PLAINTEXT** (`Samen.Web.ObjectRef.parse/1`) BEFORE the body
       is vaulted (§4.2), and store them on `ChatMessage.refs` — so unfurl never re-parses
       ciphertext.
    2. **Persist the message via Ash** — the body is vault-routed on write (clear at rest never
       happens); `OrgScope` + `SameOrgFk` apply.
    3. **Broadcast an ID-ONLY envelope** (`Samen.Web.Chat.PubSub.broadcast_message/3`) — the
       message id, never the resolved body. Each subscriber re-reads per its own plane.

  A plaintext body therefore never transits PubSub; the operator subscriber's re-read resolves
  `••••` (red path 3). The unfurl cards mask per plane on the realtime path for free, because
  the refs re-resolve through `Samen.Web.ObjectRef.resolve_string/3` for the receiving viewer.
  """

  alias Samen.Web.Chat.{PubSub, Reads}
  alias Samen.Web.{Mount, ObjectRef}

  @doc "The `%Samen.Scope{}` for reading a mount's chat resources, on this mount's plane."
  @spec scope(Mount.t(), String.t()) :: Samen.Scope.t()
  def scope(%Mount{} = mount, org_id), do: Mount.scope(mount, org_id)

  @doc """
  Create a chat thread, SNAPSHOTTING the org's disclosure setting into `disclosure_mode` at
  create time (§5 state 3) so flipping the org setting later never retroactively exposes old
  threads. `attrs` carries `subject`, `kind`, optional `context_ref`, and `org_id`. An explicit
  `disclosure_mode` in `attrs` wins (e.g. an initiator choosing `:initiator_opt_in`); otherwise
  the org's `ChatDisclosureSetting.expose_identity_to_support` decides `:tenant_wide` vs
  `:masked`. `{:ok, thread}` or `{:error, reason}`.
  """
  @spec create_thread(Mount.t(), Samen.Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_thread(%Mount{} = mount, scope, attrs) do
    mode = Map.get(attrs, :disclosure_mode) || snapshot_disclosure_mode(mount, scope)
    attrs = Map.put(attrs, :disclosure_mode, mode)

    Mount.resource(mount, ChatThread)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  @doc """
  Add a participant to a thread. `attrs` carries `thread_id`, `party` (`:tenant | :operator`),
  `handle`, optional `full_name`/`principal_kind`/`principal_id`/`identity_shared`/`role`, and
  `org_id`. The write goes through Ash (`OrgScope` + `SameOrgFk`). `{:ok, p}` or `{:error, _}`.
  """
  @spec add_participant(Mount.t(), Samen.Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_participant(%Mount{} = mount, scope, attrs) do
    Mount.resource(mount, ChatParticipant)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  @doc """
  Start a cross-plane conversation FROM the tenant plane (the inbox "New conversation" seam,
  ADR-012 §5/§6.1). Creates a thread — snapshotting the org disclosure mode (`:tenant_wide`
  when the org setting is on) UNLESS the initiator opts in, in which case the thread is stamped
  `:initiator_opt_in` — then adds the initiator as the owning tenant participant, whose
  `identity_shared` carries the per-conversation opt-in (§5 state 2).

  `attrs` carries `org_id`, `subject`, `handle` (the initiator's non-PII label), optional
  `full_name`, and `share_identity` (the opt-in boolean, default `false`). Returns
  `{:ok, thread}` or `{:error, reason}` (the thread create/participant create failing rolls up).

  This is the ONE place the 3-state model's WRITE side lives at framework level: the setting
  drives `:tenant_wide`; the initiator drives `:initiator_opt_in`; absent either, the masked
  floor. No vertical writes a bespoke branch — every host's inbox inherits it.
  """
  @spec start_conversation(Mount.t(), Samen.Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_conversation(%Mount{} = mount, scope, attrs) do
    share? = Map.get(attrs, :share_identity, false)
    org_id = Map.get(attrs, :org_id)

    thread_attrs = %{
      org_id: org_id,
      subject: Map.get(attrs, :subject),
      kind: :cross_plane,
      status: :open
    }

    # The initiator opt-in (state 2) OVERRIDES the org snapshot (state 3): if the initiator
    # chooses to share, the thread is `:initiator_opt_in` (only that participant is disclosed);
    # otherwise the org setting decides `:tenant_wide` vs the masked floor (create_thread snapshots).
    thread_attrs =
      if share?, do: Map.put(thread_attrs, :disclosure_mode, :initiator_opt_in), else: thread_attrs

    with {:ok, thread} <- create_thread(mount, scope, thread_attrs),
         {:ok, _participant} <-
           add_participant(mount, scope, %{
             org_id: org_id,
             thread_id: thread.id,
             party: :tenant,
             principal_kind: :user,
             role: :owner,
             handle: Map.get(attrs, :handle),
             full_name: Map.get(attrs, :full_name),
             identity_shared: share?
           }) do
      {:ok, thread}
    end
  end

  @doc """
  Read the org's identity-disclosure setting (§5 state 3) — `true` when participant identity is
  exposed org-wide to SaaS support, `false` (the masked floor) otherwise. Non-PII policy flag.
  """
  @spec disclosure_setting?(Mount.t(), Samen.Scope.t()) :: boolean()
  def disclosure_setting?(%Mount{} = mount, scope) do
    case Reads.disclosure_setting(mount, scope) do
      %{expose_identity_to_support: value} -> !!value
      _ -> false
    end
  end

  @doc """
  Set the org's tenant-wide identity-disclosure setting (§5 state 3) — the tenant admin's
  ONE-org-level toggle exposing participant identity to SaaS support. Upserts the single per-org
  `ChatDisclosureSetting` row through Ash (admin-gated by the blueprint's `RoleAtLeast :admin`
  policy, org-scoped by `OrgScope`). Snapshotting means flipping this NEVER retroactively
  discloses old threads — only threads created AFTER the flip are stamped `:tenant_wide`.
  `{:ok, setting}` or `{:error, reason}` (a non-admin write is forbidden).
  """
  @spec set_disclosure_setting(Mount.t(), Samen.Scope.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def set_disclosure_setting(%Mount{} = mount, scope, expose?) do
    # This is a tenant-ADMIN org-level policy write. The chat mount's own tenant plane scope is
    # a `:member` (like every tenant chat write); flipping org-wide disclosure requires `:admin`
    # (the blueprint's `RoleAtLeast :admin` on this ONE resource). We build a same-org admin
    # tenant scope for the write — legitimate because it is the tenant setting ITS OWN org's flag,
    # still confined by `OrgScope` to that org. Only reachable on the tenant plane (the LiveView
    # gates the event), never from a masked operator.
    org_id = org_id_of(scope)
    admin_scope = admin_tenant_scope(org_id)
    resource = Mount.resource(mount, ChatDisclosureSetting)

    case Reads.disclosure_setting(mount, admin_scope) do
      %{} = existing ->
        existing
        |> Ash.Changeset.for_update(:update, %{expose_identity_to_support: expose?},
          scope: admin_scope
        )
        |> Ash.update()

      _ ->
        resource
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, expose_identity_to_support: expose?},
          scope: admin_scope
        )
        |> Ash.create()
    end
  end

  # A tenant-plane ADMIN actor over `org_id` — same-org, clear-plane. The tenant flipping its
  # OWN org's disclosure flag (org-scope confines it; the operator can never reach this path).
  defp admin_tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "chat-admin:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp org_id_of(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp org_id_of(%{org_id: org_id}), do: org_id
  defp org_id_of(_), do: nil

  @doc """
  Post a message: parse refs → persist (vault + org-scope) → broadcast id-only. `attrs` carries
  `thread_id`, `participant_id`, `sender_party`, `body`, and `org_id`. Refs are parsed from the
  plaintext `body` and stored on `refs`. Returns `{:ok, message}` (already broadcast) or
  `{:error, reason}` (nothing broadcast). The broadcast is best-effort — a persisted message is
  never lost to a dead PubSub server.
  """
  @spec post_message(Mount.t(), Samen.Scope.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_message(%Mount{} = mount, scope, attrs, opts \\ []) do
    refs = attrs |> Map.get(:body) |> ObjectRef.parse() |> Enum.map(& &1.raw)
    attrs = Map.put(attrs, :refs, refs)

    with {:ok, message} <-
           Mount.resource(mount, ChatMessage)
           |> Ash.Changeset.for_create(:create, attrs, scope: scope)
           |> Ash.create() do
      maybe_broadcast(mount, message, opts)
      {:ok, message}
    end
  end

  @doc """
  The id-only broadcast envelope for a persisted message (ADR-012 §3.1) — the shape a
  subscriber's `handle_info({:chat_message, envelope}, socket)` receives. Carries the message
  ID (never the body), the sender party, the participant id, and the parsed refs.
  """
  @spec envelope(map()) :: map()
  def envelope(message) do
    %{
      thread_id: message.thread_id,
      message_id: message.id,
      sender_party: message.sender_party,
      participant_id: message.participant_id,
      refs: message.refs || []
    }
  end

  @doc """
  Re-read a broadcast message for THIS viewer's scope (the `handle_info` seam, §3.2). Resolves
  the body per the receiving viewer's plane (tenant clear / operator `••••`) AND resolves each
  stored ref into a per-viewer-masked unfurl card. Returns `{:ok, %{message:, cards:}}` or
  `:error`. This is where masking survives the realtime path by construction.
  """
  @spec read_broadcast(Mount.t(), Samen.Scope.t(), map()) ::
          {:ok, %{message: map(), cards: list()}} | :error
  def read_broadcast(%Mount{} = mount, scope, %{message_id: id}) do
    case Reads.get_message(mount, scope, id) do
      {:ok, message} -> {:ok, %{message: message, cards: resolve_cards(mount, scope, message.refs)}}
      :error -> :error
    end
  end

  @doc """
  Resolve a message's stored `refs` into per-viewer-masked unfurl cards (§4). Each ref
  re-resolves through `Samen.Web.ObjectRef.resolve_string/3` for the viewer's scope, so the
  SAME ref renders CLEAR for the tenant and `••••` for the operator. Returns a list of
  `{ref_string, card_or_error}`.
  """
  @spec resolve_cards(Mount.t(), Samen.Scope.t(), [String.t()] | nil) :: [{String.t(), any()}]
  def resolve_cards(_mount, _scope, nil), do: []

  def resolve_cards(%Mount{} = mount, scope, refs) when is_list(refs) do
    Enum.map(refs, fn ref -> {ref, ObjectRef.resolve_string(mount, scope, ref)} end)
  end

  # -- private -----------------------------------------------------------------

  # Snapshot the org's disclosure setting into a thread's disclosure_mode at create.
  defp snapshot_disclosure_mode(mount, scope) do
    case Reads.disclosure_setting(mount, scope) do
      %{expose_identity_to_support: true} -> :tenant_wide
      _ -> :masked
    end
  end

  # Broadcast the id-only envelope unless the caller opted out (`broadcast: false`, e.g. a
  # seed that inserts without a running PubSub).
  defp maybe_broadcast(mount, message, opts) do
    if Keyword.get(opts, :broadcast, true) do
      PubSub.broadcast_message(mount, message.thread_id, envelope(message))
    else
      :ok
    end
  end
end
