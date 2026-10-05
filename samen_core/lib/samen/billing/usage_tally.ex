defmodule Samen.Billing.UsageTally do
  @moduledoc """
  The **derived usage tally** (T163; ADR-051 P2). A host's `Usage` row is the
  per-`(org, subscription, metric, period)` total of the insert-only `UsageEvent`
  ledger, and `rebuild/5` is the only thing that writes one.

  ## Recompute, never increment

  `rebuild/5` sums the ledger's quantities for the period and UPSERTS that sum as the
  tally's `quantity`, replacing whatever was there. It never adds to the previous
  value, so a rebuild run twice, run after a crash, or run concurrently with a late
  capture always converges on the ledger's own total. The ledger is insert-only, so
  the recomputed total only ever grows.

  The period is half-open, `[period_start, period_end)`: an event at exactly
  `period_end` belongs to the next period, so adjacent periods never double-count.

  Events captured with no `subscription_id` are not tallied (a tally belongs to a
  subscription). They stay in the ledger, where a quota read can still count them.

  ## Reporting is by delta

  The tally also carries `reported_quantity`, the part of `quantity` the provider
  has already been sent. A rebuild never touches it. `Samen.Billing.UsageReporter`
  reports only `quantity - reported_quantity`, because the provider's metered-usage
  call increments (the reference adapter posts an increment action). `:mark_reported`
  then moves `reported_quantity` forward to exactly the value that was sent, never
  past `quantity` and never backwards (`Samen.Billing.UsageTally.ForwardOnly`).
  """

  require Ash.Query

  alias Samen.Billing.UsageTally.Guard

  @metrics [:api_calls, :seats, :storage_gb, :events, :messages, :custom_metric]

  @doc """
  Recompute the tallies for one `(org_id, subscription_id)` over
  `[period_start, period_end)` from the ledger.

  Options: `:usage` (the host's `Usage` resource) and `:usage_event` (its
  `UsageEvent` ledger), both required. Returns `{:ok, %{metric => quantity}}` for
  every metric that has at least one event in the period; metrics with none are
  left untouched (no zero rows are minted).
  """
  @spec rebuild(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, %{atom() => non_neg_integer()}} | {:error, term()}
  def rebuild(org_id, subscription_id, %DateTime{} = period_start, %DateTime{} = period_end, opts)
      when is_binary(org_id) and is_binary(subscription_id) do
    usage = Keyword.fetch!(opts, :usage)
    usage_event = Keyword.fetch!(opts, :usage_event)

    if DateTime.compare(period_start, period_end) == :lt do
      Enum.reduce_while(@metrics, {:ok, %{}}, fn metric, {:ok, acc} ->
        case ledger_sum(usage_event, org_id, subscription_id, metric, period_start, period_end) do
          {:ok, nil} ->
            {:cont, {:ok, acc}}

          {:ok, total} ->
            case upsert(usage, org_id, subscription_id, metric, total, period_start, period_end) do
              :ok -> {:cont, {:ok, Map.put(acc, metric, total)}}
              {:error, error} -> {:halt, {:error, error}}
            end

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
    else
      {:error, :empty_period}
    end
  end

  defp ledger_sum(usage_event, org_id, subscription_id, metric, period_start, period_end) do
    usage_event
    |> Ash.Query.filter(
      org_id == ^org_id and subscription_id == ^subscription_id and metric == ^metric and
        occurred_at >= ^period_start and occurred_at < ^period_end
    )
    |> Ash.sum(:quantity, authorize?: false)
  end

  defp upsert(usage, org_id, subscription_id, metric, total, period_start, period_end) do
    usage
    |> Ash.Changeset.for_create(
      :rebuild_tally,
      %{
        org_id: org_id,
        subscription_id: subscription_id,
        metric: metric,
        quantity: total,
        period_start: period_start,
        period_end: period_end
      },
      upsert?: true,
      upsert_identity: :unique_tally,
      # REPLACE the total (recompute), never add to it. `reported_quantity` is not
      # listed, so a rebuild never disturbs what has already been reported.
      upsert_fields: [:quantity, :period_end],
      authorize?: false
    )
    |> Ash.Changeset.set_context(%{private: %{Guard.marker_key() => true}})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _tally} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
