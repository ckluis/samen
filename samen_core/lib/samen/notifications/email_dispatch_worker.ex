defmodule Samen.Notifications.EmailDispatchWorker do
  @moduledoc """
  Oban worker that dispatches a SINGLE `:email`-channel `Notification` row through
  the fail-honest `Samen.Delivery.Chokepoint` (ADR-038 §4.2/§4.3; C2, T28).

  `Samen.Notifications.Engine.notify/1` already writes `:email`-channel
  notifications as `:pending` ("handed to `Samen.Delivery.Provider` downstream" —
  its own moduledoc's words); this worker IS that downstream. It is the transport
  two of the C2 send families ride:

    * **Notification digests** (spec C8 names the SCHEDULING/batching of these —
      out of T28 scope by design) — a digest job aggregates unread notifications
      into ONE rendered `Notification` row and enqueues this worker to send it.
      T28 ships the send mechanism; T30 owns deciding WHEN/WHAT to batch. This
      worker deliberately sends exactly the one notification it is given — it
      does NOT batch, so it cannot pre-empt or conflict with T30's real digest
      cadence logic.
    * **Ticket replies** — a future support-scope hook creates an `:email`-channel
      `Notification` for a ticket reply (`event_type: "support.ticket_reply"`) and
      enqueues this worker exactly like any other notification email. The
      hook itself (Support.Message → Notification) is NOT built here (named GAP,
      see the T28 summary) — this worker is the transport it will use.

  ## Job args (token-only, F2.1 — mirrors `Samen.Scopes.Marketing.SendWorker`)

    * `send_id`       — the `Notification` row's own id (the correlation id AND
      the row to update on completion — there is no separate send table here)
    * `org_id`        — owning org UUID
    * `subscriber_id` — the notification's `recipient_id` (email is revealed
      downstream by the adapter under a grant — never in these args, C3/T29 owns
      the actual PII-safe rendering path; this worker only carries token refs)
    * `template_id`   — optional; carries the notification's `event_type` when a
      caller wants the adapter to select a template by it

  ## Fail-honest + suppression (identical contract to every other C2 consumer)

  Routes through `Samen.Delivery.Chokepoint.send/2` — same `:blocked`/`:suppressed`
  fail-honest semantics as `SendWorker`/`EmailWorker`/`AuthMailer`. A `:pending`
  notification NEVER silently becomes `:sent` without a configured, unsuppressed
  provider genuinely returning `{:ok, _}`.

  ## Configuration

  Reuses `Samen.Notifications.Engine`'s `notification_module`/`repo` config (no
  second place to wire the same resource):

      config :samen_core, Samen.Notifications.Engine,
        notification_module: MyApp.Primitives.Notification,
        repo: MyApp.Repo

      # optional: this worker's OWN adapter (falls back to the marketing
      # SendWorker's configured adapter, exactly like Lifecycle.EmailWorker):
      config :samen_core, Samen.Notifications.EmailDispatchWorker,
        adapter: MyApp.Delivery.Esp,
        adapter_config: %{...}

  When no `notification_module`/`repo` is reachable, status updates degrade to a
  debug log (the SAME graceful-degradation posture `SendWorker.update_status/4`
  uses for its kernel-test env) — the SEND outcome (the function's return value)
  is still honest either way; only the persisted status update is best-effort.
  """
  use Oban.Worker,
    queue: :webhooks_out,
    max_attempts: 20,
    unique: [period: 60]

  require Logger

  alias Samen.Delivery.{Chokepoint, Message}

  @compiled_env Mix.env()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, message} <- Message.from_args(args) do
      case Chokepoint.send(message,
             fallback_adapter: resolve_adapter(),
             fallback_config: adapter_config(),
             env: env()
           ) do
        {:ok, receipt} ->
          mark_sent(message, receipt)
          :ok

        {:error, :suppressed} = err ->
          mark_status(message, :failed)
          Logger.warning(
            "[Notifications.EmailDispatchWorker] SUPPRESSED at the delivery chokepoint " <>
              "send_id=#{message.send_id} org_id=#{message.org_id}"
          )

          err

        {:error, :adapter_unconfigured} = err ->
          Logger.warning(
            "[Notifications.EmailDispatchWorker] OPERATOR ALERT: BLOCKED (adapter " <>
              "unconfigured) send_id=#{message.send_id} org_id=#{message.org_id}"
          )

          err

        {:error, reason} = err ->
          mark_status(message, :failed)

          Logger.warning(
            "[Notifications.EmailDispatchWorker] delivery FAILED send_id=#{message.send_id} " <>
              "reason=#{inspect(reason)}"
          )

          err
      end
    else
      {:error, :missing_send_id} ->
        {:discard, "notification email job missing send_id (token-only args violated)"}
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence (best-effort; degrades to a log when unwired — SendWorker parity).

  defp mark_sent(message, receipt) do
    extra = %{status: :sent, sent_at: DateTime.utc_now()}

    extra =
      case Map.get(receipt, :provider_message_id) do
        nil -> extra
        id -> Map.put(extra, :metadata, %{"provider_message_id" => to_string(id)})
      end

    update_notification(message, extra)
  end

  defp mark_status(message, status), do: update_notification(message, %{status: status})

  defp update_notification(message, extra) do
    notification_mod = notification_module()
    repo = notification_repo()

    cond do
      is_nil(notification_mod) or is_nil(repo) ->
        Logger.debug(
          "[Notifications.EmailDispatchWorker] no notification_module/repo wired; " <>
            "send_id=#{message.send_id} not persisted (kernel seam)"
        )

        :ok

      true ->
        try do
          row = repo.get!(notification_mod, message.send_id)

          merged_extra =
            case Map.get(extra, :metadata) do
              nil -> Map.delete(extra, :metadata)
              meta -> Map.put(extra, :metadata, Map.merge(row.metadata || %{}, meta))
            end

          row
          |> Ecto.Changeset.change(merged_extra)
          |> repo.update!()

          :ok
        rescue
          e ->
            Logger.warning(
              "[Notifications.EmailDispatchWorker] status update failed " <>
                "send_id=#{message.send_id}: #{Exception.message(e)}"
            )

            :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Config resolution (mirrors Lifecycle.EmailWorker's marketing-adapter fallback).

  @doc false
  def resolve_adapter do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:adapter) || marketing_fallback_adapter()
  end

  defp marketing_fallback_adapter do
    Application.get_env(:samen_core, Samen.Scopes.Marketing.SendWorker, [])
    |> Keyword.get(:adapter)
  end

  @doc false
  def adapter_config do
    case Application.get_env(:samen_core, __MODULE__, []) |> Keyword.get(:adapter) do
      nil ->
        Application.get_env(:samen_core, Samen.Scopes.Marketing.SendWorker, [])
        |> Keyword.get(:adapter_config, %{})

      _own ->
        Application.get_env(:samen_core, __MODULE__, [])
        |> Keyword.get(:adapter_config, %{})
    end
  end

  @doc false
  def env do
    Application.get_env(:samen_core, :delivery_env, @compiled_env)
  end

  defp notification_module do
    Application.get_env(:samen_core, Samen.Notifications.Engine, [])
    |> Keyword.get(:notification_module)
  end

  defp notification_repo do
    Application.get_env(:samen_core, Samen.Notifications.Engine, [])
    |> Keyword.get(:repo)
  end
end
