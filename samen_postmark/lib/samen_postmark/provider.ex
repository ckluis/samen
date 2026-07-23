defmodule SamenPostmark.Provider do
  @moduledoc """
  Postmark implementation of `Samen.Delivery.Provider` (ADR-038 §4; T27/C1) —
  the REFERENCE, inbound-capable adapter (serves C5/T59 later).

  ## Fail-honest layering (mirrors the `samen_stripe` T18 precedent)

  Every callback is gated: unconfigured (`config[:server_token]`/`config[:from]`
  absent) -> `{:error, :not_configured}`; configured but missing the
  CAPABILITY-SPECIFIC creds/glue it needs -> `{:error, :not_implemented}` (the
  honest "not wired yet", never a fake accept); else the real implementation runs.

  ## `deliver/2` — real HTTP mechanics, honest recipient-resolution gap

  `Samen.Delivery.Message` is token-only by design (ADR-014) — it carries NO
  recipient email. Resolving `to_subscriber_id -> plaintext email` requires a
  vault reveal under a grant that only the HOST (which owns the concrete
  subscriber schema) can perform; no generic ESP adapter package can do this
  itself. So `deliver/2` accepts an injectable `config[:resolve_recipient]`
  (an arity-1 function `message -> {:ok, email} | {:error, reason}`) — ABSENT
  in any real host wiring today, so `deliver/2` is honestly
  `{:error, :not_implemented}` in production until an operator wires it
  (exactly like `Samen.Delivery.Smtp`/`Samen.Delivery.Api`'s standing "operator
  TODO"). The conformance/fixture harness supplies `:resolve_recipient` (and
  `:transport`, §7.2) to prove the REST of the pipeline — request building,
  the real Postmark HTTP call shape, response parsing, receipt shape — works,
  without claiming production wiring that does not exist yet.

  `verify_and_parse_event/3` and `parse_inbound/3` need NO such host glue (the
  vendor payload IS the input) and are FULLY implemented: Postmark's real
  webhook/inbound security model is HTTP Basic Auth on the webhook URL (NOT an
  HMAC body signature — Postmark does not sign webhook bodies), so
  "invalid_signature" here means "the Authorization header does not match the
  configured Basic Auth credentials."
  """

  use Samen.Delivery.Provider

  alias Samen.Delivery.{InboundMessage, Message, ProviderEvent}
  alias SamenPostmark.Transport

  # Postmark `RecordType` -> the bounded, samen-owned ProviderEvent kind enum
  # (ADR-038 §3.3/§4.4). Anything not listed maps to :unhandled (stored
  # replay-safe, not dispatched).
  @kind_map %{
    "Delivery" => :delivered,
    "Bounce" => :bounce,
    "SpamComplaint" => :complaint,
    "Open" => :open,
    "Click" => :click
  }

  # ALLOWLIST redaction (T30 hardening, routed from the T24 verifier via the
  # ADR-038 handoff scope addendum; ADR-038 §5.4 / INV-1). The ORIGINAL
  # implementation here was a DENYLIST of ~9 known-PII key names (`Recipient
  # Email From FromFull FromName To ToFull Cc CcFull ReplyTo`) — it caught
  # those exact keys wherever they appeared (including nested), but MISSES by
  # construction the moment PII lands under any OTHER, unenumerated key.
  # Postmark webhooks carry a free-form `Metadata` bag (custom key/value data
  # an org attaches to an outbound message, echoed back on bounce/complaint/
  # delivery events) — exactly the same free-form-PII-container shape as
  # Stripe's `metadata` (T24, `samen_stripe/lib/samen_stripe/provider.ex`),
  # and the same gap: a denylist can only enumerate keys someone thought of in
  # advance.
  #
  # The allowlist inverts the failure mode: a top-level field survives ONLY IF
  # (a) its name is on `@safe_keys` AND (b) its value is a plain SCALAR — an
  # allowlisted key whose value is a map/list is ALSO dropped, never assumed
  # safe merely because the key name is safe. `Metadata` — and every other
  # nested map/list (`Headers`, `Attachments`, …) — is dropped WHOLESALE,
  # never selectively descended into.
  @safe_keys ~w(
    RecordType ID Type TypeCode Name Tag MessageID ServerID Description
    Details BouncedAt DeliveredAt ReceivedAt SentAt Inactive CanActivate
    DumpAvailable
  )

  @impl true
  def configured?(config) when is_map(config) do
    present?(config, :server_token) and present?(config, :from)
  end

  def configured?(_), do: false

  @impl true
  def capabilities, do: [:deliverability_webhooks, :inbound, :tracking]

  @impl true
  def deliver(%Message{} = message, config) do
    cond do
      not configured?(config) ->
        {:error, :not_configured}

      not is_function(Map.get(config, :resolve_recipient), 1) ->
        {:error, :not_implemented}

      true ->
        case config.resolve_recipient.(message) do
          {:ok, to_email} when is_binary(to_email) -> do_deliver(message, to_email, config)
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_resolve_recipient_result, other}}
        end
    end
  end

  @impl true
  def verify_and_parse_event(raw_body, headers, config)
      when is_binary(raw_body) and is_list(headers) do
    cond do
      not configured?(config) ->
        {:error, :not_configured}

      not (present?(config, :webhook_username) and present?(config, :webhook_password)) ->
        {:error, :not_implemented}

      true ->
        case check_basic_auth(headers, config.webhook_username, config.webhook_password) do
          :ok -> parse_event(raw_body)
          :error -> {:error, :invalid_signature}
        end
    end
  end

  def verify_and_parse_event(_raw_body, _headers, config) do
    if configured?(config), do: {:error, :malformed}, else: {:error, :not_configured}
  end

  @impl true
  def parse_inbound(raw_body, headers, config) when is_binary(raw_body) and is_list(headers) do
    cond do
      not configured?(config) ->
        {:error, :not_configured}

      not (present?(config, :inbound_username) and present?(config, :inbound_password)) ->
        {:error, :not_implemented}

      true ->
        case check_basic_auth(headers, config.inbound_username, config.inbound_password) do
          :ok -> parse_inbound_body(raw_body)
          :error -> {:error, :invalid_signature}
        end
    end
  end

  def parse_inbound(_raw_body, _headers, config) do
    if configured?(config), do: {:error, :malformed}, else: {:error, :not_configured}
  end

  @impl true
  def redact_payload(payload) when is_map(payload) do
    payload
    |> Enum.filter(fn {k, v} -> allowed_key?(k) and scalar?(v) end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # deliver/2

  defp do_deliver(message, to_email, config) do
    transport = Map.get(config, :transport, &Transport.live/1)
    body = build_request_body(message, to_email, config)
    request = %{server_token: Map.fetch!(config, :server_token), body: body}

    transport.(request) |> handle_response()
  end

  defp build_request_body(message, to_email, config) do
    %{
      "From" => Map.fetch!(config, :from),
      "To" => to_email,
      "Subject" => Map.get(config, :subject, "(rendering pending — template #{message.template_id || "none"})"),
      "TextBody" => Map.get(config, :text_body, "(rendering pending — ADR-038 C3/T29)"),
      "MessageStream" => Map.get(config, :message_stream, "outbound")
    }
  end

  defp handle_response({:ok, %{status: 200, body: %{"ErrorCode" => 0, "MessageID" => id}}})
       when is_binary(id) do
    {:ok, %{provider_message_id: id}}
  end

  defp handle_response({:ok, %{status: status, body: %{"ErrorCode" => code, "Message" => msg}}}) do
    {:error, {:postmark_error, status, code, msg}}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:unexpected_response, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3

  defp parse_event(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"RecordType" => record_type} = body} ->
        {:ok,
         %ProviderEvent{
           provider: :postmark,
           event_id: event_id(body, raw_body),
           kind: Map.get(@kind_map, record_type, :unhandled),
           provider_message_id: body["MessageID"],
           occurred_at: parse_occurred_at(body),
           payload: redact_payload(body)
         }}

      _ ->
        {:error, :malformed}
    end
  end

  # Postmark provides a stable `ID` for Bounce/SpamComplaint events but NOT for
  # Delivery/Open/Click (no vendor-native unique id there) — fall back to a
  # content hash so replay-dedup (`{provider, event_id}`, §5.3) still works: a
  # duplicate delivery of the exact same body hashes to the same id.
  defp event_id(%{"ID" => id}, _raw_body) when not is_nil(id), do: to_string(id)

  defp event_id(_body, raw_body) do
    :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp parse_occurred_at(body) do
    ts = body["DeliveredAt"] || body["BouncedAt"] || body["ReceivedAt"]

    case ts && DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # ---------------------------------------------------------------------------
  # parse_inbound/3

  defp parse_inbound_body(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, body} ->
        {:ok,
         %InboundMessage{
           provider: :postmark,
           message_id: body["MessageID"] || content_hash(raw_body),
           from: body["From"],
           from_name: body["FromName"],
           to: to_list(body["To"]),
           subject: body["Subject"],
           text_body: body["TextBody"],
           html_body: body["HtmlBody"],
           headers: headers_to_map(body["Headers"]),
           attachments: body["Attachments"] || []
         }}

      _ ->
        {:error, :malformed}
    end
  end

  defp content_hash(raw_body), do: :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

  defp to_list(nil), do: nil
  defp to_list(str) when is_binary(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  defp headers_to_map(list) when is_list(list) do
    Map.new(list, fn %{"Name" => name, "Value" => value} -> {name, value} end)
  end

  defp headers_to_map(_), do: %{}

  # ---------------------------------------------------------------------------
  # Shared helpers

  # Real Postmark webhook/inbound security is HTTP Basic Auth on the URL, not
  # a per-request HMAC signature — this checks the `Authorization` header
  # against the configured credentials with a constant-time comparison.
  defp check_basic_auth(headers, username, password) do
    expected = "Basic " <> Base.encode64("#{username}:#{password}")

    case find_header(headers, "authorization") do
      nil -> :error
      actual -> if secure_compare(actual, expected), do: :ok, else: :error
    end
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v, else: nil
    end)
  end

  defp present?(config, key) do
    case Map.get(config, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp allowed_key?(k) when is_binary(k), do: k in @safe_keys
  defp allowed_key?(_), do: false

  # Only plain scalars survive — an allowlisted key whose value is a map/list
  # (e.g. a nested structure hiding under a safe-looking name) is dropped too,
  # never assumed safe merely because its key name is on the allowlist.
  defp scalar?(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: true
  defp scalar?(_), do: false

  # Constant-time string comparison (mirrors `Samen.Webhook.Signer`'s private
  # helper — duplicated here rather than depending on a private function, and
  # kept dependency-free: no Plug in this package).
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) != byte_size(b) do
      false
    else
      a_bytes = :binary.bin_to_list(a)
      b_bytes = :binary.bin_to_list(b)

      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
      |> Kernel.==(0)
    end
  end

  defp secure_compare(_, _), do: false
end
