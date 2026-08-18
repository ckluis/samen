defmodule Samen.Auth.TokenMint do
  @moduledoc """
  ADR-035 §4.2 — the mint half of the shared emailed-token discipline (paired
  with `Samen.Auth.TokenConsume`): 32 random bytes, URL-safe base64 (the RAW
  token — appears only in the caller's return value / the eventual email
  body, never persisted, never logged); at rest ONLY the SHA-256 digest.

  `Samen.Identity.Register` (A1/T02) mints its own `:email_verify` token
  inline (it must run inside A1's single atomic transaction); this module is
  for every OTHER mint — A2 resend, A3 password-reset request — which run
  outside any such transaction.
  """

  @doc "SHA-256 hex digest of a raw token (the ONLY thing ever persisted)."
  @spec digest(String.t()) :: String.t()
  def digest(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  @doc """
  Mint a fresh `AuthToken` row for `credential_id`/`context`, bound to
  `sent_to_bidx`, expiring `ttl_seconds` from now. Returns `{:ok, auth_token,
  raw_token}` — the RAW token is handed back to the caller ONCE; only its
  digest is persisted.
  """
  @spec mint(module(), String.t(), atom(), String.t() | nil, non_neg_integer()) ::
          {:ok, term(), String.t()} | {:error, term()}
  def mint(auth_token_mod, credential_id, context, sent_to_bidx, ttl_seconds)
      when is_binary(credential_id) and is_atom(context) and is_integer(ttl_seconds) do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = DateTime.utc_now() |> DateTime.add(ttl_seconds, :second)

    result =
      auth_token_mod
      |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
      |> Ash.Changeset.force_change_attribute(:token_digest, digest(raw_token))
      |> Ash.Changeset.force_change_attribute(:context, context)
      |> Ash.Changeset.force_change_attribute(:sent_to_bidx, sent_to_bidx)
      |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
      |> Ash.Changeset.force_change_attribute(:consumed_at, nil)
      |> Ash.create()

    case result do
      {:ok, auth_token} -> {:ok, auth_token, raw_token}
      {:error, reason} -> {:error, reason}
    end
  end
end
