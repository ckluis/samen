defmodule Samen.Support.Inbound.Config do
  @moduledoc """
  The host-supplied wiring for the C5 inbound-email → ticket capability (T59).

  The inbound capability itself lives entirely in `samen_core`
  (`Samen.Support.Inbound.{Parse,Sanitize,LoopGuard,Threading,Ingest}`); a vertical
  adopts it at ≈0 authored LOC by handing this struct its OWN Support-scope resource
  modules (and, optionally, a CRM `Person`-shaped contact resource) plus the trust
  parameters. Nothing here is derived from the untrusted inbound email — every field
  is host-authoritative:

    * `:org_id` — **the tenant boundary, resolved by the TRUSTED routing layer** (which
      inbound mailbox/recipient received the mail), NEVER from a `From`/`In-Reply-To`/
      subject header. This is the crux of the cross-org-injection defense: a referenced
      ticket is resolved scoped to THIS `org_id`, so a forged reference at another org's
      ticket cannot thread (see `Samen.Support.Inbound.Threading`).
    * `:our_domains` / `:our_addresses` — our OWN sending identity, used by
      `Samen.Support.Inbound.LoopGuard` to refuse to auto-respond to ourselves.
    * `:inbound_localpart` / `:ticket_token_prefix` — the plus-address / subject token
      scheme our OWN outbound uses to encode the ticket id for threading.

  ## Fields

  | Field                  | Purpose                                                        |
  |------------------------|----------------------------------------------------------------|
  | `:org_id` (req)        | tenant boundary (trusted routing, not headers)                 |
  | `:repo` (req)          | the host repo (vault + reads)                                   |
  | `:ticket_resource` (req)      | host `Ticket` module                                    |
  | `:conversation_resource` (req)| host `Conversation` module                              |
  | `:message_resource` (req)     | host `Message` module (🔒 body)                         |
  | `:contact_resource`    | host CRM `Person`-shaped module (🔒 full_name/emails); nil skips |
  | `:file_module`         | host `File` module for attachment chokepoint; nil skips        |
  | `:our_domains`         | our sending domains (downcased) — loop signal                  |
  | `:our_addresses`       | our sending addresses (downcased) — loop signal                |
  | `:inbound_localpart`   | support inbox local part (e.g. `"support"`)                    |
  | `:ticket_token_prefix` | plus-address / subject token prefix (default `"ticket-"`)      |
  | `:max_inbound_per_thread` | runaway bound: max messages per ticket (default 100)        |
  | `:max_body_bytes`      | oversized-body cap (default 256 KiB)                           |
  | `:max_subject_bytes`   | oversized-subject cap (default 4 KiB)                          |
  | `:max_header_value_bytes` | oversized-header cap (default 4 KiB)                        |
  | `:auto_reply`          | arity-1 fun `(reply_ctx -> any)` sending the ack; nil = none    |
  | `:actor`              | optional org-scoped `Samen.Scope` for defense-in-depth authorize |
  """

  @enforce_keys [:org_id, :repo, :ticket_resource, :conversation_resource, :message_resource]
  defstruct [
    :org_id,
    :repo,
    :ticket_resource,
    :conversation_resource,
    :message_resource,
    :contact_resource,
    :file_module,
    :inbound_localpart,
    :auto_reply,
    :actor,
    # T60 (additive, optional): when set, a NEWLY-opened ticket is BORN carrying this
    # `external_id` atomically at insert time (not a later UPDATE). The chat-escalation
    # adopter sets it to the dedupe key `"chat:<thread_ref>"` so the ticket's create —
    # the race point — collides on the partial-unique index, making a concurrent double-
    # escalation impossible. Normal inbound leaves it nil (unconstrained, no regression).
    :new_ticket_external_id,
    file_upload_opts: [],
    our_domains: [],
    our_addresses: [],
    ticket_token_prefix: "ticket-",
    max_inbound_per_thread: 100,
    max_body_bytes: 262_144,
    max_subject_bytes: 4_096,
    max_header_value_bytes: 4_096
  ]

  @type t :: %__MODULE__{}

  @doc """
  Build a validated config from a keyword list / map, applying downcasing to the
  loop-signal identity lists so header comparison is case-insensitive.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts) do
    opts = Map.new(opts)

    struct!(__MODULE__, opts)
    |> Map.update!(:our_domains, &downcase_all/1)
    |> Map.update!(:our_addresses, &downcase_all/1)
  end

  defp downcase_all(list) when is_list(list),
    do: Enum.map(list, fn s -> s |> to_string() |> String.downcase() end)

  defp downcase_all(_), do: []
end
