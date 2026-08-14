defmodule Samen.Billing.AshInvoiceMirror do
  @moduledoc """
  The REAL `Samen.Billing.InvoiceMirror` implementation (T22/B4+B6): writes onto
  the EXISTING billing Ash `Invoice` resource materialized by
  `Samen.Scopes.Billing` — no new columns beyond the blueprint's own tax/hosted-link
  attributes (`samen_core/lib/samen/scopes/billing/blueprint.ex`'s
  `define_invoice/7`), which this task ships alongside.

  Resource-module-agnostic AND vendor-field-agnostic (INV-4: this file names no
  vendor — the concrete resource modules AND the provider's external-reference
  attribute names are BOTH resolved from the `ref` map, never hardcoded here,
  exactly like `Samen.Billing.AshCheckoutMirror`):

      config :samen_core, :billing_invoice_mirror,
        {Samen.Billing.AshInvoiceMirror,
         %{
           invoice: MyApp.BillingScope.Invoice,
           subscription: MyApp.BillingScope.Subscription,
           customer: MyApp.BillingScope.Customer,
           # The blueprint's provider-ref attribute names — the SAME documented,
           # pre-existing vendor-branded carve-out `AshCheckoutMirror` accepts (see
           # blueprint.ex's moduledoc NOTE); this module never names the vendor
           # itself, only accepts whatever atom the HOST config supplies.
           invoice_ref_attr: :vendor_invoice_id_field,
           subscription_ref_attr: :vendor_subscription_id_field,
           customer_ref_attr: :vendor_customer_id_field
         }}

  ## Writes are framework-system writes (`authorize?: false`)

  Like `Samen.Billing.AshCheckoutMirror`, this is a webhook-triggered background
  write, not a user action — it authorizes itself (there is no tenant actor on a
  webhook request), never bypassing `Samen.Policy.OrgScope` reads by construction
  (every query explicitly filters on the resolved `org_id` once known).

  ## Org resolution — the bootstrapping problem this port solves

  Unlike a `:checkout_completed` event (which carries `metadata.org_id` this
  package itself stamped, ADR-038 §3.1), a bare `invoice.finalized`/`invoice.paid`
  webhook carries NO org reference of its own — ingress happens before org
  attribution (the same "org_id nilable, resolved during processing" posture
  `Samen.Webhook.Event` documents, ADR-038 §5.3). This module resolves org_id by
  looking up the ALREADY-MIRRORED Customer row (required — an Invoice always
  belongs_to a Customer, `allow_nil?: false` on the blueprint) via
  `customer_ref_attr`, an UNSCOPED system read (there is no org to scope by yet —
  exactly the same bootstrapping shape `AshCheckoutMirror.find_or_create_customer/3`
  uses, just read-only here). The Subscription row (if a `subscription_ref` is
  present) is resolved the same way, for the (optional) FK.

  **Known limitation (documented, not silently swallowed):** if the Customer this
  invoice belongs to has not YET been mirrored (e.g. an invoice webhook somehow
  outraces the checkout/customer-creation path), this module refuses with
  `{:error, :customer_not_found}` rather than fabricating a bare customer row with
  guessed data — the caller (the worker) retries/DLQs, and a later retry succeeds
  once the customer mirror has caught up. This is the fail-honest choice over
  inventing a customer.

  ## Idempotency (done-criterion 1)

  `upsert/2` is idempotent by `invoice_ref_attr` (the provider invoice id): a first
  delivery CREATES the row; every subsequent delivery UPDATES the SAME row in
  place (tax fields, hosted links, status, amounts all re-mirrored from the latest
  authoritative snapshot). The `last_event_id` idempotency marker is a dedicated
  blueprint column (NOT the Tier-1 `custom` bag — that engine is a closed-world,
  org-declared field set that rejects any key without a `tnt_field` definition;
  `last_event_id` is a framework-owned attribute, the same shape as the
  blueprint's existing opaque provider-reference column).
  """

  @behaviour Samen.Billing.InvoiceMirror

  @impl true
  def read_state(ref, provider_invoice_id) do
    case find_invoice(ref, provider_invoice_id) do
      {:ok, nil} -> {:ok, %{exists: false, last_event_id: nil}}
      {:ok, row} -> {:ok, %{exists: true, last_event_id: last_event_id(row)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def upsert(ref, %{snapshot: snapshot} = attrs) do
    provider_invoice_id = Map.fetch!(snapshot, :provider_invoice_id)

    with {:ok, customer} <- resolve_customer(ref, attrs),
         {:ok, subscription} <- resolve_subscription(ref, attrs),
         {:ok, existing} <- find_invoice(ref, provider_invoice_id) do
      write(ref, existing, customer, subscription, attrs, snapshot)
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # Reads

  defp find_invoice(ref, provider_invoice_id) do
    invoice_resource = Map.fetch!(ref, :invoice)
    ref_attr = Map.fetch!(ref, :invoice_ref_attr)

    invoice_resource
    |> Ash.Query.filter_input(%{Atom.to_string(ref_attr) => provider_invoice_id})
    |> Ash.Query.ensure_selected([:last_event_id])
    |> Ash.Query.limit(1)
    # authz-scope: webhook-ingest invoice lookup keyed on the unique provider invoice ref
    # (<=1 row); the org comes FROM the resolved row, never from the request
    |> Ash.read_one(authorize?: false)
  end

  defp last_event_id(row), do: row.last_event_id

  # An Invoice always belongs_to a Customer (allow_nil?: false) — REQUIRED. Fails
  # honestly (see moduledoc "Known limitation") rather than inventing a row.
  defp resolve_customer(ref, attrs) do
    with customer_ref when is_binary(customer_ref) and customer_ref != "" <-
           Map.get(attrs, :customer_ref),
         customer_resource when not is_nil(customer_resource) <- Map.get(ref, :customer),
         ref_attr when not is_nil(ref_attr) <- Map.get(ref, :customer_ref_attr),
         {:ok, %{} = customer} <-
           customer_resource
           |> Ash.Query.filter_input(%{Atom.to_string(ref_attr) => customer_ref})
           |> Ash.Query.ensure_selected([:org_id])
           |> Ash.Query.limit(1)
           # authz-scope: webhook-ingest customer resolve keyed on the unique provider customer ref
           # (<=1 row); org_id is selected FROM the matched row for the downstream org checks
           |> Ash.read_one(authorize?: false) do
      {:ok, customer}
    else
      {:ok, nil} -> {:error, :customer_not_found}
      nil -> {:error, :customer_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :customer_not_found}
    end
  end

  # A Subscription reference is OPTIONAL (Invoice.subscription allow_nil?: true —
  # e.g. a one-time invoice with no subscription). Absent/unresolvable ⇒ nil, never
  # an error.
  defp resolve_subscription(ref, attrs) do
    case Map.get(attrs, :subscription_ref) do
      sub_ref when is_binary(sub_ref) and sub_ref != "" ->
        subscription_resource = Map.get(ref, :subscription)
        ref_attr = Map.get(ref, :subscription_ref_attr)

        if is_nil(subscription_resource) or is_nil(ref_attr) do
          {:ok, nil}
        else
          subscription_resource
          |> Ash.Query.filter_input(%{Atom.to_string(ref_attr) => sub_ref})
          |> Ash.Query.limit(1)
          # authz-scope: webhook-ingest subscription resolve keyed on the unique provider subscription ref (<=1 row)
          |> Ash.read_one(authorize?: false)
        end

      _ ->
        {:ok, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Writes

  defp write(ref, nil, customer, subscription, attrs, snapshot) do
    invoice_resource = Map.fetch!(ref, :invoice)
    ref_attr = Map.fetch!(ref, :invoice_ref_attr)

    create_attrs =
      snapshot_attrs(snapshot, attrs)
      |> Map.put(:org_id, customer.org_id)
      |> Map.put(:customer_id, customer.id)
      |> Map.put(:subscription_id, subscription && subscription.id)
      |> Map.put(ref_attr, Map.fetch!(snapshot, :provider_invoice_id))

    invoice_resource
    |> Ash.Changeset.for_create(:create, create_attrs, authorize?: false)
    |> Ash.create()
    |> case do
      {:ok, invoice} -> {:ok, %{invoice_id: invoice.id, created: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(_ref, existing, customer, subscription, attrs, snapshot) do
    update_attrs =
      snapshot_attrs(snapshot, attrs)
      |> Map.put(:customer_id, customer.id)
      |> Map.put(:subscription_id, subscription && subscription.id)

    existing
    |> Ash.Changeset.for_update(:update, update_attrs, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, invoice} -> {:ok, %{invoice_id: invoice.id, created: false}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The mutable fields mirrored verbatim from the authoritative snapshot (§3.4(1) —
  # NEVER trust the event payload for these; NEVER compute tax — the provider is
  # the source of truth). Tax fields carry through `nil`/`[]` as-is when the
  # provider computed no tax — the fail-honest contract done-criterion 3 tests.
  defp snapshot_attrs(snapshot, attrs) do
    %{
      status: Map.get(snapshot, :status),
      amount_due_cents: Map.get(snapshot, :amount_due_cents) || 0,
      amount_paid_cents: Map.get(snapshot, :amount_paid_cents) || 0,
      currency: Map.get(snapshot, :currency) || "USD",
      period_start: Map.get(snapshot, :period_start),
      period_end: Map.get(snapshot, :period_end),
      due_date: Map.get(snapshot, :due_date),
      paid_at: Map.get(snapshot, :paid_at),
      line_items: Map.get(snapshot, :line_items) || [],
      tax_amount_cents: Map.get(snapshot, :tax_amount_cents),
      tax_lines: Map.get(snapshot, :tax_lines) || [],
      hosted_invoice_url: Map.get(snapshot, :hosted_invoice_url),
      hosted_receipt_url: Map.get(snapshot, :hosted_receipt_url),
      last_event_id: Map.get(attrs, :event_id)
    }
  end
end
