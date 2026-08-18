defmodule SamenSes.Provider do
  @moduledoc """
  AWS SES implementation of `Samen.Delivery.Provider` (ADR-038 §4; T94/C1) —
  the SECOND reference ESP adapter (M1 ruling), slotting into the SAME shared
  machinery `samen_postmark`/T27 built (the conformance harness, the C4
  deliverability pipeline) without editing any of it.

  ## Fail-honest layering (mirrors the `samen_postmark`/`samen_stripe` precedent)

  Every callback is gated: unconfigured (`config[:access_key_id]` /
  `config[:secret_access_key]` / `config[:region]` / `config[:from]` absent)
  -> `{:error, :not_configured}`; configured but missing the CAPABILITY-
  SPECIFIC host glue it needs -> `{:error, :not_implemented}` (the honest "not
  wired yet", never a fake accept); else the real implementation runs.

  ## `deliver/2` — real SigV4-signed HTTP mechanics, honest recipient-resolution gap

  `Samen.Delivery.Message` is token-only by design (ADR-014) — it carries NO
  recipient email. Resolving `to_subscriber_id -> plaintext email` requires a
  vault reveal under a grant only the HOST (which owns the concrete subscriber
  schema) can perform; no generic ESP adapter package can do this itself. So
  `deliver/2` accepts an injectable `config[:resolve_recipient]` (an arity-1
  function `message -> {:ok, email} | {:error, reason}`) — ABSENT in any real
  host wiring today, so `deliver/2` is honestly `{:error, :not_implemented}` in
  production until an operator wires it (exactly like `samen_postmark`'s
  standing "operator TODO"). The conformance/fixture harness supplies
  `:resolve_recipient` (and `:transport`, §7.2) to prove the REST of the
  pipeline — request building, the real SESv2 `SendEmail` SigV4-signed request
  shape, response parsing, receipt shape — works, without claiming production
  wiring that does not exist yet.

  ## `verify_and_parse_event/3` — real SNS envelope verification, no host glue needed

  Unlike Postmark's Basic-Auth-on-the-URL model, SES publishes deliverability
  events (bounce/complaint/delivery/open/click — `:tracking` rides the SAME
  seam, ADR-038 §4.5) through SNS: the webhook body is an SNS envelope whose
  security model is a per-message RSA signature (`SamenSes.SnsSignature`) over
  a canonical string, verifiable against the X.509 cert the envelope itself
  points at (`SigningCertURL`). This needs no per-host secret to check — it is
  FULLY implemented (no `:not_implemented` gap beyond `configured?/1`),
  including the SNS subscription-confirmation handshake (a `Type ==
  "SubscriptionConfirmation"` envelope, once its OWN signature verifies, is
  confirmed by GET-ing its `SubscribeURL` — `SamenSes.SnsSignature.fetch_live/1`
  by default, injectable via `config[:confirm_subscription]`).

  NOT inbound-capable (ADR-038 §4.5 adapter split: "samen_ses ... no inbound")
  — `parse_inbound/3` is the honest `use Samen.Delivery.Provider` default,
  never overridden here.

  ## Redaction — ALLOWLIST from the start (no denylist detour)

  `redact_payload/1` ships as a top-level SCALAR-KEY ALLOWLIST from day one
  (the T24/T30 hardening line `samen_postmark`/`samen_stripe` had to retrofit
  after starting as a denylist — see `@safe_keys` below for why SES's real,
  deeply-nested event shape makes this even more binding than it was for
  Postmark's naturally-flatter payload).
  """

  use Samen.Delivery.Provider

  alias Samen.Delivery.{Message, ProviderEvent}
  alias SamenSes.{SnsSignature, Transport}

  # Real SES event `eventType` (also seen as the legacy `notificationType` key)
  # -> the bounded, samen-owned ProviderEvent kind enum (ADR-038 §3.3/§4.4).
  # Anything not listed (Send/Reject/RenderingFailure/DeliveryDelay/
  # Subscription/…) maps to :unhandled (stored replay-safe, not dispatched).
  @kind_map %{
    "Bounce" => :bounce,
    "Complaint" => :complaint,
    "Delivery" => :delivered,
    "Open" => :open,
    "Click" => :click
  }

  # ALLOWLIST redaction (ships this way from the start — ADR-038 §5.4 / INV-1;
  # mirrors the T30 denylist->allowlist hardening line samen_postmark and
  # samen_stripe had to retrofit, `redact_payload/1` there). A field survives
  # ONLY IF (a) its name is on `@safe_keys` AND (b) its value is a plain
  # SCALAR — an allowlisted key whose value is a map/list is ALSO dropped,
  # never assumed safe merely because the key name is safe.
  #
  # A real SES event (the inner `Message` JSON of an SNS Notification) is
  # DEEPLY NESTED by vendor design — `{"eventType": "Bounce", "bounce": {...
  # "bouncedRecipients": [{"emailAddress": "…"}] …}, "mail": {... "destination":
  # [...], "commonHeaders": {"to": [...], "from": [...]} ...}}` — every PII-
  # bearing field (recipient addresses, headers, `mail.source`) lives under
  # `bounce`/`complaint`/`delivery`/`mail`, ALL non-scalar. A top-level-only
  # allowlist therefore retains only the handful of genuinely top-level
  # scalar fields SES ever emits (`eventType`, its legacy alias
  # `notificationType`, and the SNS envelope's own `Type` when a confirmation
  # envelope is redacted, §"unhandled_event/1") — everything else, including
  # any invented/unenumerated nested field an attacker or a future SES
  # payload revision might add, is dropped WHOLESALE. This is deliberately
  # the SAFE direction to err: silently retaining a nested PII-bearing object
  # because its container key merely SOUNDS safe is exactly the bug the T30
  # hardening line exists to prevent — SES's shape just makes the "nested is
  # never safe" rule bind on nearly the whole payload instead of one
  # `Metadata`/`metadata` bag.
  @safe_keys ~w(eventType notificationType Type)

  @impl true
  def configured?(config) when is_map(config) do
    present?(config, :access_key_id) and present?(config, :secret_access_key) and
      present?(config, :region) and present?(config, :from)
  end

  def configured?(_), do: false

  @impl true
  def capabilities, do: [:deliverability_webhooks, :tracking]

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
    if configured?(config) do
      case Jason.decode(raw_body) do
        {:ok, %{"Type" => _} = envelope} -> handle_envelope(envelope, config)
        _ -> {:error, :malformed}
      end
    else
      {:error, :not_configured}
    end
  end

  def verify_and_parse_event(_raw_body, _headers, config) do
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

    request =
      %{
        access_key_id: Map.fetch!(config, :access_key_id),
        secret_access_key: Map.fetch!(config, :secret_access_key),
        region: Map.fetch!(config, :region),
        from: Map.fetch!(config, :from),
        to_email: to_email,
        subject: Map.get(config, :subject, "(rendering pending — template #{message.template_id || "none"})"),
        text_body: Map.get(config, :text_body, "(rendering pending — ADR-038 C3/T29)")
      }
      |> maybe_put_session_token(config)

    transport.(request) |> handle_response()
  end

  defp maybe_put_session_token(request, config) do
    case Map.get(config, :session_token) do
      nil -> request
      token -> Map.put(request, :session_token, token)
    end
  end

  defp handle_response({:ok, %{status: status, body: %{"MessageId" => id}}})
       when status in 200..201 and is_binary(id) do
    {:ok, %{provider_message_id: id}}
  end

  defp handle_response({:ok, %{status: status, body: %{"message" => msg} = body}}) do
    {:error, {:ses_error, status, Map.get(body, "__type", "SesError"), msg}}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:unexpected_response, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3

  defp handle_envelope(envelope, config) do
    cert_fetcher = Map.get(config, :cert_fetcher, &SnsSignature.fetch_live/1)

    case SnsSignature.verify(envelope, cert_fetcher) do
      :ok -> dispatch_envelope(envelope, config)
      {:error, :invalid_signature} -> {:error, :invalid_signature}
    end
  end

  defp dispatch_envelope(%{"Type" => "Notification"} = envelope, _config), do: parse_notification(envelope)

  defp dispatch_envelope(%{"Type" => "SubscriptionConfirmation"} = envelope, config),
    do: confirm_and_unhandled(envelope, config)

  # UnsubscribeConfirmation and any future/unknown envelope Type: stored
  # replay-safe (ADR-038 §3.3), not dispatched, no side effect attempted.
  defp dispatch_envelope(envelope, _config), do: {:ok, unhandled_event(envelope)}

  defp parse_notification(envelope) do
    case Jason.decode(envelope["Message"] || "") do
      {:ok, inner} when is_map(inner) ->
        {:ok,
         %ProviderEvent{
           provider: :ses,
           event_id: envelope["MessageId"] || content_hash(envelope),
           kind: Map.get(@kind_map, inner["eventType"] || inner["notificationType"], :unhandled),
           provider_message_id: get_in(inner, ["mail", "messageId"]),
           occurred_at: parse_inner_occurred_at(inner),
           payload: redact_payload(inner)
         }}

      _ ->
        {:error, :malformed}
    end
  end

  # The SNS subscription-confirmation handshake (ADR-038 §4.5 adapter split
  # note): once the envelope's OWN signature has verified, confirm the
  # subscription by GET-ing its SubscribeURL — best-effort, never turns an
  # otherwise-valid, signature-verified envelope into a retried error (a
  # handshake failure here is not something SES will ever resend).
  defp confirm_and_unhandled(envelope, config) do
    confirmer = Map.get(config, :confirm_subscription, &SnsSignature.fetch_live/1)
    _ = safe_confirm(confirmer, envelope["SubscribeURL"])
    {:ok, unhandled_event(envelope)}
  end

  defp safe_confirm(confirmer, url) when is_binary(url) do
    if SnsSignature.valid_sns_host?(url) do
      confirmer.(url)
    else
      {:error, :untrusted_host}
    end
  rescue
    _ -> {:error, :confirm_raised}
  catch
    _, _ -> {:error, :confirm_raised}
  end

  defp safe_confirm(_confirmer, _url), do: {:error, :missing_subscribe_url}

  defp unhandled_event(envelope) do
    %ProviderEvent{
      provider: :ses,
      event_id: envelope["MessageId"] || content_hash(envelope),
      kind: :unhandled,
      provider_message_id: nil,
      occurred_at: parse_envelope_timestamp(envelope),
      payload: redact_payload(%{"Type" => envelope["Type"]})
    }
  end

  defp parse_inner_occurred_at(inner) do
    ts =
      get_in(inner, ["bounce", "timestamp"]) ||
        get_in(inner, ["complaint", "timestamp"]) ||
        get_in(inner, ["delivery", "timestamp"]) ||
        get_in(inner, ["open", "timestamp"]) ||
        get_in(inner, ["click", "timestamp"]) ||
        get_in(inner, ["mail", "timestamp"])

    parse_timestamp(ts)
  end

  defp parse_envelope_timestamp(envelope), do: parse_timestamp(envelope["Timestamp"])

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp content_hash(envelope) do
    :crypto.hash(:sha256, Jason.encode!(envelope)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # ---------------------------------------------------------------------------
  # Shared helpers

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
end
