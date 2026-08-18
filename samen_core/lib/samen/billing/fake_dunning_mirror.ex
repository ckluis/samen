defmodule Samen.Billing.FakeDunningMirror do
  @moduledoc """
  The in-memory `Samen.Billing.DunningMirror` test double (T24/B7). Ships in lib
  per the house "test infra ships in lib" precedent (`Samen.RedPath`,
  `Samen.Factory`, `Samen.Billing.FakeMirror`/`FakeInvoiceMirror`/`FakeCheckoutMirror`).

  Proves `Samen.Billing.Dunning`'s routing/idempotency/retry-schedule-advance
  hermetically — no DB, no Ash resources, no vendor credentials.

  ## Lifecycle

      ref = FakeDunningMirror.new()
      # ... drive Samen.Billing.Dunning.reconcile/2 or .recover/2
      FakeDunningMirror.get_case(ref, "in_123")     # the mirrored case row
      FakeDunningMirror.change_count(ref)            # how many write_case/2 calls wrote

  `change_count/1` is the idempotency witness (mirrors `FakeInvoiceMirror.change_count/1`):
  a fixture replayed twice must leave it at 1; a genuinely NEW retry attempt (or the
  recovery close) for the SAME invoice must bump it.
  """

  @behaviour Samen.Billing.DunningMirror

  @doc "Start a fresh in-memory mirror; returns `{:ok, ref}` (the ref is an Agent pid)."
  @spec start() :: {:ok, pid()}
  def start do
    Agent.start_link(fn -> %{cases: %{}, changes: 0} end)
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
      Agent.get(ref, fn %{cases: cases} ->
        case Map.get(cases, provider_invoice_id) do
          nil ->
            %{exists: false, status: nil, provider_subscription_id: nil, last_event_id: nil, watermark: nil}

          row ->
            %{
              exists: true,
              status: Map.get(row, :status),
              provider_subscription_id: Map.get(row, :provider_subscription_id),
              last_event_id: Map.get(row, :last_event_id),
              watermark: Map.get(row, :occurred_at)
            }
        end
      end)

    {:ok, state}
  end

  @impl true
  def write_case(ref, %{provider_invoice_id: invoice_id} = attrs) do
    Agent.update(ref, fn st ->
      existing = Map.get(st.cases, invoice_id, %{})
      row = Map.merge(existing, attrs)
      %{st | cases: Map.put(st.cases, invoice_id, row), changes: st.changes + 1}
    end)

    {:ok, %{provider_invoice_id: invoice_id}}
  end

  @doc "The mirrored dunning-case row for `invoice_id` (or `nil` if never opened)."
  @spec get_case(pid(), String.t()) :: map() | nil
  def get_case(ref, invoice_id), do: Agent.get(ref, &get_in(&1, [:cases, invoice_id]))

  @doc "How many `write_case/2` calls wrote — the idempotency witness."
  @spec change_count(pid()) :: non_neg_integer()
  def change_count(ref), do: Agent.get(ref, & &1.changes)
end
