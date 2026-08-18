defmodule Samen.Auth.BlindIndex do
  @moduledoc """
  The blind-index email lookup (ADR-035 §4.1) — the vault-compatible identity
  query `ash_authentication` needed a plaintext column for. No plaintext email
  column exists anywhere (INV-1); sign-in/reset/invite lookups instead compare
  `email_bidx = Base.encode16(HMAC-SHA256(k_bidx, normalize(email)))`.

  ## `k_bidx` — the reserved synthetic KMS subject

  `Samen.Kms`'s behaviour is subject-keyed only (no purpose-key API). `k_bidx` is
  provisioned as the reserved SYNTHETIC subject `"sys:bidx"` through the ordinary
  `generate_subject_key/1` + `unwrap/1` callbacks — no new adapter, no new
  behaviour callback. `"sys:bidx"` is org-independent (sign-in happens BEFORE a
  subject/org context exists) and is never the app `secret_key_base`.
  `"sys:bidx"` is PERMANENTLY EXCLUDED from `shred/1` (`Samen.Kms.shred/1`
  refuses it structurally) — shredding the shared lookup key would break every
  login, not erase one subject.

  ## Properties (ADR-035 §4.1)

    * Non-reversible (keyed HMAC) — equality-only lookup, exactly what sign-in,
      password reset, invite-matching, and Credential uniqueness need.
    * `normalize/1` = trim + NFC + lowercase, so `" A@Ex.TEST "`, `"a@ex.test"`,
      and an NFC-equivalent Unicode form all compute the SAME index.
    * `compute/1` never returns the plaintext or the lowercased email as the
      index — see the red test in `samen_core/test/auth/blind_index_test.exs`.
  """

  alias Samen.Kms

  @bidx_subject "sys:bidx"

  @doc "The reserved synthetic KMS subject `k_bidx` is provisioned under."
  @spec bidx_subject() :: String.t()
  def bidx_subject, do: @bidx_subject

  @doc """
  Normalize an email for blind-index computation: trim, NFC-normalize, lowercase.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.normalize(:nfc)
    |> String.downcase()
  end

  @doc """
  Compute the blind index for `email`: `Base.encode16(HMAC-SHA256(k_bidx,
  normalize(email)))`. Ensures `k_bidx` exists (provisioning it under the
  reserved subject on first use) and never raises — I/O errors from the KMS
  adapter surface as `{:error, term}`.
  """
  @spec compute(String.t()) :: {:ok, String.t()} | {:error, term}
  def compute(email) when is_binary(email) do
    with :ok <- ensure_bidx_key(),
         {:ok, k_bidx} <- Kms.adapter().unwrap(@bidx_subject) do
      digest = :crypto.mac(:hmac, :sha256, k_bidx, normalize(email))
      {:ok, Base.encode16(digest, case: :upper)}
    end
  end

  defp ensure_bidx_key do
    case Kms.adapter().attest(@bidx_subject) do
      {:ok, %{state: :active}} ->
        :ok

      _ ->
        case Kms.adapter().generate_subject_key(@bidx_subject) do
          {:ok, _wrapped} -> :ok
          error -> error
        end
    end
  end
end
