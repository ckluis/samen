defmodule Samen.Delivery.WebhookDispatch do
  @moduledoc """
  The delivery (C4) consumer of the T19 webhook-dispatch seam (ADR-038 §5.2
  step 5; T30). Wired via:

      config :samen_core, :webhook_dispatch, Samen.Delivery.WebhookDispatch

  ## Composes with the billing consumer (T21) — one config slot, two domains

  `Samen.Webhook.Dispatch` reads ONE module from `:webhook_dispatch`
  (`samen_core/lib/samen/webhook/dispatch.ex`) — it was not extended to accept a
  list, and this task does not own that seam. Rather than touch the T19-shipped
  contract, this module is a DROP-IN SUPERSET of `Samen.Billing.WebhookDispatch`:
  it handles `domain: "delivery"` itself and falls through everything else
  (`domain: "billing"`, `"unknown"`) to `Samen.Billing.WebhookDispatch.dispatch/2`
  unchanged. A host wires `Samen.Delivery.WebhookDispatch` as its ONE
  `:webhook_dispatch` module and gets BOTH domains; wiring
  `Samen.Billing.WebhookDispatch` alone (the pre-T30 state) still works exactly
  as before (delivery envelopes silently acked, per its own moduledoc).

  ## The stored envelope -> ProviderEvent reconstruction

  Same shape as `Samen.Billing.WebhookDispatch`: the ingress persists the
  REDACTED payload + normalized `kind`/`occurred_at`/`event_id`
  (`Samen.Webhook.Event`, T19 §5.3) — NOT `provider_message_id` as a first-class
  column, so it is recovered from the redacted payload's `MessageID` field
  (the reference adapter's key; the generic `"provider_message_id"`/
  `"MessageID"` fallback keeps this vendor-generic per INV-4 — real adapters
  may differ, a future adapter's dispatch can extend the fallback key list).

  ## Result mapping (the DLQ contract, §5.2 step 5)

  `Samen.Delivery.Deliverability.handle_event/2` outcomes map directly:
  `:ok` -> `:ok` (recorded, or an honest no-op); `{:error, reason}` -> retry,
  then DLQ on exhaustion (§5.5) — matched events are idempotent
  (`EmailEvent.record/2`'s unique index), so a retry/DLQ-replay is always safe.
  """

  @behaviour Samen.Webhook.Dispatch

  alias Samen.Delivery.{Deliverability, ProviderEvent}
  alias Samen.Webhook.Event

  @impl true
  def dispatch(%Event{domain: "delivery"} = event, opts) do
    event
    |> to_provider_event()
    |> Deliverability.handle_event(opts)
  end

  # Everything else (billing, unknown) is NOT this consumer's concern — fall
  # through to the billing consumer unchanged (see moduledoc "Composes with...").
  def dispatch(%Event{} = event, opts), do: Samen.Billing.WebhookDispatch.dispatch(event, opts)

  defp to_provider_event(%Event{} = event) do
    payload = event.payload || %{}

    %ProviderEvent{
      provider: safe_atom(event.provider),
      event_id: event.event_id,
      kind: kind_atom(event.kind),
      provider_message_id: payload["MessageID"] || payload["provider_message_id"],
      occurred_at: event.occurred_at,
      payload: payload
    }
  end

  # Map the stored kind string to the bounded ProviderEvent kind atom; anything
  # unknown (or unparseable) is `:unhandled` (Deliverability no-ops it).
  defp kind_atom(kind) when is_binary(kind) do
    atom = safe_atom(kind)
    if atom in ~w(delivered bounce complaint open click)a, do: atom, else: :unhandled
  end

  defp kind_atom(_), do: :unhandled

  defp safe_atom(value) when is_atom(value), do: value

  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unhandled
  end

  defp safe_atom(_), do: :unhandled
end
