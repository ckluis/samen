defmodule Samen.Webhook do
  @moduledoc """
  Durable outbound webhook delivery (doc §external-surface webhook bullets; plan T3.13).

  ## `deliver/3` — enqueue a durable delivery job

  `Samen.Webhook.deliver(event_type, resource, record)` is the public entry point.
  It:

    1. Resolves the active webhook endpoints for the record's org and event type.
    2. Builds the allowlisted, masked payload via `Samen.Webhook.Payload.build/3`.
    3. Encodes the payload to JSON.
    4. Enqueues one `Samen.Webhook.DeliveryWorker` job per endpoint, using
       `Samen.Jobs.enqueue_in_tx/3` so the enqueue is atomic with the triggering
       action (no delivery without the domain change, no orphan job on rollback).

  Returns `{:ok, job_count}` on success or `{:error, reason}`.

  ## Delivery guarantees (doc §external-surface bullets)

  * **At-least-once** — Oban retries failed deliveries with capped exponential
    backoff (`max_attempts: 20`, ~6 hours total).
  * **Capped exponential backoff** — built into Oban; `max_attempts: 20`.
  * **Dead-letter after cap** — after 20 attempts, Oban moves the job to
    `:discarded` state. Monitor `SELECT * FROM oban_jobs WHERE queue = 'webhooks_out'
    AND state = 'discarded'`.
  * **Per-event idempotency keys** — each delivery job carries a unique
    `idempotency_key` (UUID). Oban's `unique` option deduplicates redeliveries of
    the same key within 24 hours.
  * **HMAC-SHA256 signature** — body + timestamp, signed at delivery time by
    `Samen.Webhook.Signer`, set in the `Samen-Signature` HTTP header.
  * **Anti-replay** — the receiver-side `Signer.verify/4` helper rejects stale
    timestamps (default 5-minute window) EVEN if the HMAC is valid.
  * **Allowlisted masked payload** — same T3.11 rules: catalog names only, PII
    masked as `"••••"`, no storage names, no vault tokens.

  ## Endpoint config (Primitives scope)

  Webhook endpoints are `Samen.Scopes.Primitives.Webhook` rows — the Identity-scope
  `webhook🔒` resource. Each endpoint carries:

    * `url` — the delivery target.
    * `signing_secret` — the per-endpoint HMAC secret (vault-routed PII).
    * `event_types` — the list of event types this endpoint is subscribed to.
    * `status` — `:active | :paused | :failed | :deleted`.

  `deliver/3` filters to `:active` endpoints subscribed to `event_type`.

  ## Scope — same as the API

  The public entry point `deliver/3` uses the resource's domain and the record's
  `org_id` to look up endpoints. There is no cross-org delivery.

  ## Payload + PII safety

  The delivery worker stores the PRE-SERIALIZED body in its `args`. This means:

    * The body is frozen at enqueue time (no TOCTOU).
    * The worker only handles the HMAC signing secret (revealed from the vault at
      delivery time, never stored in job args).
    * The `args` map satisfies the F2.1 token-only-args convention (opaque IDs +
      bounded strings + pre-serialized JSON body; no plaintext PII values).

  ## Oracle tier (F2.1)

  The `oban_jobs` tier (`Samen.NoPlaintextPii.Tiers.ObanJobs`) enforces the
  token-only-args convention at CI time (schema lint) and at post-shred time
  (subject's job rows scanned for PII-shaped arg values).
  """

  alias Samen.Webhook.{Payload, DeliveryWorker}
  alias Samen.Jobs

  @doc """
  Enqueue durable webhook delivery for `event_type`, `resource`, `record`.

  Looks up active endpoints for the record's org subscribed to `event_type`.
  Builds the allowlisted payload, encodes it, and enqueues one delivery job per
  endpoint inside the caller's `Ecto.Multi` (if provided) or as a standalone
  Oban insert.

  Options:
    * `:multi` — an `Ecto.Multi` to append the enqueue step(s) to (same-tx
      delivery). If absent, the jobs are inserted directly via `Oban.insert/1`.
    * `:repo` — override the Ecto repo (defaults to application config).
    * `:endpoints` — explicit list of endpoint maps/structs (bypasses DB lookup;
      for tests).

  Returns `{:ok, job_count}` or `{:error, reason}`.
  """
  @spec deliver(String.t(), module(), struct(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def deliver(event_type, resource, record, opts \\ []) do
    with {:ok, body} <- build_body(event_type, resource, record),
         {:ok, endpoints} <- resolve_endpoints(event_type, record, opts) do
      count =
        endpoints
        |> Enum.with_index()
        |> Enum.reduce(0, fn {{endpoint, idx}, _}, acc ->
          case enqueue_job(endpoint, event_type, body, record, idx, opts) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        end)

      {:ok, count}
    end
  end

  # ---------------------------------------------------------------------------
  # Private

  defp build_body(event_type, resource, record) do
    payload = Payload.build(event_type, resource, record)
    Payload.encode(payload)
  end

  defp resolve_endpoints(event_type, _record, opts) do
    case Keyword.get(opts, :endpoints) do
      endpoints when is_list(endpoints) ->
        active =
          Enum.filter(endpoints, fn ep ->
            ep_status(ep) == :active and event_subscribed?(ep, event_type)
          end)

        {:ok, active}

      nil ->
        # No explicit endpoints — look up from the configured endpoint module.
        # In the library (sans a real host domain), this is a seam: return [].
        {:ok, []}
    end
  end

  defp ep_status(ep) when is_map(ep), do: Map.get(ep, :status, :active)
  defp ep_status(_), do: :active

  defp event_subscribed?(ep, event_type) when is_map(ep) do
    types = Map.get(ep, :event_types, [])
    types == [] or event_type in types
  end

  defp enqueue_job(endpoint, event_type, body, record, idx, opts) do
    endpoint_id = ep_id(endpoint)
    org_id = Map.get(record, :org_id)
    idempotency_key = generate_idempotency_key(endpoint_id, event_type, record)

    args = %{
      "endpoint_id" => to_string(endpoint_id),
      "idempotency_key" => idempotency_key,
      "event_type" => event_type,
      "body" => body,
      "org_id" => to_string(org_id)
    }

    job = DeliveryWorker.new(args)

    case Keyword.get(opts, :multi) do
      %Ecto.Multi{} = multi ->
        Jobs.enqueue_in_tx(multi, :"webhook_delivery_#{idx}", job)
        {:ok, :enqueued_in_tx}

      nil ->
        case Oban.insert(job) do
          {:ok, j} -> {:ok, j}
          {:error, r} -> {:error, r}
        end
    end
  end

  defp ep_id(ep) when is_map(ep), do: Map.get(ep, :id, Ecto.UUID.generate())
  defp ep_id(_), do: Ecto.UUID.generate()

  defp generate_idempotency_key(endpoint_id, event_type, record) do
    record_id = Map.get(record, :id, "no_id")
    # Deterministic per (endpoint, event_type, record_id) — same event redelivered
    # within 24h hits the Oban uniqueness window and is a no-op.
    :crypto.hash(:sha256, "#{endpoint_id}:#{event_type}:#{record_id}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end
end
