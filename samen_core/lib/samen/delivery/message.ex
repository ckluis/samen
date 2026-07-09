defmodule Samen.Delivery.Message do
  @moduledoc """
  Token-only outbound-delivery envelope (ADR-014 §2).

  A `Message` carries ONLY opaque IDs and tokens — NEVER plaintext PII. In
  particular the recipient email is NOT a field here: it is looked up at
  `Samen.Delivery.Adapter.deliver/2` time via the vault reveal path under a grant
  (matching the `Samen.Scopes.Marketing.SendWorker` token-only job-args
  convention). This keeps the envelope safe to log, persist to an Oban job row, or
  hand to a `LocalSink` without leaking subject PII.

  ## Fields

    * `:send_id`          — opaque UUID of the send row (canonical identity)
    * `:org_id`           — opaque UUID of the owning org (scoping)
    * `:to_subscriber_id` — opaque UUID of the recipient subscriber (the email is
                             revealed from the vault at delivery time, never here)
    * `:template_id`      — opaque UUID of the template to render (nilable)

  All four are references/tokens; a `Message` therefore satisfies the F2.1
  token-only-args invariant by construction.
  """

  @enforce_keys [:send_id, :org_id, :to_subscriber_id]
  defstruct [:send_id, :org_id, :to_subscriber_id, :template_id]

  @type t :: %__MODULE__{
          send_id: String.t(),
          org_id: String.t(),
          to_subscriber_id: String.t(),
          template_id: String.t() | nil
        }

  @doc """
  Build a `Message` from the SendWorker's token-only Oban args
  (string-keyed map). Returns `{:ok, message}` or `{:error, :missing_send_id}`
  when the canonical `send_id` reference is absent — fail-closed, never a partial
  envelope.
  """
  @spec from_args(map()) :: {:ok, t()} | {:error, :missing_send_id}
  def from_args(args) when is_map(args) do
    case Map.get(args, "send_id") || Map.get(args, :send_id) do
      nil ->
        {:error, :missing_send_id}

      send_id ->
        {:ok,
         %__MODULE__{
           send_id: send_id,
           org_id: Map.get(args, "org_id") || Map.get(args, :org_id),
           to_subscriber_id:
             Map.get(args, "subscriber_id") || Map.get(args, :subscriber_id) ||
               Map.get(args, "to_subscriber_id") || Map.get(args, :to_subscriber_id),
           template_id: Map.get(args, "template_id") || Map.get(args, :template_id)
         }}
    end
  end
end
