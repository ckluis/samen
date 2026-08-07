defmodule Samen.Mailbox.Message do
  @moduledoc """
  The normalized, vendor-neutral mailbox message (spec §I1, T74) — the ONLY shape a
  `Samen.Mailbox.Provider` hands to (or takes from) the framework. Mirrors
  `Samen.Delivery.InboundMessage`'s posture: `samen_core` owns the struct, every
  vendor-specific envelope (IMAP `FETCH` body, Gmail `users.messages.get`,
  Microsoft Graph `message`) is normalized INTO it inside the adapter package, so
  core never learns a vendor's field names (INV-4, ADR-038 §8).

  ## Fields

    * `:external_id`  — the provider's own immutable message id (dedupe key).
    * `:thread_id`    — the provider's own thread/conversation id, when it has one.
    * `:direction`    — `:inbound` (arrived in the connected mailbox) or `:outbound`
      (sent FROM the connected mailbox — the second leg of the two-way sync).
    * `:from_address` / `:to_addresses` / `:cc_addresses` — 🔒 addresses. Plaintext
      IN TRANSIT only: the persisted row vaults the counterparty address (`:pii_email`).
    * `:subject` / `:body` — 🔒 free-text content; persisted vault-routed (`:pii_body`).
    * `:occurred_at`  — when the provider says the message was sent/received.
    * `:in_reply_to` / `:references` — RFC-5322 threading headers (untrusted).
    * `:meta`         — bounded, already-redacted provider metadata. NEVER raw PII.

  Every field is untrusted input: `Samen.Mailbox.Sync` bounds/normalizes before it
  writes, exactly like `Samen.Support.Inbound.Parse` does for C5 inbound.
  """

  @type direction :: :inbound | :outbound

  @type t :: %__MODULE__{
          external_id: String.t() | nil,
          thread_id: String.t() | nil,
          direction: direction(),
          from_address: String.t() | nil,
          to_addresses: [String.t()],
          cc_addresses: [String.t()],
          subject: String.t() | nil,
          body: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          meta: map()
        }

  defstruct external_id: nil,
            thread_id: nil,
            direction: :inbound,
            from_address: nil,
            to_addresses: [],
            cc_addresses: [],
            subject: nil,
            body: nil,
            occurred_at: nil,
            in_reply_to: nil,
            references: [],
            meta: %{}

  @doc """
  The COUNTERPARTY address of a message relative to the connected mailbox: the
  sender for inbound mail, the first recipient for outbound mail. This is the
  address the CRM match runs against (`Samen.Mailbox.Match`) — matching on the
  mailbox owner's OWN address would thread every message onto the same record.
  """
  @spec counterparty(t()) :: String.t() | nil
  def counterparty(%__MODULE__{direction: :inbound, from_address: from}) when is_binary(from),
    do: from

  def counterparty(%__MODULE__{direction: :outbound, to_addresses: [to | _]}) when is_binary(to),
    do: to

  def counterparty(%__MODULE__{}), do: nil
end
