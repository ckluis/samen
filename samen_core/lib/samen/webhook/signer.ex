defmodule Samen.Webhook.Signer do
  @moduledoc """
  HMAC-SHA256 body + timestamp signing for outbound webhooks, and a receiver-side
  verify helper with anti-replay protection (doc §external-surface webhook bullets;
  plan T3.13).

  ## Signing (outbound)

  `sign/3` takes the serialized body, a Unix timestamp (integer seconds), and the
  per-endpoint secret, and produces a signature:

      signature = HMAC-SHA256(secret, timestamp <> "." <> body)

  The header format:

      Samen-Signature: t=<timestamp>,v1=<hex_signature>

  This is the same shape used by common vendor webhook signature schemes (an
  HMAC over `timestamp.body`, with the timestamp carried in the header) — widely
  understood by receiver libraries and easy to replay-protect.

  ## Verifying (inbound / receiver side)

  `verify/4` is the **receiver-side verify helper**. It takes the raw body, the
  received `Samen-Signature` header value, the per-endpoint secret, and a
  tolerance (seconds). It:

    1. Parses the `t=` and `v1=` values from the header.
    2. Recomputes the expected HMAC over `"<timestamp>.<body>"`.
    3. Compares expected vs received using a constant-time comparison (`Plug.Crypto`
       / `Crypto.secure_compare`).
    4. Checks the timestamp is within the tolerance window (default: 300 seconds).

  Returns `{:ok, timestamp}` on success, `{:error, :bad_signature}` if the HMAC
  does not match, or `{:error, :stale_timestamp}` if the timestamp is outside the
  tolerance window.

  The verify helper rejects stale timestamps EVEN if the HMAC is valid — this is
  the anti-replay gate.

  ## Anti-tautology note

  Red-path tests seed a tampered body (bad sig) AND a replayed event (stale
  timestamp), confirming both are rejected. The anti-tautology probe sabotages the
  `secure_compare/2` call to always return `true`, confirms the stale-timestamp
  path is still rejected (timestamp check is independent), then reverts.
  """

  import Bitwise

  @default_tolerance_seconds 300

  @doc """
  Build the `Samen-Signature` header value for `body` at `timestamp`.

  The returned string is ready to set as the `Samen-Signature` HTTP header.

      "t=1720000000,v1=abc123..."
  """
  @spec sign(String.t(), integer(), String.t()) :: String.t()
  def sign(body, timestamp, secret)
      when is_binary(body) and is_integer(timestamp) and is_binary(secret) do
    sig = compute_hmac(body, timestamp, secret)
    "t=#{timestamp},v1=#{sig}"
  end

  @doc """
  Verify a received `Samen-Signature` header.

  Returns `{:ok, timestamp}` on success, or
  `{:error, :bad_signature | :stale_timestamp | :malformed_header}`.

  The `tolerance_seconds` window is the maximum age of a valid webhook delivery
  (default: 300s = 5 minutes). A valid HMAC outside the window is still rejected
  as a replay — the receiver must process the event before the tolerance expires.
  """
  @spec verify(String.t(), String.t(), String.t(), integer()) ::
          {:ok, integer()} | {:error, :bad_signature | :stale_timestamp | :malformed_header}
  def verify(body, header, secret, tolerance_seconds \\ @default_tolerance_seconds)
      when is_binary(body) and is_binary(header) and is_binary(secret) do
    with {:ok, timestamp, received_sig} <- parse_header(header),
         :ok <- check_timestamp(timestamp, tolerance_seconds) do
      expected = compute_hmac(body, timestamp, secret)

      if secure_compare(expected, received_sig) do
        {:ok, timestamp}
      else
        {:error, :bad_signature}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers

  defp compute_hmac(body, timestamp, secret) do
    payload = "#{timestamp}.#{body}"

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp parse_header(header) do
    parts = String.split(header, ",")

    with [t_part | rest] <- parts,
         {"t", ts_str} <- parse_kv(t_part),
         [v1_part | _] <- Enum.filter(rest, &String.starts_with?(&1, "v1=")),
         {"v1", sig} <- parse_kv(v1_part),
         {ts, ""} <- Integer.parse(ts_str) do
      {:ok, ts, sig}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp parse_kv(str) do
    case String.split(str, "=", parts: 2) do
      [k, v] -> {k, v}
      _ -> :error
    end
  end

  defp check_timestamp(timestamp, tolerance_seconds) do
    now = System.os_time(:second)
    age = now - timestamp

    if age >= 0 and age <= tolerance_seconds do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  # Constant-time string comparison to prevent timing-based HMAC oracle attacks.
  # Uses Plug.Crypto when available; falls back to `:crypto.hash/2` compare.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    # Length check first (avoids timing leak on length mismatch — both strings
    # are hex-encoded fixed-length SHAs, so this branch should rarely differ).
    if byte_size(a) != byte_size(b) do
      false
    else
      # XOR every byte; accumulate into a running OR.  Equivalent to Plug.Crypto
      # but avoids a runtime dep — Plug may not be available in samen_core.
      a_bytes = :binary.bin_to_list(a)
      b_bytes = :binary.bin_to_list(b)

      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> bor(acc, bxor(x, y)) end)
      |> Kernel.==(0)
    end
  end
end
