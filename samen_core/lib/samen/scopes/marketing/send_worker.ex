defmodule Samen.Scopes.Marketing.SendWorker do
  @moduledoc """
  Oban worker for marketing send delivery (T3.4 spec: "Sends are Oban jobs
  (webhooks_out-style queue conventions)").

  The worker runs in the `:webhooks_out` queue (same queue as outbound webhook
  deliveries, per `Samen.Jobs` queue taxonomy), with capped exponential backoff
  (max_attempts: 20, unique period: 60s per send ID). The idempotency key is the
  send row's `id` — so re-enqueue after a crash re-runs the same logical delivery,
  not a duplicate.

  ## Job args convention (doc F2.1 carry-to-P3: token-only args)

  Job args MUST contain only opaque IDs, tokens, and bounded enums — NEVER plaintext
  PII. This worker receives:

    * `send_id`      — opaque UUID of the send row (the canonical args entry)
    * `org_id`       — opaque UUID of the owning org (for scoping)
    * `subscriber_id`— opaque UUID (for re-checking suppression; email is in the vault,
                        not the args)

  Subscriber email is looked up at delivery time via the vault reveal path (under a
  grant), never stored in job args.

  ## Stub delivery

  The base `perform/1` implementation is a **stub** that marks the send as
  `:delivered`. Host applications replace this by implementing
  `Samen.Scopes.Marketing.SendWorker.Adapter` and configuring:

      config :my_app, Samen.Scopes.Marketing.SendWorker, adapter: MyApp.SendAdapter

  In the demo/test environment the default stub is used.
  """
  use Oban.Worker,
    queue: :webhooks_out,
    max_attempts: 20,
    unique: [period: 60]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    send_id = Map.fetch!(args, "send_id")
    # Delegate to configured adapter or the default stub.
    adapter().deliver(send_id, args)
  end

  # Default no-op adapter (stub for demo/test environments).
  defp adapter do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:adapter, __MODULE__.StubAdapter)
  end

  defmodule StubAdapter do
    @moduledoc """
    Stub adapter that acknowledges delivery without sending a real email.
    Used in demo and test environments.
    """

    def deliver(_send_id, _args) do
      :ok
    end
  end
end
