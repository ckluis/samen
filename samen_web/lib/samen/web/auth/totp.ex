defmodule Samen.Web.Auth.Totp do
  @moduledoc """
  ADR-035 §5 A7/§7 — the `nimble_totp` wrapper (INV-4: `samen_core` never
  references this library). Owns secret/recovery-code generation, the
  `otpauth://` provisioning URI, and the drift-tolerant/anti-replay code
  comparison; delegates every DB mutation to `Samen.Identity.Totp` (the
  kernel's atomic locking + vault reveal), injecting the actual "is this code
  valid" decision as a pure function so the kernel never has to know about
  `NimbleTOTP`.

  ## Secret encoding

  `NimbleTOTP.secret/0` returns 20 raw random bytes — NOT a valid UTF-8
  string, and a vaulted `pii_attribute` must be (`Samen.Vault.Change` stores
  it as `text`). `encode_secret/1`/`decode_secret/1` base64-round-trip it;
  `NimbleTOTP.*` functions always receive the DECODED raw bytes.

  ## Drift window

  `NimbleTOTP.valid?/3` checks exactly ONE 30-second timestep. `valid_code?/3`
  widens that to ±1 step (a ~90-second effective window — ADR-035 §5 A7
  "verify with drift window"), threading the SAME `:since` anti-replay
  watermark through every offset so a used code cannot verify twice via a
  neighboring step either.
  """

  alias Samen.Identity.Totp, as: CoreTotp

  @totp_code_pattern ~r/^\d{6}$/
  @recovery_code_count 10
  @drift_steps 1
  @period 30

  @type mods :: CoreTotp.mods()

  # -- secret / provisioning ----------------------------------------------------

  @doc "Generate a fresh raw TOTP secret (20 random bytes, RFC 4226)."
  @spec generate_secret() :: binary()
  def generate_secret, do: NimbleTOTP.secret()

  @doc "Base64-encode a raw secret for vaulted storage (see moduledoc)."
  @spec encode_secret(binary()) :: String.t()
  def encode_secret(raw_secret) when is_binary(raw_secret), do: Base.encode64(raw_secret)

  @doc "Decode a vault-revealed secret back to raw bytes for NimbleTOTP calls."
  @spec decode_secret(String.t()) :: binary()
  def decode_secret(encoded) when is_binary(encoded), do: Base.decode64!(encoded)

  @doc "The `otpauth://` URI to render as a QR code (label e.g. `\"Samen:user@example.com\"`)."
  @spec provisioning_uri(binary(), String.t(), String.t()) :: String.t()
  def provisioning_uri(raw_secret, label, issuer) when is_binary(raw_secret) and is_binary(label) do
    NimbleTOTP.otpauth_uri(label, raw_secret, issuer: issuer)
  end

  # -- recovery codes ------------------------------------------------------------

  @doc "Generate #{@recovery_code_count} single-use recovery codes (raw — shown once, never persisted)."
  @spec generate_recovery_codes() :: [String.t()]
  def generate_recovery_codes do
    for _ <- 1..@recovery_code_count, do: random_recovery_code()
  end

  defp random_recovery_code do
    raw = :crypto.strong_rand_bytes(6) |> Base.encode32(padding: false) |> String.slice(0, 8)
    String.slice(raw, 0, 4) <> "-" <> String.slice(raw, 4, 4)
  end

  # -- enrollment ------------------------------------------------------------

  @doc """
  Complete enrollment: verifies `code` against the FRESH `raw_secret` (no
  `:since` watermark applies — nothing is persisted yet, ADR-035 §5 A7 "no
  half-enrolled lockouts"), then generates a recovery-code set and writes
  secret + codes + `totp_enabled_at` together, atomically
  (`Samen.Identity.Totp.enroll/4`). Returns the new recovery codes (shown to
  the user exactly once) on success.
  """
  @spec confirm_enrollment(mods, String.t(), binary(), String.t()) ::
          {:ok, term(), [String.t()]} | {:error, :invalid_code | term()}
  def confirm_enrollment(mods, credential_id, raw_secret, code) do
    if valid_code?(raw_secret, code) do
      recovery_codes = generate_recovery_codes()

      case CoreTotp.enroll(mods, credential_id, encode_secret(raw_secret), recovery_codes) do
        {:ok, credential} -> {:ok, credential, recovery_codes}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_code}
    end
  end

  @doc "Disable 2FA for `credential_id` (clears secret/recovery codes/enrollment)."
  @spec disable(mods, String.t()) :: {:ok, term()} | {:error, term()}
  def disable(mods, credential_id), do: CoreTotp.disable(mods, credential_id)

  @doc """
  Regenerate the recovery-code set — invalidates the OLD set entirely.
  Returns the new plaintext codes (shown once).
  """
  @spec regenerate_recovery_codes(mods, String.t()) :: {:ok, term(), [String.t()]} | {:error, term()}
  def regenerate_recovery_codes(mods, credential_id) do
    codes = generate_recovery_codes()

    case CoreTotp.regenerate_recovery_codes(mods, credential_id, codes) do
      {:ok, credential} -> {:ok, credential, codes}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- verify (login / step-up) ------------------------------------------------

  @doc """
  Verify a 6-digit TOTP code for `credential_id` — atomic, drift-tolerant,
  anti-replay (`Samen.Identity.Totp.verify_totp_code/3`).
  """
  @spec verify_login_code(mods, String.t(), String.t()) ::
          {:ok, term()} | {:error, :not_enrolled | :invalid_code | :not_found | term()}
  def verify_login_code(mods, credential_id, code) do
    CoreTotp.verify_totp_code(mods, credential_id, fn encoded_secret, since ->
      valid_code?(decode_secret(encoded_secret), code, since: since)
    end)
  end

  @doc "Consume a raw recovery code (single-use, atomic)."
  @spec verify_recovery_code(mods, String.t(), String.t()) ::
          {:ok, term()} | {:error, :not_enrolled | :invalid_code | :not_found | term()}
  def verify_recovery_code(mods, credential_id, raw_code) do
    CoreTotp.consume_recovery_code(mods, credential_id, raw_code)
  end

  @doc "Whether `input` is shaped like a 6-digit TOTP code (vs. a recovery code) — dispatch helper for the /2fa endpoint."
  @spec totp_shaped?(String.t()) :: boolean()
  def totp_shaped?(input) when is_binary(input), do: Regex.match?(@totp_code_pattern, String.trim(input))
  def totp_shaped?(_), do: false

  # -- drift-tolerant, anti-replay code check --------------------------------

  @doc """
  `code` is valid for `raw_secret` if it matches ANY of the current timestep
  or its ±#{@drift_steps} neighbor(s) (a ~#{(2 * @drift_steps + 1) * @period}s
  effective window), AND that timestep has not already been accepted
  (`:since` — `NimbleTOTP`'s own reused-code guard, applied uniformly across
  every offset so a stale neighboring code cannot bypass the watermark
  either).
  """
  @spec valid_code?(binary(), String.t(), keyword()) :: boolean()
  def valid_code?(raw_secret, code, opts \\ []) when is_binary(raw_secret) and is_binary(code) do
    since = Keyword.get(opts, :since)
    now = Keyword.get(opts, :now, System.os_time(:second))

    Enum.any?(-@drift_steps..@drift_steps, fn step ->
      NimbleTOTP.valid?(raw_secret, code, time: now + step * @period, period: @period, since: since)
    end)
  end
end
