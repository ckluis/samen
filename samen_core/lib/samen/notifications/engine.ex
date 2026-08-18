defmodule Samen.Notifications.Engine do
  @moduledoc """
  The kernel notification engine — pure **record + dispatch**, NO UI (ADR-016 §4;
  WS-A design §2.3). Given a notification request, it (1) checks the recipient's
  `NotificationPreference` (a suppressed event type creates NO record — the red
  path), (2) vault-routes the rendered body through the `Notification` resource's
  `pii_attribute` (so the body is a `vt_*` token in the domain column, never
  plaintext), (3) writes the `Notification` record, (4) emits the audit event via
  `Samen.Scopes.Primitives.Audit.notification_sent/3`, and (5) broadcasts an
  **id-only** PubSub envelope so the `samen_web` inbox can re-read per its own
  viewer scope.

  ## Web-dep-free (AC-X-1)

  `samen_core` MUST NOT depend on `phoenix`/`phoenix_pubsub`/`liveview`. The engine
  therefore never calls `Phoenix.PubSub` directly. The realtime broadcast is a
  documented **seam**: a `Samen.Notifications.Broadcaster` behaviour whose
  implementation the host wires via config. The kernel ships
  `Samen.Notifications.LogBroadcaster` (an honest structured log — captured, not
  transported) as the default; `samen_web` (a later A4 unit) wires a broadcaster
  that publishes on `Phoenix.PubSub`. Either way the envelope the engine hands the
  broadcaster carries ONLY the notification id + bounded routing keys — never the
  rendered body (Invariant N1).

  ## Host-wired resource + repo (injectable seams, ADR-014 SendWorker convention)

  Like `Samen.Scopes.Marketing.SendWorker`, the engine resolves the host's
  concrete resource modules + repo from config rather than hardcoding a namespace
  (the kernel is mount-agnostic):

      config :samen_core, Samen.Notifications.Engine,
        notification_module: Demo.PrimitivesScope.Notification,
        preference_module:   Demo.PrimitivesScope.NotificationPreference,
        repo:                Demo.Repo,
        broadcaster:         Samen.Web.Notifications.PubSubBroadcaster

  `notify/1` also accepts these as explicit opts (a test/caller override); opts win
  over config. When no `:notification_module` is reachable the engine fails closed:
  it returns `{:error, :no_notification_module}` rather than silently dropping the
  event (an unrecorded notification is an honest failure, not a fake success).

  ## The id-only envelope (Invariant N1)

  The broadcast envelope is exactly:

      %{id: notification_id, org_id: org_id, recipient_id: recipient_id,
        event_type: event_type, channel: channel}

  All five fields are bounded IDs / enums / labels — safe to transit PubSub. The
  `rendered_body` (vaulted) is DELIBERATELY absent: an operator subscriber listening
  on the topic receives the id only and must re-read the record through its own
  scope, where `PiiResolution` masks per plane. This is why masking survives the
  realtime path by construction (the chat ADR-012 pattern, reused verbatim).

  ## PII discipline (the load-bearing masking rule)

  The `Notification` record stores object REFS (`samen:<key>:<id>`) + non-PII copy
  ONLY. The single free-text channel — `rendered_body` — is vault-routed, so the
  domain row holds a `vt_*` token, never denormalized PII plaintext. A notification
  for a PII-bearing subject therefore contains no vault-token plaintext and no
  vaulted-field copy in any non-vault column (proven by the red-path test).
  """

  require Logger

  alias Samen.Scopes.Primitives.Audit

  @doc """
  Create + dispatch a notification.

  ## Request

    * `:org_id`        — owning org (required; the scoping boundary)
    * `:recipient_id`  — opaque UUID of the notified user/entity (required)
    * `:event_type`    — bounded namespaced label, e.g. `"invoice.created"` (required)
    * `:channel`       — `:in_app` (default) | `:email` | `:sms` | `:push` | `:webhook`
    * `:rendered_body` — free-text body; vault-routed into `Notification.rendered_body`
      (may contain PII — stored encrypted, never plaintext in the domain row)
    * `:subject_ref`   — optional object ref (`"samen:crm.person:<id>"`) stored in
      `metadata["subject_ref"]` (a bounded reference, NOT denormalized subject PII)
    * `:actor_id`      — optional opaque id of the actor causing the notification
      (for the audit row); nilable
    * `:metadata`      — optional bounded map merged into the record's metadata

  ## Options (override config seams)

    * `:notification_module` / `:preference_module` / `:repo` / `:broadcaster`

  ## Returns

    * `{:ok, notification}`       — record written, audited, broadcast
    * `{:ok, :suppressed}`        — the recipient opted out of this event type; NO
      record was written and nothing was dispatched (the preference red path)
    * `{:error, reason}`          — fail-closed (no module wired, or a write error)
  """
  @spec notify(map(), keyword()) ::
          {:ok, struct()} | {:ok, :suppressed} | {:error, term()}
  def notify(request, opts \\ []) when is_map(request) do
    notification_mod = opt(opts, :notification_module)
    preference_mod = opt(opts, :preference_module)
    repo = opt(opts, :repo)
    broadcaster = opt(opts, :broadcaster) || Samen.Notifications.LogBroadcaster

    org_id = fetch(request, :org_id)
    recipient_id = fetch(request, :recipient_id)
    event_type = fetch(request, :event_type)
    channel = Map.get(request, :channel, :in_app)

    cond do
      is_nil(notification_mod) ->
        {:error, :no_notification_module}

      is_nil(org_id) or is_nil(recipient_id) or is_nil(event_type) ->
        {:error, :incomplete_request}

      suppressed?(preference_mod, org_id, recipient_id, event_type, channel) ->
        # RED PATH: a suppressed event type creates NO record — nothing is written,
        # nothing is dispatched, nothing is broadcast. The engine is provably silent.
        {:ok, :suppressed}

      true ->
        create_and_dispatch(
          notification_mod,
          repo,
          broadcaster,
          org_id,
          recipient_id,
          event_type,
          channel,
          request
        )
    end
  end

  @doc """
  Best-effort `notify/1` for kernel/framework EVENT SOURCES (WS-A design §2.3 —
  SLA breach, chat mentions, blocked/failed sends, invoice state changes).

  A source rides ALONGSIDE a primary write (marking a ticket breached, updating a
  send row, transitioning an invoice) — the notification must NEVER abort or roll
  back that primary write. `emit/2` therefore never raises: any engine error is
  logged (an honest signal, not a silent swallow) and returned, but a caller can
  ignore the return safely. An UNWIRED engine (`:no_notification_module` — the
  host hasn't configured `config :samen_core, Samen.Notifications.Engine`) is a
  quiet debug log: sources are inert until the host wires the engine, by design.

  The preference gate applies exactly as in `notify/1`: a suppressed event type
  creates NO record (`{:ok, :suppressed}`) — the per-source red path.
  """
  @spec emit(map(), keyword()) ::
          {:ok, struct()} | {:ok, :suppressed} | {:error, term()}
  def emit(request, opts \\ []) when is_map(request) do
    case notify(request, opts) do
      {:ok, _} = ok ->
        ok

      {:error, :no_notification_module} = error ->
        Logger.debug(
          "[Notifications.Engine] source event #{inspect(Map.get(request, :event_type))} " <>
            "not recorded: engine not wired (config :samen_core, Samen.Notifications.Engine)"
        )

        error

      {:error, reason} = error ->
        Logger.warning(
          "[Notifications.Engine] source event #{inspect(Map.get(request, :event_type))} " <>
            "failed: #{inspect(reason)}"
        )

        error
    end
  rescue
    e ->
      Logger.warning(
        "[Notifications.Engine] source event #{inspect(Map.get(request, :event_type))} " <>
          "raised: #{Exception.message(e)}"
      )

      {:error, e}
  end

  # ---------------------------------------------------------------------------
  # Preference-aware dispatch gate.

  @doc """
  Is dispatch of `event_type` on `channel` suppressed for this recipient?

  Default-ON: with NO preference row the answer is `false` (in-app notifications
  appear unless explicitly opted out). A row with `in_app_enabled: false` suppresses
  the `:in_app` channel; `email_enabled: false` suppresses `:email` (opt-in). A
  missing/unreachable preference module degrades OPEN for in-app (default-on) — the
  suppression gate is an opt-out, not a fail-closed guard on delivery.
  """
  @spec suppressed?(module() | nil, String.t(), String.t(), String.t(), atom()) :: boolean()
  def suppressed?(nil, _org_id, _recipient_id, _event_type, _channel), do: false

  def suppressed?(preference_mod, org_id, recipient_id, event_type, channel) do
    case load_preference(preference_mod, org_id, recipient_id, event_type) do
      nil ->
        # No explicit preference: default-on for in_app, opt-in (suppressed) for email.
        channel == :email

      pref ->
        case channel do
          :email -> not Map.get(pref, :email_enabled, false)
          _ -> not Map.get(pref, :in_app_enabled, true)
        end
    end
  rescue
    # A preference lookup failure must not fake success NOR block in-app delivery;
    # degrade to the default-on in_app posture (opt-in email stays suppressed).
    _ -> channel == :email
  end

  defp load_preference(preference_mod, org_id, recipient_id, event_type) do
    import Ash.Query

    preference_mod
    |> filter(org_id == ^org_id)
    |> filter(recipient_id == ^recipient_id)
    |> filter(event_type == ^event_type)
    |> limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # ---------------------------------------------------------------------------
  # Record + dispatch.

  defp create_and_dispatch(
         notification_mod,
         repo,
         broadcaster,
         org_id,
         recipient_id,
         event_type,
         channel,
         request
       ) do
    status = initial_status(channel)

    attrs =
      %{
        org_id: org_id,
        recipient_id: recipient_id,
        event_type: event_type,
        channel: channel,
        status: status,
        rendered_body: Map.get(request, :rendered_body),
        sent_at: Map.get(request, :sent_at, DateTime.utc_now()),
        metadata: build_metadata(request)
      }
      |> reject_nil()

    result =
      notification_mod
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(authorize?: false)

    case result do
      {:ok, notification} ->
        emit_audit(repo, notification)
        broadcast(broadcaster, envelope(notification, org_id, recipient_id, event_type, channel))
        {:ok, notification}

      {:error, reason} ->
        # Fail-honest: a write failure is returned, never swallowed into a fake ok.
        {:error, reason}
    end
  end

  # In-app notifications are delivered on write (they land in the inbox). Email/other
  # channels start :pending and are handed to Samen.Delivery.Provider downstream.
  defp initial_status(:in_app), do: :delivered
  defp initial_status(_), do: :pending

  # The metadata carries ONLY bounded refs + the caller's bounded map — never the
  # rendered body or any denormalized PII. `subject_ref` is an object ref
  # ("samen:<key>:<id>"), a reference, not subject data.
  defp build_metadata(request) do
    base = Map.get(request, :metadata, %{})
    base = if is_map(base), do: base, else: %{}

    case Map.get(request, :subject_ref) do
      nil -> base
      ref -> Map.put(base, "subject_ref", to_string(ref))
    end
  end

  # ---------------------------------------------------------------------------
  # Audit (rides the aud_event tier via the Primitives writer).

  defp emit_audit(repo, notification) do
    audit_repo = repo || Application.get_env(:samen_core, :verify_repo)

    if audit_repo do
      try do
        Audit.notification_sent(audit_repo, notification, nil)
      rescue
        e ->
          Logger.warning(
            "[Notifications.Engine] audit emit failed for notification " <>
              "#{inspect(Map.get(notification, :id))}: #{Exception.message(e)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Realtime broadcast (id-only envelope; Invariant N1).

  @doc """
  Build the id-only broadcast envelope for a written notification. Carries the
  notification id + bounded routing keys ONLY — never the rendered body. This is the
  exact envelope the broadcaster hands to PubSub; a subscriber re-reads the record
  through its own scope so masking survives the realtime path.
  """
  @spec envelope(struct(), String.t(), String.t(), String.t(), atom()) :: map()
  def envelope(notification, org_id, recipient_id, event_type, channel) do
    %{
      id: Map.get(notification, :id),
      org_id: org_id,
      recipient_id: recipient_id,
      event_type: event_type,
      channel: channel
    }
  end

  defp broadcast(broadcaster, envelope) when is_atom(broadcaster) do
    broadcaster.broadcast(envelope)
  rescue
    e ->
      # A broadcast failure never loses data: the record is already persisted. The
      # inbox re-reads on next mount; realtime just won't deliver this beat.
      Logger.warning(
        "[Notifications.Engine] broadcast failed for notification " <>
          "#{inspect(Map.get(envelope, :id))}: #{Exception.message(e)}"
      )

      :ok
  end

  # ---------------------------------------------------------------------------
  # Config / opt resolution (opts win over config).

  defp opt(opts, key) do
    Keyword.get(opts, key) || Keyword.get(config(), key)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])

  defp fetch(request, key), do: Map.get(request, key) || Map.get(request, to_string(key))

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
