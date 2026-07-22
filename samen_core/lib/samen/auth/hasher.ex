defmodule Samen.Auth.Hasher do
  @moduledoc """
  The password-hashing behaviour (ADR-035 §4.4). `samen_core` ships exactly one
  default implementation, `Samen.Auth.Hasher.Pbkdf2` — PBKDF2-SHA256 via OTP
  `:crypto`, 600,000 iterations, no new dependency (`samen_core/mix.exs` stays
  untouched, INV-4). A host may wire a memory-hard hasher (argon2/bcrypt, a NIF
  dep it owns) via `config :samen_core, :auth_hasher, MyArgon2` — same adapter
  seam shape as `Samen.Kms`/`Samen.Files.Storage`.

  ## Why a `hash_scheme` string travels with every hash

  `Credential.password_hash` stores the encoded hash; `Credential.hash_scheme`
  stores WHICH scheme produced it (e.g. `"pbkdf2-sha256$600000"`). `verify/3`
  takes the scheme explicitly (not `adapter().verify/2` blind) so a future
  iteration-count bump or hasher migration can verify old rows under their
  original scheme while new rows mint the new one — transparent upgrade, never a
  silent re-hash of a password nobody re-typed.
  """

  @type password :: binary()
  @type hash :: binary()
  @type scheme :: String.t()

  @doc "Hash `password`. Returns the encoded hash and the scheme string that produced it."
  @callback hash(password) :: {hash, scheme}

  @doc "Verify `password` against `hash`, produced under `scheme`. Constant-time."
  @callback verify(password, hash, scheme) :: boolean()

  @doc "The configured hasher adapter. Defaults to the pure-OTP PBKDF2-SHA256 hasher."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:samen_core, :auth_hasher, Samen.Auth.Hasher.Pbkdf2)

  @doc "Hash `password` under the configured adapter."
  @spec hash(password) :: {hash, scheme}
  def hash(password) when is_binary(password), do: adapter().hash(password)

  @doc "Verify `password` against `hash`/`scheme` under the configured adapter."
  @spec verify(password, hash, scheme) :: boolean()
  def verify(password, hash, scheme)
      when is_binary(password) and is_binary(hash) and is_binary(scheme),
      do: adapter().verify(password, hash, scheme)

  def verify(_, _, _), do: false
end
