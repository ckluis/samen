defmodule Samen.Mailbox.Account do
  @moduledoc """
  The normalized result of a per-user mailbox CONNECT (spec §I1, T74) — what a
  `Samen.Mailbox.Provider.connect/2` returns once the vendor handshake (OAuth
  consent, IMAP login, Graph delegated permission) genuinely succeeded.

  `:external_account_id` is the provider's opaque handle for the connected
  mailbox (the value later passed back as `account_ref` on `fetch/3` /
  `send/3` / `disconnect/2`). `:address` is 🔒 — it is the mailbox owner's email
  address and is persisted vault-routed (`:pii_email`) on the Connection row,
  never as a plain column.

  `:cursor` is the provider's initial sync position (an IMAP `UIDVALIDITY/UIDNEXT`
  pair, a Gmail `historyId`, a Graph `deltaLink`) — opaque to core, stored as a
  bounded string so a resumed sync never re-reads the whole mailbox.
  """

  @type t :: %__MODULE__{
          external_account_id: String.t(),
          address: String.t() | nil,
          cursor: String.t() | nil,
          meta: map()
        }

  @enforce_keys [:external_account_id]
  defstruct external_account_id: nil, address: nil, cursor: nil, meta: %{}
end
