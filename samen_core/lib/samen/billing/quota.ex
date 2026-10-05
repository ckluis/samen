defmodule Samen.Billing.Quota do
  @moduledoc """
  The **usage quota check** (T163; ADR-051 §2.6, P3). `within_limit?/4` answers
  "would using `quantity` more of `metric` keep this org within its limit for the
  current billing period?".

  ## A read, never a lock

  It never blocks capture. `Samen.Billing.Meter.record/3` records usage that
  happened whatever the quota says, and what to do when an org is over its limit is
  the caller's policy decision. The check takes no lock, so two concurrent callers
  can both see room for the last unit. That is accepted: the ledger still records
  both, and the bill follows the ledger.

  ## Where the numbers come from

    * **The limit** is the `limit` on the org's active `Entitlement` row for the
      metric (`granted`, not expired), MIRRORED from the provider's plan, never
      computed (ADR-051 D2 option (a)). `nil` means unlimited.
    * **The period** is that row's subscription's `[current_period_start,
      current_period_end)`, half-open like the tally's.
    * **The usage** is summed from the insert-only `UsageEvent` ledger over that
      period: the subscription's events plus the org's unsubscribed ones (captured
      with no `subscription_id`, which a tally never holds). The derived `Usage`
      tally equals that same sum after a rebuild, but it is only rebuilt at
      rollover and on demand, so mid-period it can lag the ledger. Reading the
      ledger means a quota never under-counts because a rebuild has not run yet.

  ## Fail closed (R6)

  The check fails closed: anything that leaves the limit or the period unknown
  is `{:error, reason}`, never `{:ok, true}`.

    * `:no_limit` — no active entitlement row carries this metric. An absent limit
      is not an unlimited one; unlimited is an explicit `nil` limit.
    * `:ambiguous_limit` — more than one active row carries it (several
      subscriptions). Pass `subscription_id:` to pick one.
    * `:no_current_period` — the subscription is missing, has no period, or the
      period has ended (the mirror has not seen the renewal yet).
    * `:invalid_org_id`, `:invalid_metric`, `:invalid_quantity`, or a read error.

      Samen.Billing.Quota.within_limit?(org_id, :api_calls, 1,
        entitlement: MyApp.Billing.Entitlement,
        subscription: MyApp.Billing.Subscription,
        usage_event: MyApp.Billing.UsageEvent)
      #=> {:ok, true}
  """

  require Ash.Query

  @metrics [:api_calls, :seats, :storage_gb, :events, :messages, :custom_metric]

  @doc """
  Would using `quantity` (`0` asks "am I within it now?") more of `metric` keep
  `org_id` within its limit for the current period?

  Options: `:entitlement`, `:subscription` and `:usage_event`, the host's resources,
  all required; `:subscription_id` to pick one subscription's limit; `:at`, the
  instant to check at (default now).

  Returns `{:ok, true}` when `used + quantity <= limit` or the limit is `nil`,
  `{:ok, false}` when it would go over, and `{:error, reason}` when the limit or the
  period cannot be read (see the moduledoc). Never `{:ok, true}` on an error.
  """
  @spec within_limit?(Ecto.UUID.t(), atom(), non_neg_integer(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def within_limit?(org_id, metric, quantity, opts) when is_list(opts) do
    with {:ok, org_id} <- cast_org_id(org_id),
         :ok <- check_metric(metric),
         :ok <- check_quantity(quantity),
         {:ok, entitlement} <- fetch_limit_row(org_id, metric, opts),
         {:ok, within?} <- check_limit(org_id, metric, quantity, entitlement, opts) do
      {:ok, within?}
    else
      # Every unreadable limit or period lands here, and stays an error (R6).
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # nil is an explicit "unlimited" mirrored from the plan, not a missing limit.
  defp check_limit(_org_id, _metric, _quantity, %{limit: nil}, _opts), do: {:ok, true}

  defp check_limit(org_id, metric, quantity, %{limit: limit} = entitlement, opts) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    with {:ok, period_start, period_end} <- current_period(entitlement, at, opts),
         {:ok, used} <- used(org_id, metric, entitlement.subscription_id, period_start, period_end, opts) do
      {:ok, used + quantity <= limit}
    end
  end

  defp fetch_limit_row(org_id, metric, opts) do
    resource = Keyword.fetch!(opts, :entitlement)
    now = Keyword.get(opts, :at, DateTime.utc_now())

    query =
      Ash.Query.filter(
        resource,
        org_id == ^org_id and metric == ^metric and granted == true and
          (is_nil(expires_at) or expires_at > ^now)
      )

    query =
      case Keyword.get(opts, :subscription_id) do
        nil -> query
        subscription_id -> Ash.Query.filter(query, subscription_id == ^subscription_id)
      end

    case Ash.read(Ash.Query.limit(query, 2), authorize?: false) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :no_limit}
      {:ok, [_, _]} -> {:error, :ambiguous_limit}
      {:error, error} -> {:error, error}
    end
  end

  defp current_period(%{subscription_id: nil}, _at, _opts), do: {:error, :no_current_period}

  defp current_period(entitlement, at, opts) do
    resource = Keyword.fetch!(opts, :subscription)

    case Ash.get(resource, entitlement.subscription_id, authorize?: false) do
      {:ok, %{current_period_start: %DateTime{} = period_start, current_period_end: %DateTime{} = period_end}} ->
        if DateTime.compare(period_start, at) != :gt and DateTime.compare(at, period_end) == :lt do
          {:ok, period_start, period_end}
        else
          {:error, :no_current_period}
        end

      {:ok, _no_period} ->
        {:error, :no_current_period}

      {:error, _not_found} ->
        {:error, :no_current_period}
    end
  end

  defp used(org_id, metric, subscription_id, period_start, period_end, opts) do
    opts
    |> Keyword.fetch!(:usage_event)
    |> Ash.Query.filter(
      org_id == ^org_id and metric == ^metric and
        (subscription_id == ^subscription_id or is_nil(subscription_id)) and
        occurred_at >= ^period_start and occurred_at < ^period_end
    )
    |> Ash.sum(:quantity, authorize?: false)
    |> case do
      {:ok, nil} -> {:ok, 0}
      {:ok, total} -> {:ok, total}
      {:error, error} -> {:error, error}
    end
  end

  defp cast_org_id(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_org_id}
    end
  end

  defp check_metric(metric) when metric in @metrics, do: :ok
  defp check_metric(_metric), do: {:error, :invalid_metric}

  defp check_quantity(quantity) when is_integer(quantity) and quantity >= 0, do: :ok
  defp check_quantity(_quantity), do: {:error, :invalid_quantity}
end
