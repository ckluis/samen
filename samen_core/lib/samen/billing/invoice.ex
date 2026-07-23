defmodule Samen.Billing.Invoice do
  @moduledoc """
  The vendor-generic B4+B6 invoice-mirror logic (T22; ADR-038 §3.5 "the Invoice
  mirror gains tax fields + hosted invoice/receipt URLs", §3.4 convergence model
  applied to the invoice object). `samen_core` owns this logic (INV-4) — the vendor
  adapter package only translates + transports (`fetch_object(:invoice, …)`); it
  never decides org-scoping or what the mirror row looks like.

  `Samen.Billing.WebhookDispatch` (the shared T19 seam's billing consumer) routes
  `:invoice_finalized`/`:invoice_paid` HERE — never to `Samen.Billing.Reconciler`
  (subscription lifecycle, T21) or `Samen.Billing.Checkout` (checkout activation,
  T20). `:invoice_payment_failed` is explicitly NOT handled here — it is T24
  dunning's exclusive kind (ADR-038 §3.5 B7 rule: "driven exclusively from
  `:invoice_payment_failed` events"); this module treats it as any other unhandled
  kind (`{:ok, :ignored}`), leaving it clean for T24 to wire.

  ## Reconciliation (`reconcile/2`)

  1. No `object_id` ref (the invoice's own provider id — the webhook object IS the
     invoice) ⇒ `{:ok, :ignored}` — defensive; `WebhookDispatch` only ever routes
     invoice kinds here.
  2. Idempotency short-circuit (coherent with T19's ingress replay index, NOT a
     second independent guard): `invoice_mirror.read_state/2` — an EXACT replay of
     the event that already produced the current row's state (`last_event_id`
     match) is `{:ok, :duplicate}`, skipping a wasted authoritative re-fetch. T19's
     `{provider, event_id}` unique index already makes a duplicate DELIVERY a no-op
     before this module is ever called; this covers the DLQ-replay / at-least-once
     retry re-dispatch case, exactly like `Samen.Billing.Reconciler`'s
     `last_event_id` check.
  3. Authoritative re-fetch (ADR-038 §3.4(1) — never trust the webhook payload for
     state, and NEVER compute tax ourselves — the provider is the source of truth
     for both amounts and tax): `provider.fetch_object(:invoice, invoice_id,
     provider_config)`.
  4. `invoice_mirror.upsert/2` writes the mirror row, keyed on `provider_invoice_id`
     — creates on first delivery, UPDATES THE SAME ROW on every subsequent delivery
     (done-criterion 1's "updates re-mirror idempotently": whichever kind arrives —
     `:invoice_finalized` then `:invoice_paid`, or either replayed, or delivered
     out of order — the mirror converges to the CURRENT authoritative snapshot,
     never a duplicate row). There is no out-of-order watermark hazard the way
     subscription sync has: every invoice event triggers the same re-fetch of the
     same object, so the result is always "whatever is true now," regardless of
     which kind/order triggered it.

  ## Fail-honest tax mirroring (ADR-014 shape applied to tax; done-criterion 3)

  Tax fields (`tax_amount_cents`, `tax_lines`) are mirrored VERBATIM from the
  adapter's snapshot. When the provider computed no tax for an invoice (automatic
  tax not enabled, or not applicable), the snapshot carries `tax_amount_cents: nil`
  and `tax_lines: []` — this module NEVER substitutes a `0`, never invents a line.
  The mirror row (and every UI reading it) must render that absence honestly (see
  the tax-enablement guide under `docs/guides/`).
  """

  alias Samen.Billing.ProviderEvent

  @invoice_kinds ~w(invoice_finalized invoice_paid)a

  @type reconcile_opts :: [
          provider: module(),
          provider_config: map(),
          invoice_mirror: module(),
          invoice_mirror_ref: term()
        ]

  @type outcome ::
          {:ok, :applied, map()}
          | {:ok, :duplicate}
          | {:ok, :ignored}
          | {:error, term()}

  @doc """
  Reconcile one normalized `Samen.Billing.ProviderEvent` of an invoice kind against
  the `Samen.Billing.InvoiceMirror`. See the moduledoc for the full per-step
  contract. Anything outside `:invoice_finalized`/`:invoice_paid` is `{:ok,
  :ignored}` (defensive — `WebhookDispatch` only ever routes invoice kinds here).
  """
  @spec reconcile(ProviderEvent.t(), reconcile_opts()) :: outcome()
  def reconcile(%ProviderEvent{kind: kind} = event, opts) when kind in @invoice_kinds do
    reconcile_invoice(event, opts)
  end

  def reconcile(%ProviderEvent{}, _opts), do: {:ok, :ignored}

  # ---------------------------------------------------------------------------

  defp reconcile_invoice(%ProviderEvent{provider_refs: refs} = event, opts) do
    refs = refs || %{}

    case Map.get(refs, :object_id) do
      nil -> {:ok, :ignored}
      invoice_id -> do_reconcile(invoice_id, refs, event, opts)
    end
  end

  defp do_reconcile(invoice_id, refs, event, opts) do
    mirror = Keyword.fetch!(opts, :invoice_mirror)
    mirror_ref = Keyword.fetch!(opts, :invoice_mirror_ref)
    provider = Keyword.fetch!(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config, %{})

    with {:ok, state} <- mirror.read_state(mirror_ref, invoice_id),
         :proceed <- duplicate_gate(state, event.event_id),
         {:ok, snapshot} <- provider.fetch_object(:invoice, invoice_id, provider_config) do
      attrs = %{
        org_id: Map.get(refs, :org_id),
        customer_ref: Map.get(refs, :customer_id) || Map.get(snapshot, :provider_customer_id),
        subscription_ref: Map.get(refs, :subscription_id) || Map.get(snapshot, :provider_subscription_id),
        event_id: event.event_id,
        snapshot: Map.put(snapshot, :provider_invoice_id, invoice_id)
      }

      case mirror.upsert(mirror_ref, attrs) do
        {:ok, applied} -> {:ok, :applied, applied}
        {:error, reason} -> {:error, reason}
      end
    else
      {:short, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  # The idempotency short-circuit — an EXACT replay of the event that already
  # produced the current row is a no-op. Anything else (first delivery, or a
  # DIFFERENT event for an already-mirrored invoice) proceeds to the authoritative
  # re-fetch; there is no watermark/staleness check here (see moduledoc: every
  # invoice event re-fetches the SAME object, so out-of-order delivery converges to
  # current truth without a clobber hazard).
  defp duplicate_gate(%{exists: true, last_event_id: last_id}, event_id)
       when not is_nil(last_id) and last_id == event_id do
    {:short, {:ok, :duplicate}}
  end

  defp duplicate_gate(_state, _event_id), do: :proceed
end
