defmodule Samen.Auth.Hasher.Pbkdf2 do
  @moduledoc """
  The default `Samen.Auth.Hasher` (ADR-035 §4.4): PBKDF2-SHA256 via OTP `:crypto`
  only — no new dependency. 600,000 iterations (OWASP 2023+ level), a fresh
  16-byte random salt per credential, constant-time verify.

  Deliberately NOT bcrypt/argon2: those are NIF deps, and this hasher lives in
  `samen_core`, whose `mix.exs` this ADR requires stay untouched (INV-4). A host
  that wants a memory-hard hasher wires one behind the `Samen.Auth.Hasher`
  behaviour and owns that dependency itself (`config :samen_core, :auth_hasher,
  MyArgon2`).

  ## Encoding

  `hash/1` returns `{encoded, scheme}` where:

    * `scheme` is `"pbkdf2-sha256$<iterations>"` (e.g. `"pbkdf2-sha256$600000"`) —
      travels alongside the hash so a future iteration-count bump can still verify
      old rows under their original parameters.
    * `encoded` is `Base.url_encode64(salt) <> "." <> Base.url_encode64(derived_key)`
      — the salt rides WITH the hash (never a separate column), the standard
      PBKDF2-at-rest shape.

  `verify/3` re-derives under the SAME salt + the scheme's iteration count and
  compares with `:crypto.hash_equals/2` (constant-time; ADR-035 §4.4) — never
  `==` on the raw bytes, which would leak timing on the first differing byte.
  """

  @behaviour Samen.Auth.Hasher

  @algo "pbkdf2-sha256"
  @default_iterations 600_000
  @salt_bytes 16
  @derived_len 32

  @impl true
  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    derived = derive(password, salt, @default_iterations)

    encoded = Base.url_encode64(salt) <> "." <> Base.url_encode64(derived)
    scheme = "#{@algo}$#{@default_iterations}"

    {encoded, scheme}
  end

  @impl true
  def verify(password, hash, scheme)
      when is_binary(password) and is_binary(hash) and is_binary(scheme) do
    with {:ok, iterations} <- parse_scheme(scheme),
         {:ok, salt, expected} <- parse_hash(hash) do
      actual = derive(password, salt, iterations)
      byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected)
    else
      _ -> false
    end
  end

  def verify(_, _, _), do: false

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @derived_len)
  end

  defp parse_scheme(@algo <> "$" <> iter_str) do
    case Integer.parse(iter_str) do
      {iterations, ""} when iterations > 0 -> {:ok, iterations}
      _ -> :error
    end
  end

  defp parse_scheme(_), do: :error

  defp parse_hash(hash) do
    case String.split(hash, ".", parts: 2) do
      [salt_b64, digest_b64] ->
        with {:ok, salt} <- Base.url_decode64(salt_b64),
             {:ok, digest} <- Base.url_decode64(digest_b64) do
          {:ok, salt, digest}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
