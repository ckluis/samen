defmodule Samen.Delivery.ProviderConformanceCaseNonVacuityTest do
  @moduledoc """
  Non-vacuity self-test for `Samen.Delivery.ProviderConformanceCase` (T27/C1).

  T94/T95 will cite the harness UNCHANGED and trust it to catch a genuinely
  broken adapter. This proves the harness itself is not a rubber stamp by
  running it against a THROWAWAY adapter (`ToyProvider`, defined here, wholly
  independent of `samen_postmark`) that implements REAL HMAC signature
  verification (reusing `Samen.Webhook.Signer`, the same vendor-generic
  primitive `samen_stripe`'s conformance test already exercises) and REAL
  redaction — so a harness bug (e.g. the tampered-webhook check accepting
  anything) would be caught here even if samen_postmark's own suite happened
  to mask it.
  """

  defmodule ToyProvider do
    use Samen.Delivery.Provider

    alias Samen.Delivery.{InboundMessage, ProviderEvent}
    alias Samen.Webhook.Signer

    @pii_keys ~w(email name)

    @impl true
    def configured?(config) when is_map(config), do: is_binary(Map.get(config, :secret))
    def configured?(_), do: false

    @impl true
    def capabilities, do: [:deliverability_webhooks, :inbound]

    @impl true
    def deliver(message, config) do
      if configured?(config) do
        receipt = %{provider_message_id: "toy-#{message.send_id}", fake: true}

        # When the harness (deliver leak gate, §4.5(f)) injects a capture transport,
        # route a CLEAN, already-resolved request through it (no vt_ token, no PII —
        # the raw token-only message is never forwarded). Without a transport the
        # canned receipt path (used by §4.5(b)) is unchanged.
        case Map.get(config, :transport) do
          fun when is_function(fun, 1) ->
            _ = fun.(%{"To" => "toy-recipient@example.test", "MessageID" => receipt.provider_message_id})
            {:ok, receipt}

          _ ->
            {:ok, receipt}
        end
      else
        {:error, :not_configured}
      end
    end

    @impl true
    def verify_and_parse_event(raw_body, headers, config) do
      if configured?(config) do
        with {:ok, sig} <- find_header(headers),
             {:ok, _ts} <- Signer.verify(raw_body, sig, config.secret, 300),
             {:ok, decoded} <- Jason.decode(raw_body) do
          {:ok,
           %ProviderEvent{
             provider: :toy,
             event_id: decoded["id"],
             kind: String.to_existing_atom(decoded["kind"]),
             provider_message_id: decoded["message_id"],
             occurred_at: parse_occurred_at(decoded["occurred_at"]),
             payload: redact_payload(decoded)
           }}
        else
          {:error, :bad_signature} -> {:error, :invalid_signature}
          {:error, :stale_timestamp} -> {:error, :invalid_signature}
          {:error, :malformed_header} -> {:error, :malformed}
          {:error, _} -> {:error, :malformed}
        end
      else
        {:error, :not_configured}
      end
    end

    @impl true
    def parse_inbound(raw_body, headers, config) do
      if configured?(config) do
        with {:ok, sig} <- find_header(headers),
             {:ok, _ts} <- Signer.verify(raw_body, sig, config.secret, 300),
             {:ok, decoded} <- Jason.decode(raw_body) do
          {:ok,
           %InboundMessage{
             provider: :toy,
             message_id: decoded["message_id"],
             from: decoded["from"],
             subject: decoded["subject"],
             text_body: decoded["text_body"]
           }}
        else
          _ -> {:error, :malformed}
        end
      else
        {:error, :not_configured}
      end
    end

    @impl true
    def redact_payload(payload) when is_map(payload) do
      Map.drop(payload, @pii_keys)
    end

    defp find_header(headers) do
      case Enum.find_value(headers, fn {k, v} -> if k == "toy-signature", do: v end) do
        nil -> {:error, :malformed_header}
        sig -> {:ok, sig}
      end
    end

    defp parse_occurred_at(nil), do: DateTime.utc_now()

    defp parse_occurred_at(iso) do
      case DateTime.from_iso8601(iso) do
        {:ok, dt, _offset} -> dt
        _ -> DateTime.utc_now()
      end
    end
  end

  use Samen.Delivery.ProviderConformanceCase,
    provider: Samen.Delivery.ProviderConformanceCaseNonVacuityTest.ToyProvider,
    fixtures: "test/fixtures/toy_conformance",
    capabilities: [:deliverability_webhooks, :inbound]
end
