defmodule Samen.Fleet.Crypto do
  @moduledoc """
  The `Samen-Fleet-v1` wire authentication scheme (ADR-044 §4.4) — signing-input
  construction, mode-A HMAC-SHA256 sign/verify (constant-time), mode-B Ed25519
  sign/verify, header build/parse, and the unknown-`kid` dummy-verify mitigation
  (§4.4's timing-oracle defence, mirroring the ADR-035 §4.4 sign-in precedent).

  No new dependency: HMAC and Ed25519 both go through OTP's `:crypto` (ADR-037: no
  new deps). `samen_core` has no `Plug` dependency (`Samen.Webhook.Signer` notes
  this precedent), so the constant-time compare is a hand-rolled XOR-accumulate,
  exactly like `Samen.Webhook.Signer.secure_compare/2`.

  ```
  signing input = "samen-fleet-v1\\n" <> METHOD <> "\\n" <> PATH <> "\\n"
                  <> ts <> "\\n" <> nonce <> "\\n" <> sha256(raw_body)

  mode A: sig = HMAC-SHA256(shared_secret, input)     — constant-time compare
  mode B: sig = Ed25519.sign(app_private_key, input)  — verify against public key
  ```

  ## RP-J-1 (the sabotage target)

  The constant-time compare (`secure_compare/2`) and the unknown-kid dummy
  verification (`dummy_verify/0`) are the two things sabotage patches 88+
  independently flip: (a) short-circuit the compare to plain `==`/early-return,
  (b) skip the dummy verify on an unknown `kid` so that path returns early. Each
  must flip its own named test.

  ## `wrap_credential/2` / `unwrap_credential/2` — a DELIBERATE second AEAD,
  never `Samen.Kms.Crypto.decrypt/2`

  `Samen.Chokepoint` enforces exactly ONE `Crypto.decrypt(` call site in
  `samen_core` — `Samen.Vault`'s reveal path — as a structural guarantee that
  subject PII is never decrypted outside the grant-gated chokepoint (T1.5). A
  fleet mode-A shared secret is NOT subject PII (§5.2's own argument: the fleet
  cannot reach a subject at all); it is an OPERATIONAL credential this module
  KMS-wraps for the SAME reason `Samen.Kms` wraps anything (never a plaintext
  column) but through its OWN AEAD call, not the vault's — so the two concerns
  stay structurally distinct and the chokepoint invariant is not weakened to
  make this task's storage need fit. Same primitive (AES-256-GCM via `:crypto`),
  same self-describing `iv(12) <> tag(16) <> ciphertext` layout as
  `Samen.Kms.Crypto`'s `seal/open`, independently implemented.
  """

  @scheme "samen-fleet-v1"

  # A fixed, non-secret decoy HMAC key + Ed25519 public key used ONLY to perform a
  # dummy verification on an unknown `kid`, so the unknown-kid path does the SAME
  # amount of work (one HMAC compute + one constant-time compare, or one Ed25519
  # verify) as a known-kid-bad-signature path. Never used to authorize anything —
  # `verify_hmac/4` / `verify_ed25519/4` always return `false` for it by construction
  # (the decoy key can never match a real signature computed over real content).
  @decoy_hmac_key :crypto.hash(:sha256, "samen-fleet-v1:decoy-hmac-key")

  @doc "The scheme name carried in the Authorization header (`Samen-Fleet-v1`)."
  @spec scheme() :: String.t()
  def scheme, do: @scheme

  @doc """
  Build the exact signing-input bytes for a request (§4.4). `body_sha256_hex` is the
  lowercase-hex SHA-256 of the raw request body (callers compute it once and reuse it
  for both the signing input and any storage/logging need).
  """
  @spec signing_input(String.t(), String.t(), integer(), String.t(), String.t()) :: binary()
  def signing_input(method, path, ts, nonce, body_sha256_hex)
      when is_binary(method) and is_binary(path) and is_integer(ts) and is_binary(nonce) and
             is_binary(body_sha256_hex) do
    @scheme <>
      "\n" <>
      String.upcase(method) <>
      "\n" <> path <> "\n" <> Integer.to_string(ts) <> "\n" <> nonce <> "\n" <> body_sha256_hex
  end

  @doc "Lowercase-hex SHA-256 of the raw body bytes."
  @spec body_digest(binary()) :: String.t()
  def body_digest(raw_body) when is_binary(raw_body) do
    :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)
  end

  @doc "A fresh 16-byte, base64url-encoded nonce for the Authorization header."
  @spec generate_nonce() :: String.t()
  def generate_nonce, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # ---------------------------------------------------------------------------
  # Mode A — HMAC-SHA256
  # ---------------------------------------------------------------------------

  @doc "Mode-A: HMAC-SHA256(shared_secret, signing_input), lowercase hex."
  @spec sign_hmac(binary(), binary()) :: String.t()
  def sign_hmac(shared_secret, signing_input) when is_binary(shared_secret) do
    :crypto.mac(:hmac, :sha256, shared_secret, signing_input) |> Base.encode16(case: :lower)
  end

  @doc """
  Mode-A verify: recompute the HMAC over `signing_input` with `shared_secret` and
  compare to `received_sig_hex` in CONSTANT TIME (`secure_compare/2` — RP-J-1). Never
  short-circuits on a length mismatch in a way that reveals length (constant-time
  compare handles unequal-length inputs by failing the length check first, matching
  the shipped `Samen.Webhook.Signer` precedent — both operands here are always the
  same fixed hex length in real traffic, so this is defense-in-depth, not the
  primary timing surface).
  """
  @spec verify_hmac(binary(), binary(), String.t()) :: boolean()
  def verify_hmac(shared_secret, signing_input, received_sig_hex)
      when is_binary(shared_secret) and is_binary(received_sig_hex) do
    expected = sign_hmac(shared_secret, signing_input)
    secure_compare(expected, received_sig_hex)
  end

  @doc """
  The unknown-`kid` dummy verification (§4.4): perform the SAME shape of work
  (one HMAC compute + one constant-time compare) against a fixed, non-secret decoy
  key, and discard the result. Always returns `false`. Callers on an unknown-`kid`
  path call this INSTEAD OF skipping straight to `401`, so the unknown-kid branch
  costs the same wall-clock as a known-kid-bad-signature branch (RP-J-1 sabotage
  target (b): removing this call is what makes the unknown path return early).

  Emits `:telemetry.execute([:samen, :fleet, :dummy_verify], %{}, %{scheme: :hmac})`
  (fix round — RP-J-1's missing twin (b): a timing-distribution assertion is
  inherently flaky, so the MITIGATION'S PRESENCE is pinned deterministically
  instead — a test attaches a telemetry handler and asserts this event fires
  on the unknown-`kid` heartbeat path; removing this call is refutable by that
  test, not just by a statistical timing sample).
  """
  @spec dummy_verify_hmac(binary()) :: false
  def dummy_verify_hmac(signing_input) when is_binary(signing_input) do
    _ = verify_hmac(@decoy_hmac_key, signing_input, String.duplicate("0", 64))
    :telemetry.execute([:samen, :fleet, :dummy_verify], %{}, %{scheme: :hmac})
    false
  end

  # ---------------------------------------------------------------------------
  # Mode B — Ed25519
  # ---------------------------------------------------------------------------

  @doc "Mode-B: generate a fresh Ed25519 keypair. Returns `{public_key, private_key}` (32B / 32B raw)."
  @spec generate_ed25519_keypair() :: {binary(), binary()}
  def generate_ed25519_keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "Mode-B: Ed25519.sign(private_key, signing_input) — raw 64-byte signature."
  @spec sign_ed25519(binary(), binary()) :: binary()
  def sign_ed25519(private_key, signing_input) when is_binary(private_key) do
    :crypto.sign(:eddsa, :none, signing_input, [private_key, :ed25519])
  end

  @doc "Mode-B verify: Ed25519 signature verification against the stored public key."
  @spec verify_ed25519(binary(), binary(), binary()) :: boolean()
  def verify_ed25519(public_key, signing_input, signature)
      when is_binary(public_key) and is_binary(signature) do
    :crypto.verify(:eddsa, :none, signing_input, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  @doc """
  The unknown-`kid` dummy verification for mode B — same shape (§4.4), a fixed decoy
  Ed25519 public key, always `false`. Emits the same
  `[:samen, :fleet, :dummy_verify]` telemetry event (`scheme: :ed25519`) as
  `dummy_verify_hmac/1` — see its @doc for why.
  """
  @spec dummy_verify_ed25519(binary()) :: false
  def dummy_verify_ed25519(signing_input) when is_binary(signing_input) do
    {decoy_pub, _decoy_priv} = decoy_ed25519_keypair()
    _ = verify_ed25519(decoy_pub, signing_input, :binary.copy(<<0>>, 64))
    :telemetry.execute([:samen, :fleet, :dummy_verify], %{}, %{scheme: :ed25519})
    false
  end

  defp decoy_ed25519_keypair do
    # Deterministic (same process lifetime) decoy keypair derived from a fixed seed
    # via :crypto.generate_key/2 is NOT deterministic across calls (Ed25519 keygen is
    # random by construction), so cache one for the life of the module via a
    # persistent_term — computed once, never a secret, never used for anything real.
    case :persistent_term.get({__MODULE__, :decoy_ed25519}, nil) do
      nil ->
        pair = :crypto.generate_key(:eddsa, :ed25519)
        :persistent_term.put({__MODULE__, :decoy_ed25519}, pair)
        pair

      pair ->
        pair
    end
  end

  # ---------------------------------------------------------------------------
  # Header build/parse — `Samen-Fleet-v1 kid=<key_id>,v=<key_version>,ts=<unix>,
  # nonce=<16B b64>,sig=<b64>`
  # ---------------------------------------------------------------------------

  @doc "Build the Authorization header value."
  @spec build_header(String.t(), integer(), integer(), String.t(), String.t()) :: String.t()
  def build_header(kid, key_version, ts, nonce, sig_hex)
      when is_binary(kid) and is_integer(key_version) and is_integer(ts) and is_binary(nonce) do
    "#{@scheme} kid=#{kid},v=#{key_version},ts=#{ts},nonce=#{nonce},sig=#{sig_hex}"
  end

  @doc """
  Parse an Authorization header value. Returns `{:ok, %{kid:, v:, ts:, nonce:, sig:}}`
  or `{:error, :malformed_header}`. Never raises on malformed input.
  """
  @spec parse_header(String.t()) :: {:ok, map()} | {:error, :malformed_header}
  def parse_header(header) when is_binary(header) do
    with [@scheme, rest] <- String.split(header, " ", parts: 2),
         parts when is_list(parts) <- String.split(rest, ","),
         %{"kid" => kid, "v" => v, "ts" => ts, "nonce" => nonce, "sig" => sig} <-
           parse_kv_pairs(parts),
         {v_int, ""} <- Integer.parse(v),
         {ts_int, ""} <- Integer.parse(ts) do
      {:ok, %{kid: kid, v: v_int, ts: ts_int, nonce: nonce, sig: sig}}
    else
      _ -> {:error, :malformed_header}
    end
  end

  def parse_header(_), do: {:error, :malformed_header}

  defp parse_kv_pairs(parts) do
    Enum.reduce_while(parts, %{}, fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> {:cont, Map.put(acc, k, v)}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      map -> map
    end
  end

  @doc """
  Replay-bound timestamp check (§4.4): `|now - ts| > tolerance_s` ⇒ stale.
  Default tolerance 300s.
  """
  @spec fresh_timestamp?(integer(), integer()) :: boolean()
  def fresh_timestamp?(ts, tolerance_s \\ 300) when is_integer(ts) do
    now = System.os_time(:second)
    abs(now - ts) <= tolerance_s
  end

  # ---------------------------------------------------------------------------
  # Constant-time compare (RP-J-1 — the primary sabotage target). Mirrors
  # `Samen.Webhook.Signer`'s hand-rolled implementation (no Plug dep in samen_core).
  # ---------------------------------------------------------------------------

  @doc false
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
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

  # ---------------------------------------------------------------------------
  # Credential wrap/unwrap — a deliberate SECOND AEAD (see moduledoc). Never
  # `Samen.Kms.Crypto.decrypt/2` — that literal call site is the Samen.Chokepoint
  # single-decrypt invariant's sanctioned one, owned by Samen.Vault's reveal path.
  # ---------------------------------------------------------------------------

  @aad "samen/fleet/credential/v1"

  @doc "AES-256-GCM-wrap `plaintext` under `dek` (a 32-byte key from Samen.Kms)."
  @spec wrap_credential(binary(), binary()) :: binary()
  def wrap_credential(dek, plaintext) when byte_size(dek) == 32 and is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plaintext, @aad, true)
    iv <> tag <> ciphertext
  end

  @doc "AES-256-GCM-unwrap a `wrap_credential/2` blob. `{:error, :decrypt_failed}` on a bad key/tampered blob."
  @spec unwrap_credential(binary(), binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def unwrap_credential(dek, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>)
      when byte_size(dek) == 32 do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  def unwrap_credential(_dek, _blob), do: {:error, :decrypt_failed}
end
