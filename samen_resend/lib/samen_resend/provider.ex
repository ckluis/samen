defmodule SamenResend.Provider do
  @moduledoc """
  Resend implementation of `Samen.Delivery.Provider` (ADR-038 §4; T95/C1) —
  the THIRD reference ESP adapter (M1 ruling), slotting into the SAME shared
  machinery `samen_postmark`/T27 and `samen_ses`/T94 built (the conformance
  harness, the C4 deliverability pipeline) without editing any of it.

  ## Fail-honest layering (mirrors the samen_postmark/samen_ses precedent)

  Every callback is gated: unconfigured (`config[:api_key]` / `config[:from]`
  absent) -> `{:error, :not_configured}`; configured but missing the
  CAPABILITY-SPECIFIC host glue/creds it needs -> `{:error, :not_implemented}`
  (the honest "not wired yet", never a fake accept); else the real
  implementation runs.

  ## `deliver/2` — real HTTP mechanics, honest recipient-resolution gap

  `Samen.Delivery.Message` is token-only by design (ADR-014) — it carries NO
  recipient email. Resolving `to_subscriber_id -> plaintext email` requires a
  vault reveal under a grant only the HOST (which owns the concrete subscriber
  schema) can perform; no generic ESP adapter package can do this itself. So
  `deliver/2` accepts an injectable `config[:resolve_recipient]` (an arity-1
  function `message -> {:ok, email} | {:error, reason}`) — ABSENT in any real
  host wiring today, so `deliver/2` is honestly `{:error, :not_implemented}` in
  production until an operator wires it (exactly like `samen_postmark`'s/
  `samen_ses`'s standing "operator TODO"). The conformance/fixture harness
  supplies `:resolve_recipient` (and `:transport`, §7.2) to prove the REST of
  the pipeline — request building, the real Resend `POST /emails` request
  shape, response parsing, receipt shape — works, without claiming production
  wiring that does not exist yet.

  ## `verify_and_parse_event/3` — real Svix-style verification, no host glue needed

  Resend delivers deliverability webhooks (bounce/complaint/delivered/open/
  click — `:tracking` rides the SAME seam, ADR-038 §4.5) through Svix: three
  headers (`svix-id`, `svix-timestamp`, `svix-signature`) carry an
  HMAC-SHA256 signature over `"{id}.{timestamp}.{body}"`, keyed by a base64
  `whsec_...` secret (`SamenResend.SvixSignature`), plus timestamp-tolerance
  replay protection. This needs a per-host secret (`config[:webhook_secret]`)
  but no network access to verify — a capability-specific credential gate
  (mirrors samen_postmark's `webhook_username`/`webhook_password` gate),
  distinct from the base `configured?/1` send credentials.

  NOT inbound-capable (ADR-038 §4.5 adapter split: "samen_resend ... no
  inbound") — `parse_inbound/3` is the honest `use Samen.Delivery.Provider`
  default, never overridden here.

  ## Redaction — ALLOWLIST from the start (no denylist detour)

  `redact_payload/1` ships as a top-level SCALAR-KEY ALLOWLIST from day one
  (the T24/T30 hardening line `samen_postmark`/`samen_stripe` had to retrofit
  after starting as a denylist, and the same discipline `samen_ses`/T94
  shipped from day one — see `@safe_keys` below). A real Resend webhook body
  is `{"type": ..., "created_at": ..., "data": {...nested, PII-bearing...}}`
  — every recipient/sender/subject field lives under the non-scalar `data`
  key, so a top-level-only allowlist retains only the genuinely safe,
  genuinely top-level scalar fields (`type`, `created_at`) and drops `data`
  (and any invented/unenumerated future top-level field) WHOLESALE.
  """

  use Samen.Delivery.Provider

  alias Samen.Delivery.{Message, ProviderEvent}
  alias SamenResend.{SvixSignature, Transport}

  # Real Resend webhook `type` -> the bounded, samen-owned ProviderEvent kind
  # enum (ADR-038 §3.3/§4.4). Anything not listed (email.sent,
  # email.delivery_delayed, email.failed, email.scheduled, ...) maps to
  # :unhandled (stored replay-safe, not dispatched).
  @kind_map %{
    "email.bounced" => :bounce,
    "email.complained" => :complaint,
    "email.delivered" => :delivered,
    "email.opened" => :open,
    "email.clicked" => :click
  }

  # ALLOWLIST redaction (ships this way from the start — ADR-038 §5.4 / INV-1;
  # mirrors the samen_ses/T94 from-day-one allowlist and the T24/T30
  # denylist->allowlist hardening line samen_postmark/samen_stripe had to
  # retrofit). A field survives ONLY IF (a) its name is on `@safe_keys` AND
  # (b) its value is a plain SCALAR — an allowlisted key whose value is a
  # map/list is ALSO dropped, never assumed safe merely because the key name
  # is safe.
  #
  # A real Resend webhook body nests every PII-bearing field (recipient/
  # sender addresses, subject, bounce/complaint detail) under `data`
  # (non-scalar) — `type` and `created_at` are the only genuinely top-level
  # scalar fields Resend ever emits. This is deliberately the SAFE direction
  # to err: silently retaining a nested PII-bearing object because its
  # container key merely sounds safe is exactly the bug the T30 hardening
  # line exists to prevent.
  @safe_keys ~w(type created_at)

  @impl true
  def configured?(config) when is_map(config) do
    present?(config, :api_key) and present?(config, :from)
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
    cond do
      not configured?(config) ->
        {:error, :not_configured}

      not present?(config, :webhook_secret) ->
        {:error, :not_implemented}

      true ->
        verify_opts =
          config
          |> Map.take([:tolerance_seconds, :now])
          |> Map.to_list()

        case SvixSignature.verify(raw_body, headers, config.webhook_secret, verify_opts) do
          :ok -> parse_body(raw_body, headers)
          {:error, reason} -> {:error, reason}
        end
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

    request = %{
      api_key: Map.fetch!(config, :api_key),
      from: Map.fetch!(config, :from),
      to_email: to_email,
      subject: Map.get(config, :subject, "(rendering pending — template #{message.template_id || "none"})"),
      text_body: Map.get(config, :text_body, "(rendering pending — ADR-038 C3/T29)")
    }

    transport.(request) |> handle_response()
  end

  defp handle_response({:ok, %{status: status, body: %{"id" => id}}})
       when status in 200..201 and is_binary(id) do
    {:ok, %{provider_message_id: id}}
  end

  defp handle_response({:ok, %{status: status, body: %{"message" => msg} = body}}) do
    {:error, {:resend_error, status, Map.get(body, "name", "ResendError"), msg}}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:unexpected_response, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3

  defp parse_body(raw_body, headers) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => _} = body} ->
        {:ok,
         %ProviderEvent{
           provider: :resend,
           event_id: event_id(raw_body, headers),
           kind: Map.get(@kind_map, body["type"], :unhandled),
           provider_message_id: get_in(body, ["data", "email_id"]),
           occurred_at: parse_occurred_at(body),
           payload: redact_payload(body)
         }}

      _ ->
        {:error, :malformed}
    end
  end

  # Prefer the real `svix-id` header — the natural, Svix-native replay-dedup
  # key (ADR-038 §5.3): each webhook DELIVERY attempt (not the underlying
  # email) carries its own stable svix-id, which is exactly the
  # `{provider, event_id}` uniqueness the WebhookEvent replay store keys on.
  # A content hash of the body is the honest fallback only if the header is
  # somehow absent (never happens once signature verification — which
  # requires the SAME header — has already succeeded).
  defp event_id(raw_body, headers) do
    case Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "svix-id", do: v end) do
      id when is_binary(id) and id != "" -> id
      _ -> :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    end
  end

  defp parse_occurred_at(body) do
    ts = body["created_at"] || get_in(body, ["data", "created_at"])

    case ts && DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
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
