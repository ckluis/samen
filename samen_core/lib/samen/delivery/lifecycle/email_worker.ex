defmodule Samen.Delivery.Lifecycle.EmailWorker do
  @moduledoc """
  Oban worker for **transactional lifecycle emails** — welcome/onboarding,
  trial-ending, payment-failed/dunning, subscription-cancelled — dispatched
  THROUGH the existing `Samen.Delivery.Provider` boundary (ADR-038 §4.2 rename
  of the ADR-014 `Samen.Delivery.Adapter` contract), **fail-honest** (ADR-014
  §3). This is the transactional-email sibling of
  `Samen.Scopes.Marketing.SendWorker`: same Invariant D1 discipline, same
  env-dependent adapter resolution, same token-only job args — but for
  event-triggered lifecycle mail rather than bulk marketing sends.

  No first-party ESP/SMTP adapter ships here (F1 declined it): the host BYOs the
  adapter per `docs/guides/byo-esp.md`. With no configured adapter in a non-`:test`
  env a lifecycle email is **blocked** (never faked to `:sent`), exactly like a
  blocked marketing send.

  ## Job args convention (token-only — F2.1)

  Job args carry ONLY opaque IDs, tokens, and one bounded event enum — NEVER
  plaintext PII (the row is safe to persist to `oban_jobs`):

    * `send_id`       — opaque lifecycle correlation UUID (minted at enqueue; the
      `Samen.Delivery.Message` canonical identity — there is NO persisted send row,
      lifecycle mail is a stateless enqueue+deliver over existing subscriber refs)
    * `org_id`        — opaque UUID of the owning org (scoping)
    * `subscriber_id` — opaque UUID of the recipient (email is in the vault, not args)
    * `template_id`   — opaque UUID (nilable)
    * `event`         — the bounded lifecycle-event enum (see `events/0`): one of
      `"welcome" | "onboarding" | "trial_ending" | "payment_failed" |
      "payment_recovered" | "subscription_cancelled"`

  Recipient email is revealed from the vault at `deliver/2` time under a grant
  (the BYO adapter's governed read) — never in job args, never in a receipt.

  ## Fail-honest delivery (Invariant D1 carried to the lifecycle path)

  `perform/1` realizes `Samen.Delivery.Provider` with three honest outcomes,
  mirroring the marketing worker:

    1. **No configured adapter, non-`:test` env** → `:blocked` (NOT `:sent`): an
       operator-visible notification (`lifecycle.email.blocked`) is emitted through
       `Samen.Notifications.Engine.emit/1` and `perform/1` returns
       `{:error, :adapter_unconfigured}` so Oban retries/alerts. It NEVER returns
       `:ok`/`:sent`. In `:test` the default adapter is `LocalSink` (honest
       "captured, not delivered"), so tests exercise the happy path with no wiring.
    2. **`adapter.deliver/2 -> {:ok, receipt}`** → `perform/1` returns `:ok` (the
       `:sent` terminal), receipt captured.
    3. **`adapter.deliver/2 -> {:error, reason}`** → `perform/1` returns
       `{:error, reason}` (retriable within `max_attempts`), provably NOT `:sent`.

  **Invariant D1 (lifecycle):** a lifecycle email reaches `:sent` ⟺ a *configured*
  adapter returned `{:ok, _}`. There is NO code path from an unconfigured/failed
  adapter to `:sent`.

  ## Configuration

      config :samen_core, Samen.Delivery.Lifecycle.EmailWorker,
        adapter: MyApp.Delivery.Esp,
        adapter_config: %{api_key: ..., endpoint: ...}

  When `:adapter` is absent the resolution is env-dependent (identical to the
  marketing worker): `:test` falls back to `Samen.Delivery.LocalSink`; any other
  env falls back to `nil` (unconfigured → `:blocked`). The active env is
  `Application.get_env(:samen_core, :delivery_env)` defaulting to the compiled
  `Mix.env()` — release-safe (Mix is not consulted at runtime) and
  test-overridable. As a convenience, if this worker has no `:adapter` configured
  the resolver falls back to the marketing `SendWorker`'s configured adapter — a
  host that wired one delivery adapter gets lifecycle mail through it for free.
  """
  use Oban.Worker,
    queue: :webhooks_out,
    max_attempts: 20,
    unique: [period: 60]

  require Logger

  alias Samen.Delivery.{Chokepoint, Message}

  # Captured at compile time so the runtime never consults Mix (unavailable in
  # releases). Overridable at runtime via :delivery_env for tests / staging.
  @compiled_env Mix.env()

  # The bounded lifecycle-event enum. A job whose `event` is not in this list is
  # malformed and DISCARDED (fail-closed) — never delivered. Kept small and
  # namespaced; a host adds events by extending this list in a framework change,
  # not by smuggling free text through args. `payment_recovered` (T24/B7) is the
  # dunning-recovery counterpart to the pre-existing `payment_failed`.
  @events ~w(welcome onboarding trial_ending payment_failed payment_recovered subscription_cancelled)

  @doc "The bounded set of recognised lifecycle events (string enum)."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Is `event` a recognised lifecycle event? Accepts a string or atom."
  @spec valid_event?(term()) :: boolean()
  def valid_event?(event) when is_binary(event), do: event in @events
  def valid_event?(event) when is_atom(event) and not is_nil(event), do: to_string(event) in @events
  def valid_event?(_), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    event = Map.get(args, "event") || Map.get(args, :event)

    cond do
      not valid_event?(event) ->
        # Fail-closed: an unbounded/absent event can never succeed — discard rather
        # than retry. It does NOT become :sent.
        {:discard, "lifecycle email has no recognised event (token-only args violated)"}

      true ->
        with {:ok, message} <- Message.from_args(args) do
          event = to_string(event)

          case Chokepoint.send(message,
                 fallback_adapter: resolve_adapter(),
                 fallback_config: adapter_config(),
                 env: env()
               ) do
            {:ok, receipt} ->
              log_sent(message, event, receipt)
              :ok

            {:error, :suppressed} ->
              mark_suppressed(message, event)
              {:error, :suppressed}

            {:error, :adapter_unconfigured} = err ->
              mark_blocked(message, event)
              err

            {:error, reason} = err ->
              log_failed(message, event, reason)
              err
          end
        else
          {:error, :missing_send_id} ->
            {:discard, "lifecycle email missing send_id (token-only args violated)"}
        end
    end
  end

  @doc """
  Pure fail-honest decision (ADR-014 §3) — DELEGATES to the single chokepoint
  (`Samen.Delivery.Chokepoint.decide/3`, ADR-038 §4.3/T28) so this is no longer a
  second copy of the logic (`Samen.Scopes.Marketing.SendWorker.decide/3` is the
  same delegate). Kept as a public function (same name/arity) so existing
  callers/tests are unaffected by the T28 chokepoint consolidation.
  """
  @spec decide(module() | nil, map(), atom()) ::
          {:blocked, :adapter_unconfigured} | {:deliver, module(), map()}
  defdelegate decide(adapter, config, env), to: Chokepoint

  # ---------------------------------------------------------------------------
  # Side effects

  defp log_sent(message, event, _receipt) do
    Logger.info(
      "[Lifecycle.EmailWorker] sent event=#{event} send_id=#{message.send_id} " <>
        "org_id=#{message.org_id}"
    )
  end

  defp log_failed(message, event, reason) do
    Logger.warning(
      "[Lifecycle.EmailWorker] delivery FAILED event=#{event} send_id=#{message.send_id} " <>
        "reason=#{inspect(reason)}"
    )
  end

  # Suppressed AT the chokepoint (spec C2) — never reaches the provider. Distinct
  # from :adapter_unconfigured (blocked): the adapter WAS configured, the
  # recipient was refused. Best-effort operator signal, same degrade-to-log
  # posture as mark_blocked/2.
  defp mark_suppressed(message, event) do
    Logger.warning(
      "[Lifecycle.EmailWorker] lifecycle email SUPPRESSED at the delivery chokepoint " <>
        "event=#{event} send_id=#{message.send_id} org_id=#{message.org_id}"
    )

    if is_binary(message.org_id) do
      Samen.Notifications.Engine.emit(%{
        org_id: message.org_id,
        recipient_id: message.org_id,
        event_type: "lifecycle.email.suppressed",
        channel: :in_app,
        rendered_body: "A lifecycle email was refused: recipient is suppressed.",
        metadata: %{"send_id" => to_string(message.send_id), "lifecycle_event" => event}
      })
    end

    :ok
  end

  # Blocked lifecycle email: emit an operator-visible signal (a warning log +
  # a `lifecycle.email.blocked` notification through the engine — best-effort,
  # an unwired engine degrades to the log). NEVER marks the email as sent.
  defp mark_blocked(message, event) do
    Logger.warning(
      "[Lifecycle.EmailWorker] OPERATOR ALERT: lifecycle email BLOCKED (adapter " <>
        "unconfigured) event=#{event} send_id=#{message.send_id} org_id=#{message.org_id}"
    )

    if is_binary(message.org_id) do
      Samen.Notifications.Engine.emit(%{
        org_id: message.org_id,
        recipient_id: message.org_id,
        event_type: "lifecycle.email.blocked",
        channel: :in_app,
        rendered_body: "A lifecycle email was blocked: no delivery adapter is configured.",
        metadata: %{"send_id" => to_string(message.send_id), "lifecycle_event" => event}
      })
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Config resolution (env-dependent — identical shape to the marketing worker).

  @doc false
  def resolve_adapter do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:adapter) || marketing_fallback_adapter()
  end

  # A host that wired exactly one delivery adapter (on the marketing SendWorker)
  # gets lifecycle mail through the same adapter for free. This is a CONFIGURED
  # fallback only — a nil marketing adapter stays nil, so the fail-honest
  # :blocked path is untouched (D1 holds; the sink is never a prod fallback).
  defp marketing_fallback_adapter do
    Application.get_env(:samen_core, Samen.Scopes.Marketing.SendWorker, [])
    |> Keyword.get(:adapter)
  end

  # Public (not private) — `Samen.Delivery.AuthMailer` (T03) reuses this
  # EXACT config resolution so an auth-token email rides the SAME configured
  # adapter a host wired for lifecycle mail, with the SAME marketing-adapter
  # fallback.
  @doc false
  def adapter_config do
    case Application.get_env(:samen_core, __MODULE__, []) |> Keyword.get(:adapter) do
      nil ->
        # Fell back to the marketing adapter → use its config too.
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
end
