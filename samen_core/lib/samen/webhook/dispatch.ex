defmodule Samen.Webhook.Dispatch do
  @moduledoc """
  The domain-dispatch seam for a verified, persisted webhook envelope (ADR-038 §5.2
  step 5; T19/B9).

  `Samen.Webhook.IngestWorker` calls `dispatch/2` for each `Samen.Webhook.Event`
  after it is stored. The CONSUMERS are out of T19's scope — billing kinds route to
  `Samen.Billing.Reconciler` (T21), delivery kinds to the C4 handler (T30). T19 ships
  ONLY this behaviour + the honest default so the ingress/DLQ machinery is fully
  provable now and the consumers plug in without touching the ingress.

  ## The seam is config-selected

      config :samen_core, :webhook_dispatch, MyApp.WebhookDispatch

  Absent config, `Samen.Webhook.Dispatch.Default` runs: it treats every envelope as
  `:unhandled` and returns `:ok` (an unknown/unwired event is stored replay-safe and
  acknowledged, never crashed — ADR-038 §3.3). It is honest: it does NOT claim to have
  reconciled anything; it simply no-ops the not-yet-wired domains.

  ## Contract

  `dispatch/2` returns:

    * `:ok` — the envelope was handled (or is `:unhandled` by design). The worker marks
      it `:processed`.
    * `{:error, reason}` — a transient failure. The worker retries per Oban policy; on
      the FINAL attempt the envelope is dead-lettered (§5.5).
    * `{:discard, reason}` — a permanent failure. The worker dead-letters immediately.
  """

  alias Samen.Webhook.Event

  @type result :: :ok | {:error, term()} | {:discard, term()}

  @callback dispatch(event :: Event.t(), opts :: keyword()) :: result()

  @doc "The configured dispatch module (default `Samen.Webhook.Dispatch.Default`)."
  @spec module() :: module()
  def module do
    Application.get_env(:samen_core, :webhook_dispatch, Samen.Webhook.Dispatch.Default)
  end

  @doc "Dispatch `event` through the configured module."
  @spec run(Event.t(), keyword()) :: result()
  def run(%Event{} = event, opts \\ []) do
    module().dispatch(event, opts)
  end
end

defmodule Samen.Webhook.Dispatch.Default do
  @moduledoc """
  The honest default webhook dispatch (ADR-038 §5.2/§3.3): every stored envelope is
  acknowledged as `:unhandled` until a real consumer (T21 billing reconciler, T30
  delivery handler) is wired via `:webhook_dispatch` config. It NEVER claims to have
  reconciled a mirror it did not touch.
  """
  @behaviour Samen.Webhook.Dispatch

  @impl true
  def dispatch(_event, _opts), do: :ok
end
