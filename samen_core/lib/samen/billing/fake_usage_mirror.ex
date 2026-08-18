defmodule Samen.Billing.FakeUsageMirror do
  @moduledoc """
  The in-memory `Samen.Billing.UsageMirror` test double (B8; T25). Ships in lib
  per the house "test infra ships in lib" precedent (`Samen.RedPath`,
  `Samen.Factory`, `Samen.Billing.FakeMirror`/`FakeInvoiceMirror`/
  `FakeDunningMirror`/`FakeCheckoutMirror`).

  Proves `Samen.Billing.UsageReporter`'s batching + idempotency-key derivation +
  no-data-loss properties hermetically — no DB, no Ash resources, no vendor
  credentials.

  ## Lifecycle

      ref = FakeUsageMirror.new()
      FakeUsageMirror.seed(ref, %{id: "ur_1", metric: :api_calls, quantity: 42,
                                   period_start: ~U[2026-07-01 00:00:00Z],
                                   period_end: ~U[2026-07-31 23:59:59Z],
                                   subscription_id: "sub_row_1", provider_ref: "si_123"})
      # ... drive Samen.Billing.UsageReporter.report_pending/1
      FakeUsageMirror.get(ref, "ur_1")           # the row, including reported_at
      FakeUsageMirror.mark_count(ref)             # how many mark_reported/3 calls WROTE

  `mark_count/1` is the idempotency witness: a `report_pending/1` re-run against
  an already-reported backlog reads zero pending rows and never calls
  `mark_reported/3` at all, so `mark_count` stays flat — the "reported records are
  NOT re-sent" done-criterion.
  """

  @behaviour Samen.Billing.UsageMirror

  @doc "Start a fresh in-memory mirror; returns `{:ok, ref}` (the ref is an Agent pid)."
  @spec start() :: {:ok, pid()}
  def start do
    Agent.start_link(fn -> %{records: %{}, marks: 0} end)
  end

  @doc "Start a fresh mirror, raising on failure; returns the ref directly (test sugar)."
  @spec new() :: pid()
  def new do
    {:ok, ref} = start()
    ref
  end

  @doc """
  Seed a usage-record row (pending unless `:reported_at` is explicitly given).
  Returns `ref` (chainable).
  """
  @spec seed(pid(), map()) :: pid()
  def seed(ref, %{id: id} = record) do
    row = Map.put_new(record, :reported_at, nil)
    Agent.update(ref, fn st -> %{st | records: Map.put(st.records, id, row)} end)
    ref
  end

  @impl true
  def read_pending(ref, limit) when is_integer(limit) and limit > 0 do
    pending =
      Agent.get(ref, fn %{records: records} -> records end)
      |> Map.values()
      |> Enum.filter(&is_nil(&1.reported_at))
      |> Enum.sort_by(& &1.id)
      |> Enum.take(limit)
      |> Enum.map(
        &Map.take(&1, [
          :id,
          :metric,
          :quantity,
          :period_start,
          :period_end,
          :subscription_id,
          :provider_ref
        ])
      )

    {:ok, pending}
  end

  @impl true
  def mark_reported(ref, ids, %DateTime{} = reported_at) when is_list(ids) do
    count =
      Agent.get_and_update(ref, fn %{records: records, marks: marks} ->
        existing_ids = Enum.filter(ids, &Map.has_key?(records, &1))

        updated_records =
          Enum.reduce(existing_ids, records, fn id, acc ->
            Map.update!(acc, id, &Map.put(&1, :reported_at, reported_at))
          end)

        new_marks = if existing_ids == [], do: marks, else: marks + 1
        {length(existing_ids), %{records: updated_records, marks: new_marks}}
      end)

    {:ok, count}
  end

  @doc "The mirrored row for `id` (or `nil` if never seeded)."
  @spec get(pid(), String.t()) :: map() | nil
  def get(ref, id), do: Agent.get(ref, &get_in(&1, [:records, id]))

  @doc "How many `mark_reported/3` calls actually wrote (skip-if-empty is not counted)."
  @spec mark_count(pid()) :: non_neg_integer()
  def mark_count(ref), do: Agent.get(ref, & &1.marks)

  @doc "All seeded rows (for assertions)."
  @spec all(pid()) :: [map()]
  def all(ref), do: Agent.get(ref, & &1.records) |> Map.values()
end
