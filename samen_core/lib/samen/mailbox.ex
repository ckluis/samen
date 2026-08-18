defmodule Samen.Mailbox do
  @moduledoc """
  **CRM two-way email sync** (spec §I1, ruling M8; T74) — the public face of the
  mailbox seam.

  A user connects their own mailbox; mail that arrives threads onto the matching
  CRM Person and Company timelines; mail sent from the product (or sent directly
  from the user's own mail client, picked up on the next pull) is recorded on the
  same timelines. Message subject/body are vault-routed `:pii_body`, the
  counterparty address `:pii_email` — so an operator without a grant sees `••••` on
  a CRM timeline, never a customer's mail.

  ## The parts

    * `Samen.Mailbox.Provider` — the behaviour a real IMAP/Gmail/Graph adapter
      implements. Core references NO vendor module and pulls NO mailbox dependency
      (INV-4): the whole surface is this behaviour plus normalized structs.
    * `Samen.Mailbox.FakeProvider` — the honest, keyless double CI runs. A real
      adapter is a documented seam behind an explicit host flag and is NEVER
      exercised in CI.
    * `Samen.Mailbox.Message` / `Samen.Mailbox.Account` — the normalized structs.
    * `Samen.Mailbox.Match` — vaulted-address → Person/Company matching through
      `Samen.Api.PiiResolution` (never through the vault directly).
    * `Samen.Mailbox.Sync` — connect / sync / send.
    * `Samen.Scopes.Mailbox` — the host-mountable `Connection` + `MailMessage`
      resources (≈0 authored LOC per vertical: one `use` line).

  ## Fail-honest

  Unconfigured means unconfigured. Every operation here returns
  `{:error, :not_configured}` when no provider is configured — never an empty
  success. `configured?/1` is the single predicate the CRM mailbox settings surface
  reads to decide between the connect affordance and the honest "not connected"
  state; it never renders a fabricated empty inbox.

  See `docs/guides/mailbox-seam.md` for the full adapter callback roster.
  """

  alias Samen.Mailbox.{Config, Sync}

  @doc """
  HOST-level provider selection, mirroring `config :samen_core, :delivery_provider`
  (ADR-038 §4.3): the EXPLICIT flag that turns a real adapter on.

      config :samen_core, :mailbox_provider, {MyImapAdapter.Provider, %{host: "...", ...}}

  Returns `{module, config}` or `nil`. Unset (the default, and the value CI runs
  with) means NO provider — the framework then refuses every operation with
  `{:error, :not_configured}` and every surface renders the honest not-connected
  state. There is no implicit default adapter and no fallback to the fake.
  """
  @spec provider_selection() :: {module(), map()} | nil
  def provider_selection do
    case Application.get_env(:samen_core, :mailbox_provider) do
      {module, config} when is_atom(module) and is_map(config) -> {module, config}
      module when is_atom(module) and not is_nil(module) -> {module, %{}}
      _ -> nil
    end
  end

  @doc """
  Is a real mailbox provider wired AND genuinely configured at the host level?
  The single predicate the CRM mailbox surface reads. `false` (never `nil`, never a
  guess) whenever no provider is selected or the selected one says it is not ready.
  """
  @spec provider_configured?() :: boolean()
  def provider_configured? do
    case provider_selection() do
      {module, config} ->
        Code.ensure_loaded?(module) and function_exported?(module, :configured?, 1) and
          module.configured?(config) == true

      nil ->
        false
    end
  end

  @doc "Is a real mailbox provider configured for this host config? (see `Samen.Mailbox.Config.configured?/1`)"
  @spec configured?(Config.t() | nil) :: boolean()
  defdelegate configured?(config), to: Config

  @doc "Connect a user's mailbox (`Samen.Mailbox.Sync.connect/2`)."
  @spec connect(map(), Config.t()) :: {:ok, struct()} | {:error, term()}
  defdelegate connect(params, config), to: Sync

  @doc "Disconnect a mailbox (`Samen.Mailbox.Sync.disconnect/2`)."
  @spec disconnect(struct(), Config.t()) :: {:ok, struct()} | {:error, term()}
  defdelegate disconnect(connection, config), to: Sync

  @doc "Pull + thread one bounded page (`Samen.Mailbox.Sync.sync/2`)."
  @spec sync(struct(), Config.t()) :: {:ok, map()} | {:error, term()}
  defdelegate sync(connection, config), to: Sync

  @doc "Send AS the mailbox and record it on the timeline (`Samen.Mailbox.Sync.send/3`)."
  @spec send(map(), struct(), Config.t()) :: {:ok, struct()} | {:error, term()}
  defdelegate send(attrs, connection, config), to: Sync
end
