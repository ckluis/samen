defmodule Samen.Billing.ProviderEvent do
  @moduledoc """
  Normalized billing webhook event (ADR-038 §3.3; T18/B1).

  Every `Samen.Billing.Provider` adapter's `verify_and_parse_event/3` returns one of
  these on success. `payload` is ALREADY redacted (`redact_payload/1` ran before
  this struct was built) — never re-derive PII from it.

  `kind` is a bounded, samen-owned enum. Adapters map vendor event names onto it;
  any vendor event the adapter does not recognize maps to `:unhandled` and is
  stored (replay-safe, T19 §5.3) but not dispatched to the reconciler.
  """

  @enforce_keys [:provider, :event_id, :kind, :occurred_at, :provider_refs, :payload]
  defstruct [:provider, :event_id, :kind, :occurred_at, :provider_refs, :payload]

  @type kind ::
          :checkout_completed
          | :checkout_expired
          | :subscription_created
          | :subscription_updated
          | :subscription_deleted
          | :invoice_finalized
          | :invoice_paid
          | :invoice_payment_failed
          | :payment_method_attached
          | :payment_method_detached
          | :unhandled

  @type t :: %__MODULE__{
          provider: atom(),
          event_id: String.t(),
          kind: kind(),
          occurred_at: DateTime.t(),
          provider_refs: %{optional(atom()) => String.t()},
          payload: map()
        }
end
