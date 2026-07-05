defmodule Samen.Kms.Crypto do
  @moduledoc """
  Shared envelope-crypto primitives for the KMS adapters (ADR-001 §2).

  - `wrap/2` / `unwrap/2`: AES-256-GCM wrap of a per-subject DEK under a master
    key. This is the local-dev stand-in for `KMS.Encrypt` / `KMS.Decrypt`. The
    master key is a fixed dev key; in production this is a KMS CMK the app never
    holds in the clear.
  - `encrypt/2` / `decrypt/2`: AES-256-GCM of vault field ciphertext under the
    unwrapped DEK.
  - `pseudonym_key/1` + `pseudonym/2`: HKDF-derive `psk_S` from `DEK_S`, then
    `HMAC(psk_S, subject_id)` — the J2 trace-sink pseudonym that rides the same
    DEK, so one shred unlinks it (ADR-001 §2, RQ5).

  All AEAD; a tampered ciphertext or wrong key fails the GCM tag check and
  returns `{:error, :decrypt_failed}` rather than garbage plaintext (fail-closed).

  ## Trust surface

  This module is the entire crypto core (~100 lines). It uses only OTP `:crypto`
  AES-256-GCM (FIPS-grade) with random 96-bit IVs and authenticated AAD. The
  `to_string/1` / log paths on ciphertext output never emit plaintext because
  the output is a raw `:binary`, not a printable string. No third-party crypto
  library dependency exists or is needed (ADR-003).
  """

  @aad "samen/vault/v1"
  @pseudonym_info "samen/obs-pseudonym/v1"
  @dek_bytes 32

  @doc "Generate a fresh 32-byte per-subject DEK."
  @spec generate_dek() :: binary()
  def generate_dek, do: :crypto.strong_rand_bytes(@dek_bytes)

  @doc """
  Wrap a DEK under the master key (dev analog of `KMS.Encrypt`).
  Returns a self-describing blob: iv(12) <> tag(16) <> ciphertext.
  """
  @spec wrap(binary(), binary()) :: binary()
  def wrap(master_key, dek) when byte_size(master_key) == 32 do
    seal(master_key, dek, "samen/wrap/v1")
  end

  @doc "Unwrap a wrapped DEK under the master key (dev analog of `KMS.Decrypt`)."
  @spec unwrap(binary(), binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def unwrap(master_key, wrapped) when byte_size(master_key) == 32 do
    open(master_key, wrapped, "samen/wrap/v1")
  end

  @doc "AES-256-GCM encrypt vault field plaintext under a DEK."
  @spec encrypt(binary(), binary()) :: binary()
  def encrypt(dek, plaintext) when byte_size(dek) == 32 do
    seal(dek, plaintext, @aad)
  end

  @doc "AES-256-GCM decrypt vault field ciphertext under a DEK."
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def decrypt(dek, blob) when byte_size(dek) == 32 do
    open(dek, blob, @aad)
  end

  @doc """
  Derive the per-subject pseudonym HMAC key `psk_S = HKDF(DEK_S, info)`.
  No independent key material: destroying DEK_S makes this unreconstructable.
  """
  @spec pseudonym_key(binary()) :: binary()
  def pseudonym_key(dek) when byte_size(dek) == 32 do
    hkdf_sha256(dek, "", @pseudonym_info, 32)
  end

  @doc "actor_id = HMAC(psk_S, subject_id), lowercase hex (J2, ADR-001 §2 RQ5)."
  @spec pseudonym(binary(), String.t()) :: binary()
  def pseudonym(dek, subject_id) when byte_size(dek) == 32 do
    psk = pseudonym_key(dek)
    :crypto.mac(:hmac, :sha256, psk, subject_id) |> Base.encode16(case: :lower)
  end

  # --- internal AEAD helpers ---

  defp seal(key, plaintext, aad) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

    iv <> tag <> ciphertext
  end

  defp open(key, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  defp open(_key, _blob, _aad), do: {:error, :decrypt_failed}

  # RFC 5869 HKDF-Extract + HKDF-Expand over SHA-256.
  defp hkdf_sha256(ikm, salt, info, length) do
    salt = if salt == "", do: <<0::size(256)>>, else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    expand(prk, info, length, 1, "", "")
  end

  defp expand(_prk, _info, length, _counter, _prev, acc) when byte_size(acc) >= length do
    binary_part(acc, 0, length)
  end

  defp expand(prk, info, length, counter, prev, acc) do
    block = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<counter>>)
    expand(prk, info, length, counter + 1, block, acc <> block)
  end
end
