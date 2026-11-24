defmodule Samen.Vault.Class do
  @moduledoc """
  The class of a vault, decided by the VAULT a field is routed to, never by the field's name.

  `:pii_secret` is the authentication-secret vault (a TOTP secret, recovery-code digests, a webhook
  signing secret). Its values are credentials, not personal data ABOUT a subject: they are never part of
  a subject export (`Samen.Dsar.export_subject/2`). Any field a resource routes to a secret-class vault is
  excluded by construction, so a new secret field needs no change here. A host with its own secret-class
  vault lists it under `config :samen_core, :secret_vaults, [:my_secret_vault]`.
  """

  @builtin ["pii_secret"]

  @doc "The secret-class vault names (strings, as stored in `pii_vault.vault_name`)."
  @spec secret_vaults() :: [String.t()]
  def secret_vaults do
    configured = :samen_core |> Application.get_env(:secret_vaults, []) |> Enum.map(&to_string/1)
    Enum.uniq(@builtin ++ configured)
  end

  @doc "Is `vault` (atom or string) a secret-class vault?"
  @spec secret?(atom() | String.t()) :: boolean()
  def secret?(vault), do: to_string(vault) in secret_vaults()
end
