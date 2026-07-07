defmodule Samen.Webhook.DeliveryWorker do
  @moduledoc """
  Oban worker for durable outbound webhook delivery (doc §external-surface;
  plan T3.13).

  ## At-least-once delivery

  `perform/1` receives the delivery job args and:

    1. Loads the webhook endpoint row (URL + encrypted signing secret).
    2. Reveals the signing secret through the vault chokepoint.
    3. Signs the body (already serialized at enqueue time) via `Samen.Webhook.Signer`.
    4. Posts to the endpoint URL over HTTP.
    5. Returns `:ok` on HTTP 2xx, `{:error, reason}` otherwise (triggers Oban
       retry with capped exponential backoff).

  ## Capped exponential backoff + DLQ

  Uses Oban's built-in backoff schedule: `max_attempts: 20` covers approximately
  6 hours of exponential backoff (base 15s, `2^attempt - 1` seconds). After 20
  attempts Oban moves the job to `:discarded` state — the Samen DLQ bucket.
  Monitor `SELECT * FROM oban_jobs WHERE queue = 'webhooks_out' AND state = 'discarded'`.

  ## Per-event idempotency keys

  The job args include an `idempotency_key` (unique-per-event UUID). The Oban
  `unique` option is set to `[fields: [:args], keys: [:idempotency_key], period: 86_400]`
  (24-hour window). Redelivery of the same event (same idempotency_key) within 24
  hours is a no-op (`:ok` from the conflicting insert, job not enqueued again).

  > Note: Oban (2.23) requires `:keys` to be a list of ATOMS — `keys: [:idempotency_key]`.
  > The atom keys are matched against the JSON-encoded args at enqueue time. (The
  > Gate-3 housekeeping note suggested a string form, but Oban rejects strings at
  > compile time, so the atom form is authoritative — the moduledoc now matches it.)

  ## Payload allowlist

  The payload is serialized to JSON at enqueue time by `Samen.Webhook.Payload.build/3`
  + `Payload.encode/1`. The serialized body is stored in the job args as `"body"`.
  The delivery worker NEVER re-fetches the record — it delivers the already-allowlisted
  body verbatim. This ensures:

    * The payload is frozen at delivery-time (no TOCTOU between enqueue and delivery).
    * The delivery worker has NO access to PII beyond the already-masked `"••••"` strings
      in the pre-serialized body.
    * The signing secret is the ONLY PII the worker handles — and it handles it ONLY in
      memory, never logging it.

  ## Job args shape

  The job args are opaque-ID/token/enum/number — the F2.1 token-only-args convention:

      %{
        "endpoint_id"      => "uuid-of-webhook-row",    # opaque ID
        "idempotency_key"  => "uuid-per-event",          # opaque ID
        "event_type"       => "invoice.created",         # enum / bounded string
        "body"             => "{\"event\":\"invoice.created\",...}",  # pre-serialized JSON
        "org_id"           => "uuid-of-org"              # opaque ID (scoping)
      }

  The `body` field is an opaque pre-serialized JSON string — it carries the masked
  payload but NOT the signing secret, NOT decrypted PII, and NOT any storage name.
  This satisfies the token-only-args invariant: the args hold references and bounded
  data, never plaintext PII values.

  ## HTTP adapter injection

  The HTTP client is injected via `:http_adapter` in job args (for tests) or via
  `Application.get_env(:samen_core, :webhook_http_adapter)`. The default is
  `Samen.Webhook.HttpAdapter.Httpc` (uses Erlang's built-in `httpc`).
  """

  use Oban.Worker,
    queue: :webhooks_out,
    max_attempts: 20,
    unique: [fields: [:args], keys: [:idempotency_key], period: 86_400]

  alias Samen.Webhook.Signer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    endpoint_id = Map.fetch!(args, "endpoint_id")
    body = Map.fetch!(args, "body")
    repo = resolve_repo(args)

    with {:ok, endpoint} <- load_endpoint(endpoint_id, repo),
         {:ok, secret} <- reveal_secret(endpoint, repo),
         {:ok, url} <- endpoint_url(endpoint),
         {:ok, _} <- deliver(url, body, secret) do
      :ok
    else
      {:error, :shredded} ->
        # The endpoint's org has been shredded — the secret is gone. Discard.
        {:discard, "signing secret shredded (org erasure)"}

      {:error, :not_found} ->
        # Endpoint row deleted between enqueue and delivery. Discard.
        {:discard, "webhook endpoint not found: #{endpoint_id}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private

  defp load_endpoint(id, repo) when is_binary(id) and not is_nil(repo) do
    case repo.get_by(oban_webhook_endpoint_table(), [id: id]) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    _ ->
      # No real Ash resource wired — this is the seam for host apps.
      {:error, :not_found}
  end

  defp load_endpoint(_id, nil) do
    # No repo configured — fail closed.
    {:error, :no_repo}
  end

  # Try to use the configured vault + repo to reveal the signing secret.
  defp reveal_secret(endpoint, repo) do
    vault = Application.get_env(:samen_core, :vault_module, Samen.Vault)

    case Map.get(endpoint, :signing_secret) do
      %Samen.Masked{} = masked ->
        vault.reveal(masked, repo, [])

      nil ->
        {:error, :no_secret}

      secret when is_binary(secret) ->
        # Already plaintext (e.g. in-memory test stub).
        {:ok, secret}
    end
  end

  defp endpoint_url(endpoint) do
    case Map.get(endpoint, :url) do
      nil -> {:error, :no_url}
      url -> {:ok, url}
    end
  end

  defp deliver(url, body, secret) do
    timestamp = System.os_time(:second)
    signature = Signer.sign(body, timestamp, secret)

    adapter = delivery_adapter()
    adapter.post(url, body, [
      {"Content-Type", "application/json"},
      {"Samen-Signature", signature}
    ])
  end

  defp delivery_adapter do
    Application.get_env(:samen_core, :webhook_http_adapter, Samen.Webhook.HttpAdapter.Httpc)
  end

  defp resolve_repo(args) do
    case Map.get(args, "repo") do
      nil -> Application.get_env(:samen_core, :webhook_repo) ||
               Application.get_env(:samen_core, :verify_repo)
      repo_str when is_binary(repo_str) ->
        String.to_existing_atom("Elixir.#{repo_str}")
    end
  rescue
    _ -> nil
  end

  # Hook for the host app — returns the table module for webhook endpoint rows.
  # Overridden via `:webhook_endpoint_module` in app config.
  defp oban_webhook_endpoint_table do
    Application.get_env(:samen_core, :webhook_endpoint_module, __MODULE__)
  end
end
