defmodule Samen.Identity.SignIn do
  @moduledoc """
  ADR-035 §4.4 — credential verification, the timing-parity-safe primitive a
  sign-in surface authenticates against. **Scope note:** this module is ONLY
  the bidx-lookup + password-verify check; it does not create an
  `Identity.Session` row, write a cookie, or render a form — full sign-in
  (`LoginLive`, remember-me, the Session row) is A4's contract (T04), built ON
  this primitive. It exists at T03 because the ADR explicitly assigns the
  timing-parity dummy-verify + its red test here (§4.4: "a dummy verify runs
  on unknown-bidx sign-in attempts (timing parity red test in T03)").

  ## No account-existence oracle on sign-in (mirrors the A1 registration fix)

  `Samen.Auth.Hasher.verify/3` is constant-time on the BYTE COMPARISON, but a
  real credential lookup that short-circuits when the bidx matches no row
  would still leak an oracle: an unknown email fails IMMEDIATELY (no PBKDF2
  work), while a known email always pays one PBKDF2 derive (~100-300ms) before
  failing/succeeding. `authenticate/3` closes this by running a REAL
  `Hasher.verify/3` call against a FIXED dummy hash on the unknown-bidx branch
  too — same cost, same code path, discarded result — so response latency
  cannot distinguish "no such account" from "wrong password."
  """

  alias Samen.Auth.BlindIndex
  alias Samen.Auth.Hasher

  # A fixed dummy hash/scheme pair, computed once under the default scheme, to
  # verify against on the unknown-bidx branch. Never a real credential; never
  # compared against a real password. `hash/1` derives via the SAME
  # `:crypto.pbkdf2_hmac` call `verify/3` does, so the cost is equivalent
  # regardless of which of the two functions the timing-parity branch calls.
  @dummy_password "samen-dummy-timing-parity-password-never-compared"

  @type mods :: %{required(:credential) => module()}

  @doc """
  Verify `email`/`password` against the credential the email's blind index
  resolves to. Returns `{:ok, credential}` on a match, `{:error,
  :invalid_credentials}` otherwise — including for an unknown email, a
  passwordless (SSO-only, `password_hash: nil`) credential, and a wrong
  password, all through the SAME generic failure (no oracle on WHY it failed).

  Every branch pays one `Samen.Auth.Hasher` call before returning — the
  unknown-bidx and passwordless branches verify against a fixed dummy
  hash/scheme, discarding the result, purely to burn equivalent latency
  (ADR-035 §4.4 timing-parity discipline).
  """
  @spec authenticate(String.t(), String.t(), mods) ::
          {:ok, term()} | {:error, :invalid_credentials}
  def authenticate(email, password, %{} = mods) when is_binary(email) and is_binary(password) do
    with {:ok, bidx} <- BlindIndex.compute(email) do
      case find_credential(mods, bidx) do
        [credential] -> verify_credential(credential, password)
        [] -> dummy_verify(password)
      end
    else
      _ -> dummy_verify(password)
    end
  end

  defp find_credential(mods, bidx) do
    require Ash.Query

    mods.credential
    |> Ash.Query.filter(email_bidx == ^bidx)
    # `:totp_enabled_at` rides along here (ADR-035 §5 A7) so a caller (the
    # SessionController login gate) can decide whether to complete sign-in or
    # detour through the second factor WITHOUT a second read — same shape as
    # every other field this authenticate/3 call already needed.
    |> Ash.Query.ensure_selected([:id, :password_hash, :hash_scheme, :verified_at, :totp_enabled_at])
    |> Ash.Query.limit(1)
    # authz-scope: pre-auth sign-in lookup keyed on the unique email blind index (<=1 row);
    # the org is not known until the credential resolves — this read IS the login boot path
    |> Ash.read!(authorize?: false)
  end

  # A passwordless (SSO-only, A6) credential has `password_hash: nil` — password
  # sign-in simply fails for it (ADR-035 §5 A6), through the SAME dummy-verify
  # timing-parity branch as an unknown bidx (never a faster/slower rejection).
  defp verify_credential(%{password_hash: nil}, password), do: dummy_verify(password)

  defp verify_credential(%{password_hash: hash, hash_scheme: scheme} = credential, password) do
    if Hasher.verify(password, hash, scheme) do
      {:ok, credential}
    else
      {:error, :invalid_credentials}
    end
  end

  defp dummy_verify(_password) do
    Hasher.hash(@dummy_password)
    {:error, :invalid_credentials}
  end
end
