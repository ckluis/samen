defmodule Samen.Delivery.ProviderEvent do
  @moduledoc """
  Normalized deliverability-webhook event (ADR-038 §4.4; C4, T30 consumes).

  Recipient matching goes `provider_message_id -> send receipt -> subscriber ref`
  — NEVER by email address; the raw recipient email in the vendor payload is
  removed by `redact_payload/1` before an envelope carrying this struct's
  `payload` is ever persisted (§5.4). `kind` is the bounded, samen-owned enum —
  unknown vendor events map to `:unhandled` (stored replay-safe, not dispatched).
  """

  @enforce_keys [:provider, :event_id, :kind, :occurred_at, :payload]
  defstruct [:provider, :event_id, :kind, :provider_message_id, :occurred_at, :payload]

  @type kind :: :delivered | :bounce | :complaint | :open | :click | :unhandled

  @type t :: %__MODULE__{
          provider: atom(),
          event_id: String.t(),
          kind: kind(),
          provider_message_id: String.t() | nil,
          occurred_at: DateTime.t(),
          payload: map()
        }
end
