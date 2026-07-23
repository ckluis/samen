defmodule Samen.Web.Webhook.Ingress do
  @moduledoc """
  The SHARED webhook ingress endpoint (ADR-038 §5; T19/B9) — one ingress, two domains
  (billing + delivery). `POST /webhooks/:provider`. Vendor-generic by construction: the
  provider module + config are resolved from HOST config at runtime, so `samen_web`
  (like `samen_core`) compiles with ZERO vendor deps (INV-4). All per-vendor knowledge
  (signature scheme, event-name mapping, PII redaction) lives behind the adapter's
  `verify_and_parse_event/3` + `redact_payload/1`.

  ## Request lifecycle (ADR-038 §5.2 — BINDING order)

    1. **Resolve provider** from host config; unknown ⇒ 404 (fail-closed, counter only).
    2. **Rate-limit** the per-provider flood guard (§6.3) — cheap, before any crypto.
    3. **Oversize guard** — a body over `:max_body_bytes` ⇒ 413 before verify (bounds
       oversized-payload DoS / DLQ poisoning).
    4. **Pre-crypto bad-signature gate** — an IP already over the invalid-signature
       budget (§6.3) ⇒ 429 before the HMAC work.
    5. **Verify + parse** via the adapter: bad signature / stale timestamp / malformed ⇒
       **400, NOTHING persisted** (the invalid-signature counter is bumped on failure).
    6. **Persist** the envelope (`Samen.Webhook.Event`) with the ALREADY-REDACTED payload
       (§5.4). A duplicate `{provider, event_id}` ⇒ 200 no-op (replay protection; the DB
       unique index is the arbiter, safe under concurrent duplicate delivery).
    7. **Enqueue** the processing worker (`:webhooks_in`) with TOKEN-ONLY args (the row
       id) and return 200 immediately (fast ack; slow work never runs in the request).

  ## Configuration (host)

      config :samen_web, Samen.Web.Webhook,
        repo: MyApp.Repo,
        providers: %{"stripe" => {SamenStripe.Provider, %{webhook_secret: "whsec_..."}}},
        max_body_bytes: 1_048_576

  Wire the raw-body parser (`Samen.Web.Webhook.RawBodyReader`) into the endpoint so the
  exact signed bytes survive `Plug.Parsers` (see that module).

  Pure ingress LOGIC — `ingest/2` takes and returns a conn. The `samen_webhook_routes`
  macro routes `POST /webhooks/:provider` to `Samen.Web.Webhook.IngressController`,
  which delegates here (the BytesController seam pattern).
  """

  import Plug.Conn

  alias Samen.Web.RateLimit
  alias Samen.Web.Webhook.RawBodyReader
  alias Samen.Webhook.{Event, IngestWorker}

  @default_max_body_bytes 1_048_576

  @doc """
  Run the ingress lifecycle for `conn`. `opts` may override host config
  (`:repo`, `:providers`, `:max_body_bytes`) — used by tests; production reads config.
  Returns the conn with the response already sent + halted.
  """
  @spec ingest(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def ingest(conn, opts \\ []) do
    provider = conn.params["provider"] || conn.path_params["provider"]

    case resolve_provider(provider, opts) do
      nil ->
        # Unknown provider — fail-closed, nothing processed, nothing logged beyond a 404.
        respond(conn, 404, "unknown_provider")

      {module, provider_config} ->
        with :ok <- flood_guard(provider),
             :ok <- oversize_guard(conn, opts),
             :ok <- bad_sig_gate(conn) do
          verify_and_store(conn, provider, module, provider_config, opts)
        else
          {:error, :rate_limited} -> respond(conn, 429, "rate_limited")
          {:error, :too_large} -> respond(conn, 413, "payload_too_large")
        end
    end
  end

  # ---------------------------------------------------------------------------

  defp flood_guard(provider) do
    RateLimit.check(:webhook_ingress, :provider, provider)
  end

  defp oversize_guard(conn, opts) do
    max = opt(opts, :max_body_bytes) || configured(:max_body_bytes) || @default_max_body_bytes

    if byte_size(RawBodyReader.raw_body(conn)) > max do
      {:error, :too_large}
    else
      :ok
    end
  end

  # Pre-crypto: if this IP is already over the invalid-signature budget, 429 before HMAC.
  defp bad_sig_gate(conn) do
    if RateLimit.over_limit?(:webhook_bad_sig, :ip, remote_ip(conn)) do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp verify_and_store(conn, provider, module, provider_config, opts) do
    raw = RawBodyReader.raw_body(conn)

    case module.verify_and_parse_event(raw, conn.req_headers, provider_config) do
      {:ok, event} ->
        store(conn, provider, event, opts)

      {:error, _reason} ->
        # Bad signature / stale timestamp / malformed ⇒ 400, NOTHING persisted.
        # Count the failure against this IP's forgery-DoS budget (§6.3).
        RateLimit.record_failure(:webhook_bad_sig, :ip, remote_ip(conn))
        respond(conn, 400, "invalid_signature")
    end
  end

  defp store(conn, provider, event, opts) do
    repo = opt(opts, :repo) || configured(:repo)

    attrs = %{
      provider: provider,
      event_id: to_string(event.event_id),
      kind: to_string(event.kind),
      domain: domain_of(event),
      occurred_at: event.occurred_at,
      # payload is ALREADY redacted by the adapter (§5.4) — never re-derive PII from it.
      payload: event.payload || %{}
    }

    case Event.insert_received(repo, attrs) do
      {:ok, :duplicate, _existing} ->
        # Replay: the {provider, event_id} unique index rejected the second delivery.
        respond(conn, 200, "duplicate")

      {:ok, :inserted, row} ->
        enqueue(row, repo)
        respond(conn, 200, "ok")

      {:error, _changeset} ->
        # A malformed envelope that passed verification but cannot be stored — surface a
        # 422 so the provider retries; nothing half-processed.
        respond(conn, 422, "unprocessable")
    end
  end

  defp enqueue(row, repo) do
    IngestWorker.enqueue(row, repo: repo)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Domain from the normalized event struct — match by module split so we do NOT
  # compile-depend on Samen.Delivery.ProviderEvent (a later WS-C resource).
  defp domain_of(%{__struct__: mod}) do
    case Module.split(mod) do
      ["Samen", "Billing", "ProviderEvent"] -> "billing"
      ["Samen", "Delivery", "ProviderEvent"] -> "delivery"
      _ -> "unknown"
    end
  end

  defp domain_of(_), do: "unknown"

  defp resolve_provider(nil, _opts), do: nil

  defp resolve_provider(provider, opts) do
    providers = opt(opts, :providers) || configured(:providers) || %{}

    case Map.get(providers, provider) do
      {module, config} -> {module, config}
      module when is_atom(module) and not is_nil(module) -> {module, %{}}
      _ -> nil
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp remote_ip(_), do: "unknown"

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  defp opt(opts, key), do: Keyword.get(opts, key)

  defp configured(key) do
    Application.get_env(:samen_web, Samen.Web.Webhook, [])
    |> Keyword.get(key)
  end
end
