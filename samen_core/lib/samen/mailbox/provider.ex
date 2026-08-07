defmodule Samen.Mailbox.Provider do
  @moduledoc """
  The core-defined **mailbox provider contract** (spec §I1, ruling M8; T74) — the
  two-way CRM email-sync seam. Same shape, same honesty discipline, and the same
  INV-4 boundary as `Samen.Delivery.Provider` (ADR-038 §4/§8): `samen_core` defines
  the behaviour, the normalized `Samen.Mailbox.Message` / `Samen.Mailbox.Account`
  structs, the honest `Samen.Mailbox.FakeProvider` double, and the whole threading
  pipeline. It references NO vendor module and pulls NO IMAP/Gmail/Graph/HTTP
  dependency — a real adapter is a SEPARATE package, behind an explicit host flag,
  and is NEVER exercised in CI.

  A host selects a mailbox provider through its `Samen.Mailbox.Config`:

      %Samen.Mailbox.Config{
        provider: MyImapAdapter.Provider,
        provider_config: %{host: "imap.example.test", ...},
        ...
      }

  ## The fail-honest contract (ADR-014/024/026 shape, binding)

  Every callback except `configured?/1`, `capabilities/0` and `redact_payload/1`
  returns `{:error, :not_configured}` when `configured?/1` is `false` for the same
  config — NEVER a fabricated `{:ok, _}`, never an empty-but-successful sync, never
  a "connected" account it did not connect. An UNCONFIGURED mailbox is not an empty
  mailbox: a surface that renders "no mail yet" for a provider that never ran is
  the exact lie the gates sabotage-test for. A capability the adapter genuinely
  lacks (undeclared in `capabilities/0`) returns `{:error, :not_implemented}`
  REGARDLESS of configured state.

  ### Precedence when BOTH are absent (binding)

  `capabilities/0` is checked FIRST, so an adapter that is both unconfigured AND
  lacks the capability answers `{:error, :not_implemented}`, not
  `{:error, :not_configured}`. This mirrors `Samen.Delivery.FakeProvider` (the
  shipped ESP precedent) and is the answer an adapter author needs: `:not_configured`
  says "wire credentials and this will work", `:not_implemented` says "this adapter
  will never do that" — a PERMANENT absence must not be reported as a fixable one.
  The capability-gated callbacks are `fetch/3`, `send/3` and `parse_push/3`;
  `connect/2` and `disconnect/2` are not capability-gated (every mailbox provider
  connects), so they answer `{:error, :not_configured}` when unconfigured.

  ## `use Samen.Mailbox.Provider` — the minimal four-function adapter

  `use Samen.Mailbox.Provider` injects overridable, fail-honest defaults for
  `capabilities/0` (`[]`), `disconnect/2` and `parse_push/3`
  (`{:error, :not_implemented}`), and `redact_payload/1` (identity pass-through —
  honest, since an adapter declaring no push capability never receives a raw
  vendor payload to redact). A minimal adapter therefore implements only
  `configured?/1`, `connect/2`, `fetch/3` and `send/3`.

  ## Callback roster (a real adapter implements ALL of these)

  See `docs/guides/mailbox-seam.md` — it names every callback, its arguments, its
  honest refusals, and what a real IMAP/Gmail/Graph adapter must do for each.
  """

  alias Samen.Mailbox.{Account, Message}

  @typedoc """
  The bounded, honestly-declared capability enum. `:inbound_sync` = can pull mail
  the mailbox received; `:outbound_send` = can send AS the connected mailbox;
  `:push_notifications` = can turn a vendor push/webhook payload into messages;
  `:thread_history` = the provider returns a stable `thread_id` so threading does
  not have to fall back on RFC-5322 headers.
  """
  @type capability :: :inbound_sync | :outbound_send | :push_notifications | :thread_history

  @typedoc "The provider's opaque handle for a connected mailbox (`Account.external_account_id`)."
  @type account_ref :: String.t()

  @typedoc "The provider's opaque sync position. Core never interprets it."
  @type cursor :: String.t() | nil

  @doc """
  `true` when the provider has everything it needs to actually reach the mailbox
  (OAuth client + tokens, IMAP host/credentials, ...), `false` otherwise. Every
  other callback except `capabilities/0` and `redact_payload/1` MUST refuse with
  `{:error, :not_configured}` when this is `false` for the same `config` — this
  predicate is the single source of truth, and the honest empty state in the CRM
  mailbox settings surface is rendered from it.
  """
  @callback configured?(config :: map()) :: boolean()

  @doc """
  Honest capability declaration. NOT config-dependent — capabilities are a property
  of the adapter module, not of a runtime config.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Per-user mailbox CONNECT. `params` is the host-supplied handshake input (an OAuth
  authorization code, an IMAP username/app-password, a delegated-permission grant).
  Returns `{:ok, %Samen.Mailbox.Account{}}` ONLY when the mailbox was genuinely
  reached — a provider that cannot verify the mailbox returns an error, never a
  synthesized account.
  """
  @callback connect(params :: map(), config :: map()) ::
              {:ok, Account.t()} | {:error, :not_configured | term()}

  @doc """
  Release the connection (revoke the OAuth grant, drop the IMAP session). Returns
  `:ok` only when the provider actually released it.
  """
  @callback disconnect(account_ref :: account_ref(), config :: map()) ::
              :ok | {:error, :not_configured | :not_implemented | term()}

  @doc """
  Pull one bounded page of messages for `account_ref` starting at `cursor`. Returns
  `{:ok, %{messages: [Message.t()], cursor: cursor()}}`. The page MUST include BOTH
  directions the mailbox holds — inbound mail AND mail the user sent from that
  mailbox (`%Message{direction: :outbound}`) — that is what makes the sync two-way
  even for mail composed outside the product. An adapter that does not declare
  `:inbound_sync` returns `{:error, :not_implemented}`.
  """
  @callback fetch(account_ref :: account_ref(), cursor :: cursor(), config :: map()) ::
              {:ok, %{messages: [Message.t()], cursor: cursor()}}
              | {:error, :not_configured | :not_implemented | term()}

  @doc """
  Send `message` AS the connected mailbox (the outbound leg). Returns
  `{:ok, receipt}` ONLY when the provider actually dispatched it; the receipt MUST
  carry `:external_id` when the provider returns one — it is the dedupe key that
  stops the next `fetch/3` from double-recording the same send. An adapter that
  does not declare `:outbound_send` returns `{:error, :not_implemented}`.
  """
  @callback send(message :: Message.t(), account_ref :: account_ref(), config :: map()) ::
              {:ok, receipt :: map()} | {:error, :not_configured | :not_implemented | term()}

  @doc """
  Turn a vendor push/webhook payload into normalized messages (Gmail `watch`
  notification, Graph subscription, IMAP IDLE bridge). Signature verification is the
  ADAPTER's job; a bad signature returns `{:error, :invalid_signature}` and parses
  NOTHING. Adapters without `:push_notifications` return `{:error, :not_implemented}`.
  """
  @callback parse_push(
              raw_body :: binary(),
              headers :: [{String.t(), String.t()}],
              config :: map()
            ) ::
              {:ok, [Message.t()]}
              | {:error, :invalid_signature | :malformed | :not_implemented | term()}

  @doc """
  PII pruning of a raw vendor payload BEFORE anything about it is persisted or
  logged. A pure function — it must not need creds or network access, so it is
  exempt from the `configured?/1` fail-honest gate.
  """
  @callback redact_payload(payload :: map()) :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour Samen.Mailbox.Provider

      @impl Samen.Mailbox.Provider
      def capabilities, do: []

      @impl Samen.Mailbox.Provider
      def disconnect(_account_ref, _config), do: {:error, :not_implemented}

      @impl Samen.Mailbox.Provider
      def parse_push(_raw_body, _headers, _config), do: {:error, :not_implemented}

      @impl Samen.Mailbox.Provider
      def redact_payload(payload) when is_map(payload), do: payload

      defoverridable capabilities: 0, disconnect: 2, parse_push: 3, redact_payload: 1
    end
  end
end
