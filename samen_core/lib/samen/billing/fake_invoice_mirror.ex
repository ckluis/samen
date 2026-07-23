defmodule Samen.Billing.FakeInvoiceMirror do
  @moduledoc """
  The in-memory `Samen.Billing.InvoiceMirror` test double (T22/B4+B6). Ships in lib
  per the house "test infra ships in lib" precedent (`Samen.RedPath`,
  `Samen.Factory`, `Samen.Billing.FakeMirror`/`FakeCheckoutMirror`).

  Proves `Samen.Billing.Invoice.reconcile/2`'s routing + idempotency hermetically —
  no DB, no Ash resources, no vendor credentials. The REAL storage (an actual
  Invoice row) is proven separately against `Samen.Billing.AshInvoiceMirror`.

  `change_count/1` is the idempotency witness (mirrors `FakeMirror.change_count/1`
  / `FakeCheckoutMirror.change_count/1`): a fixture replayed twice must leave it at
  1; a DIFFERENT event for the SAME invoice (e.g. `finalized` then `paid`) must
  bump it (a genuine re-mirror, not a fresh row).
  """

  @behaviour Samen.Billing.InvoiceMirror

  @doc "Start a fresh in-memory mirror; returns `{:ok, ref}` (the ref is an Agent pid)."
  @spec start() :: {:ok, pid()}
  def start do
    Agent.start_link(fn -> %{invoices: %{}, changes: 0} end)
  end

  @doc "Start a fresh mirror, raising on failure; returns the ref directly (test sugar)."
  @spec new() :: pid()
  def new do
    {:ok, ref} = start()
    ref
  end

  @impl true
  def read_state(ref, provider_invoice_id) do
    state =
      Agent.get(ref, fn %{invoices: invoices} ->
        case Map.get(invoices, provider_invoice_id) do
          nil -> %{exists: false, last_event_id: nil}
          row -> %{exists: true, last_event_id: Map.get(row, :last_event_id)}
        end
      end)

    {:ok, state}
  end

  @impl true
  def upsert(ref, %{snapshot: %{provider_invoice_id: invoice_id}} = attrs) do
    row =
      attrs
      |> Map.take([:org_id, :customer_ref, :subscription_ref])
      |> Map.merge(attrs.snapshot)
      |> Map.put(:last_event_id, Map.get(attrs, :event_id))

    created? = not Agent.get(ref, fn %{invoices: invoices} -> Map.has_key?(invoices, invoice_id) end)

    Agent.update(ref, fn st ->
      %{st | invoices: Map.put(st.invoices, invoice_id, row), changes: st.changes + 1}
    end)

    {:ok, %{provider_invoice_id: invoice_id, created: created?}}
  end

  @doc "The mirrored invoice row for `invoice_id` (or `nil` if never mirrored)."
  @spec get_invoice(pid(), String.t()) :: map() | nil
  def get_invoice(ref, invoice_id), do: Agent.get(ref, &get_in(&1, [:invoices, invoice_id]))

  @doc "How many `upsert/2` calls actually wrote (create OR update) — the idempotency witness."
  @spec change_count(pid()) :: non_neg_integer()
  def change_count(ref), do: Agent.get(ref, & &1.changes)
end
