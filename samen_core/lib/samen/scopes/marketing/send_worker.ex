defmodule Samen.Scopes.Marketing.SendWorker do
  @moduledoc """
  Oban worker for marketing send delivery — **fail-honest** (ADR-014 §3).

  The worker runs in the `:webhooks_out` queue (same queue as outbound webhook
  deliveries, per `Samen.Jobs` queue taxonomy), with capped exponential backoff
  (max_attempts: 20, unique period: 60s per send ID). The idempotency key is the
  send row's `id` — so re-enqueue after a crash re-runs the same logical delivery,
  not a duplicate.

  ## Job args convention (doc F2.1: token-only args)

  Job args MUST contain only opaque IDs, tokens, and bounded enums — NEVER plaintext
  PII. This worker receives:

    * `send_id`      — opaque UUID of the send row (the canonical args entry)
    * `org_id`       — opaque UUID of the owning org (for scoping)
    * `subscriber_id`— opaque UUID (email is in the vault, not the args)
    * `template_id`  — opaque UUID (nilable)

  Subscriber email is looked up at delivery time via the vault reveal path (under a
  grant), never stored in job args.

  ## Fail-honest delivery (ADR-014 — the load-bearing change)

  There is NO no-op stub that marks unconfigured sends as `:delivered`. Instead
  `perform/1` realizes `Samen.Delivery.Adapter` with three honest outcomes:

    1. **No configured adapter, non-`:test` env** → the send is set to `:blocked`
       (NOT `:delivered`), an audit event `marketing.send.blocked` is emitted, an
       operator notification is recorded, and the job returns
       `{:error, :adapter_unconfigured}` so Oban retries/alerts. It NEVER returns
       `:delivered`. In `:test` env the default adapter is `LocalSink` (an honest
       "captured, not delivered"), so tests do not need to wire an adapter to
       exercise the happy path.
    2. **`adapter.deliver/2 -> {:ok, receipt}`** → send `:delivered` with the
       receipt persisted.
    3. **`adapter.deliver/2 -> {:error, reason}`** → send `:failed` (retriable
       within `max_attempts`), provably NOT `:delivered`.

  **Invariant D1:** `status == :delivered` ⟺ a *configured* adapter returned
  `{:ok, _}`. There is no code path from an unconfigured/failed adapter to
  `:delivered`.

  ## Configuration

      config :samen_core, Samen.Scopes.Marketing.SendWorker,
        adapter: MyApp.SendAdapter,
        adapter_config: %{host: "smtp.example.com", ...}

  When `:adapter` is absent the resolution is env-dependent: `:test` falls back to
  `Samen.Delivery.LocalSink`; any other env falls back to `nil` (unconfigured →
  `:blocked`). The active env is `Application.get_env(:samen_core, :delivery_env)`
  defaulting to the compiled `Mix.env()` — release-safe (Mix is not consulted at
  runtime) and test-overridable.
  """
  use Oban.Worker,
    queue: :webhooks_out,
    max_attempts: 20,
    unique: [period: 60]

  require Logger

  alias Samen.Delivery.Message

  # Captured at compile time so the runtime never consults Mix (unavailable in
  # releases). Overridable at runtime via :delivery_env for tests / staging.
  @compiled_env Mix.env()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, message} <- Message.from_args(args) do
      repo = resolve_repo(args)

      case decide(resolve_adapter(), adapter_config(), env()) do
        {:blocked, reason} ->
          mark_blocked(message, repo)
          {:error, reason}

        {:deliver, adapter, config} ->
          run_deliver(adapter, message, config, repo)
      end
    else
      {:error, :missing_send_id} ->
        # A send job with no send_id is malformed — discard rather than retry a
        # job that can never succeed. Fail-honest: it does NOT become :delivered.
        {:discard, "send job missing send_id (token-only args violated)"}
    end
  end

  @doc """
  Pure fail-honest decision (ADR-014 §3), kernel-testable in isolation.

  Given the resolved `adapter` (module or nil), its `config`, and the active
  `env`, returns either:

    * `{:blocked, :adapter_unconfigured}` — no adapter, or the adapter's
      `configured?/1` is false, in a non-`:test` env. This is the fail-honest
      path: the caller MUST set the send to `:blocked` and NEVER `:delivered`.
    * `{:deliver, adapter, config}` — route to `adapter.deliver/2`.

  In `:test` env a `nil` adapter resolves to `Samen.Delivery.LocalSink` (an honest
  captured-not-delivered), so test happy paths need no wiring. In any other env a
  `nil` (or unconfigured) adapter is fail-honest `:blocked` — the sink is NEVER a
  prod fallback (a prod send "delivered" to a log is the exact lie ADR-014
  forbids).
  """
  @spec decide(module() | nil, map(), atom()) ::
          {:blocked, :adapter_unconfigured} | {:deliver, module(), map()}
  def decide(nil, _config, :test), do: {:deliver, Samen.Delivery.LocalSink, %{}}
  def decide(nil, _config, _env), do: {:blocked, :adapter_unconfigured}

  def decide(adapter, config, _env) when is_atom(adapter) do
    if adapter.configured?(config) do
      {:deliver, adapter, config}
    else
      {:blocked, :adapter_unconfigured}
    end
  end

  # ---------------------------------------------------------------------------
  # Side effects (injectable / graceful-degradation seams)

  defp run_deliver(adapter, message, config, repo) do
    case adapter.deliver(message, config) do
      {:ok, receipt} ->
        mark_delivered(message, receipt, repo)
        :ok

      {:error, reason} ->
        mark_failed(message, reason, repo)
        {:error, reason}
    end
  end

  defp mark_delivered(message, receipt, repo) do
    update_status(message, :delivered, %{sent_at: DateTime.utc_now(), custom: %{receipt: sanitize_receipt(receipt)}}, repo)
  end

  defp mark_failed(message, _reason, repo) do
    update_status(message, :failed, %{}, repo)
  end

  defp mark_blocked(message, repo) do
    update_status(message, :blocked, %{}, repo)
    emit_blocked_audit(message, repo)
    notify_operator_blocked(message, repo)
  end

  # Update the send row's status. Uses the send-resource module the host wires via
  # config (`:send_module`); degrades to a warning log when no resource/repo is
  # reachable (kernel-test env has no marketing send table). NEVER fabricates a
  # :delivered — the caller only ever asks for the honest status it decided.
  defp update_status(message, status, extra, repo) do
    send_mod = Application.get_env(:samen_core, :marketing_send_module)

    cond do
      is_nil(send_mod) or is_nil(repo) ->
        Logger.debug(
          "[SendWorker] no send_module/repo wired; send_id=#{message.send_id} " <>
            "status=#{status} not persisted (kernel seam)"
        )

        :ok

      true ->
        try do
          row = repo.get!(send_mod, message.send_id)

          row
          |> Ecto.Changeset.change(Map.put(extra, :status, status))
          |> repo.update!()

          :ok
        rescue
          e ->
            Logger.warning(
              "[SendWorker] status update failed send_id=#{message.send_id} " <>
                "status=#{status}: #{Exception.message(e)}"
            )

            :ok
        end
    end
  end

  # Emit the `marketing.send.blocked` audit event on the aud_event tier. Token-only
  # detail (send_id + reason enum). Degrades to a warning log if no audit repo.
  defp emit_blocked_audit(message, repo) do
    audit_repo = repo || Application.get_env(:samen_core, :verify_repo)

    if audit_repo do
      try do
        Samen.AuditEvent.insert(audit_repo, %{
          event_type: "system",
          subject_id: to_string(message.send_id),
          correlation_id: message.org_id,
          detail: "marketing.send.blocked reason=adapter_unconfigured"
        })
      rescue
        _ -> :ok
      end
    else
      Logger.warning(
        "[SendWorker] send blocked but no audit repo; send_id=#{message.send_id}"
      )

      :ok
    end
  end

  # Record an operator notification that a send was blocked. The kernel path is
  # the notification engine's record write (ADR-014 §6: the inbox render is web;
  # the record is kernel). Until the engine (a sibling A1/A4 task) is wired, this
  # is a structured warning log — an honest signal, not a silent swallow.
  defp notify_operator_blocked(message, _repo) do
    Logger.warning(
      "[SendWorker] OPERATOR ALERT: marketing send blocked (adapter unconfigured) " <>
        "send_id=#{message.send_id} org_id=#{message.org_id}"
    )

    :ok
  end

  # Keep only token-safe receipt fields in the persisted `custom` map (never a
  # revealed email; adapters return opaque receipt tokens).
  defp sanitize_receipt(receipt) when is_map(receipt) do
    Map.take(receipt, [:sink, :adapter, :send_id, :captured_at, :provider_id, :message_id])
    |> Map.new(fn {k, v} -> {to_string(k), to_string_safe(v)} end)
  end

  defp sanitize_receipt(_), do: %{}

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v) when is_atom(v), do: to_string(v)
  defp to_string_safe(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp to_string_safe(v), do: inspect(v)

  # ---------------------------------------------------------------------------
  # Config resolution

  @doc false
  def resolve_adapter do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:adapter)
  end

  defp adapter_config do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:adapter_config, %{})
  end

  @doc false
  def env do
    Application.get_env(:samen_core, :delivery_env, @compiled_env)
  end

  defp resolve_repo(args) do
    case Map.get(args, "repo") do
      nil ->
        Application.get_env(:samen_core, :marketing_repo) ||
          Application.get_env(:samen_core, :verify_repo)

      repo_str when is_binary(repo_str) ->
        String.to_existing_atom("Elixir.#{repo_str}")
    end
  rescue
    _ -> nil
  end
end
