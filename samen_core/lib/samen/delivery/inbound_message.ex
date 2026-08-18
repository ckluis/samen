defmodule Samen.Delivery.InboundMessage do
  @moduledoc """
  C5 seam — the normalized result of `Samen.Delivery.Provider.parse_inbound/3`
  (ADR-038 §4.1). The reference ESP adapter package (ADR-038 §8.1) is the
  inbound-capable reference; this struct is the shape ANY inbound-capable
  adapter returns.

  ## Scope note (this is a SEAM, not a consumer)

  This struct is NOT persisted anywhere by this task. Mapping an `InboundMessage`
  into a ticket/thread (the vault/PII discipline that applies to a PERSISTED
  representation) is T59's job (phase 4, C5 consumer). Because nothing here is
  written to a resource/table, the INV-1 "never plaintext-at-rest" rule is not
  engaged at THIS layer — T59 is responsible for applying vault/PII governance
  when it persists any of these fields (from/subject/bodies are vendor-native
  plaintext, exactly as the adapter's inbound webhook sends them).
  """

  @enforce_keys [:provider, :message_id]
  defstruct [
    :provider,
    :message_id,
    :from,
    :from_name,
    :to,
    :subject,
    :text_body,
    :html_body,
    :headers,
    :attachments
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          message_id: String.t(),
          from: String.t() | nil,
          from_name: String.t() | nil,
          to: [String.t()] | nil,
          subject: String.t() | nil,
          text_body: String.t() | nil,
          html_body: String.t() | nil,
          headers: map() | nil,
          attachments: list() | nil
        }
end
