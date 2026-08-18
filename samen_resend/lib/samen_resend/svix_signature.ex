defmodule SamenResend.SvixSignature do
  @moduledoc """
  Real Svix-style webhook signature verification (ADR-038 §4.5 adapter split:
  "samen_resend (Svix-style signatures; no inbound)"), the crypto half of
  `SamenResend.Provider.verify_and_parse_event/3`.

  Resend delivers webhooks through Svix, whose security model is THREE
  headers per request:

    * `svix-id`        — a unique message id for this delivery attempt (also
                          used here as the `ProviderEvent.event_id`, the
                          replay-dedup key — ADR-038 §5.3).
    * `svix-timestamp`  — unix seconds the message was sent.
    * `svix-signature`  — one or more space-separated `v1,<base64 sig>` pairs
                          (Svix sends multiple candidates during secret
                          rotation; ANY match is accepted).

  Real Svix docs, "Verifying Webhooks":
  https://docs.svix.com/receiving/verifying-payloads/how

  ## Signed content (binding shape — DO NOT reorder)

      "{svix-id}.{svix-timestamp}.{raw_body}"

  HMAC-SHA256 over that string, keyed by the secret. The secret is shipped as
  `whsec_<base64>` (Svix's own encoding); the `whsec_` prefix is stripped and
  the remainder base64-decoded to get the raw signing key. `Base.encode64/1`
  of the MAC is compared (constant-time) against each candidate in
  `svix-signature` after the `v1,` prefix.

  ## Timestamp-tolerance replay protection

  A signature is cryptographically valid forever once computed — the
  `svix-timestamp` freshness check is what actually prevents replay of an
  intercepted-but-genuinely-signed request. `verify/4` rejects (fail-closed)
  any timestamp more than `tolerance_seconds` (default 300s / 5min, matching
  Svix's own recommended window) away from "now" in EITHER direction (clock
  skew tolerant, replay-of-an-old-message intolerant).

  ## Hermeticity (ADR-038 §7.2)

  No network access is needed to verify — everything is local HMAC + string
  comparison. The fixture/conformance suite generates real signatures with a
  known fixture secret at test-eval time (so the timestamp is always fresh),
  proving the REAL crypto path end-to-end with zero network access in
  `mix test`.
  """

  @default_tolerance_seconds 300

  @typedoc "A single request's Svix headers, already lowercased-key-matched."
  @type headers :: [{String.t(), String.t()}]

  @doc """
  Verifies `raw_body` against its `svix-id`/`svix-timestamp`/`svix-signature`
  headers using `secret` (the `whsec_...`-shaped webhook signing secret).

  Returns `:ok`, `{:error, :invalid_signature}` (missing/malformed headers,
  malformed secret, or no candidate signature matches), or
  `{:error, :stale_timestamp}` (headers + signature are well-formed and the
  signature MAY be valid, but the timestamp falls outside the tolerance
  window — checked only after signature-shape validation so a garbage
  request can't distinguish itself from a stale-but-real one). NEVER raises
  on attacker-controlled input.

  `opts`:
    * `:tolerance_seconds` — default #{@default_tolerance_seconds}.
    * `:now` — arity-0 fn returning unix seconds; defaults to
      `System.system_time(:second)`. Present for test determinism only —
      production callers never need it.
  """
  @spec verify(binary(), headers(), String.t(), keyword()) ::
          :ok | {:error, :invalid_signature | :stale_timestamp}
  def verify(raw_body, headers, secret, opts \\ [])

  def verify(raw_body, headers, secret, opts)
      when is_binary(raw_body) and is_list(headers) and is_binary(secret) do
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)
    now_fn = Keyword.get(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, svix_id} <- fetch_header(headers, "svix-id"),
         {:ok, svix_timestamp} <- fetch_header(headers, "svix-timestamp"),
         {:ok, svix_signature} <- fetch_header(headers, "svix-signature"),
         {:ok, key} <- decode_secret(secret),
         expected <- compute_signature(key, svix_id, svix_timestamp, raw_body),
         true <- any_signature_matches?(svix_signature, expected) do
      check_freshness(svix_timestamp, now_fn.(), tolerance)
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  catch
    _, _ -> {:error, :invalid_signature}
  end

  def verify(_raw_body, _headers, _secret, _opts), do: {:error, :invalid_signature}

  # ---------------------------------------------------------------------------

  defp fetch_header(headers, name) do
    case Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end) do
      nil -> :error
      "" -> :error
      value -> {:ok, value}
    end
  end

  # `whsec_` prefix stripped, remainder base64-decoded per Svix's own secret
  # encoding. Fails closed (never raises) on a malformed secret.
  defp decode_secret("whsec_" <> b64), do: Base.decode64(b64)
  defp decode_secret(other), do: Base.decode64(other)

  defp compute_signature(key, svix_id, svix_timestamp, raw_body) do
    signed_content = svix_id <> "." <> svix_timestamp <> "." <> raw_body
    :crypto.mac(:hmac, :sha256, key, signed_content) |> Base.encode64()
  end

  # `svix-signature` may carry multiple space-separated "v1,<base64>"
  # candidates (secret rotation) — ANY constant-time match is accepted.
  defp any_signature_matches?(header_value, expected) do
    header_value
    |> String.split(" ", trim: true)
    |> Enum.any?(fn candidate ->
      case String.split(candidate, ",", parts: 2) do
        ["v1", sig] -> secure_compare(sig, expected)
        _ -> false
      end
    end)
  end

  defp check_freshness(svix_timestamp, now, tolerance) do
    case Integer.parse(svix_timestamp) do
      {ts, ""} ->
        if abs(now - ts) <= tolerance do
          :ok
        else
          {:error, :stale_timestamp}
        end

      _ ->
        {:error, :invalid_signature}
    end
  end

  # Constant-time string comparison (mirrors the samen_postmark Basic-Auth
  # helper — duplicated here rather than depending on a private function,
  # kept dependency-free).
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
