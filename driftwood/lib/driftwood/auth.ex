defmodule Driftwood.Auth do
  @moduledoc """
  Driftwood's BYO-auth REFERENCE credential store (F2 / ADR-031).

  Auth is host-owned (ADR-029). This module is the driftwood-local proof that a real,
  fail-closed login CAN sit under the framework session seam (`Samen.Web.Auth` +
  `Samen.Web.CurrentOrg`) — it is NOT what samen ships. A production deploy replaces it with
  `phx.gen.auth` or an external IdP (see `docs/adr/031-*` and `docs/launch-checklist.md`); the
  session seam and the `CurrentOrg` actor gate stay exactly the same underneath.

  ## What it does

  Verifies an email + password against a salted PBKDF2-SHA256 (`:crypto`, no new dep) credential
  record and returns the authenticated user id plus the org ids that user is provisioned for.
  The `authorized_org_ids/1` function is the membership seam `CurrentOrg` calls to constrain the
  tenant actor to the user's own orgs.

  ## No baked backdoor (public-repo hygiene)

  The credential store is EMPTY by default — `config :driftwood, :auth_credentials` is `%{}`
  unless an operator provisions it. This repo commits no working password/hash. Tests inject a
  freshly-hashed credential at runtime; the launch checklist documents provisioning for real.

  Credential record shape (keyed by lowercased email):

      %{"a@ex.test" => %{user_id: "<uuid>", org_ids: ["<tenant_org_id>", …],
                         salt: "<b64>", pbkdf2: "<b64 of hash(password, salt)>"}}
  """

  @iterations 120_000
  @derived_len 32

  @doc "The configured credential store (empty by default — no committed backdoor)."
  @spec credentials() :: map()
  def credentials, do: Application.get_env(:driftwood, :auth_credentials, %{})

  @doc "PBKDF2-SHA256 (Base64) of `password` under `salt`. The digest stored in a credential record."
  @spec hash(String.t(), String.t()) :: String.t()
  def hash(password, salt) when is_binary(password) and is_binary(salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, @derived_len) |> Base.encode64()
  end

  @doc """
  Verify `email` + `password`. Returns `{:ok, user_id, org_ids}` on a constant-time digest match,
  else `:error`. An unknown email still runs a decoy hash (timing-equalized) before failing.
  """
  @spec verify(String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | :error
  def verify(email, password) when is_binary(email) and is_binary(password) do
    case Map.get(credentials(), String.downcase(String.trim(email))) do
      %{salt: salt, pbkdf2: expected, user_id: user_id} = rec
      when is_binary(salt) and is_binary(expected) and is_binary(user_id) ->
        if Plug.Crypto.secure_compare(hash(password, salt), expected) do
          {:ok, user_id, org_ids(rec)}
        else
          :error
        end

      _ ->
        # Timing-equalize: hash even when the email is unknown, then fail.
        _ = hash(password, "driftwood-decoy-salt")
        :error
    end
  end

  def verify(_, _), do: :error

  @doc """
  The tenant org ids the authenticated `user_id` may act on — the `:authorized_orgs` membership
  seam `Samen.Web.CurrentOrg` calls. Sourced from the credential store here; a production deploy
  swaps this for real `Identity.Membership` rows. Unknown user → `[]` (deny).
  """
  @spec authorized_org_ids(String.t()) :: [String.t()]
  def authorized_org_ids(user_id) when is_binary(user_id) do
    credentials()
    |> Enum.find_value([], fn {_email, rec} ->
      if Map.get(rec, :user_id) == user_id, do: org_ids(rec), else: nil
    end)
  end

  def authorized_org_ids(_), do: []

  defp org_ids(rec) do
    case Map.get(rec, :org_ids, []) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end
end
