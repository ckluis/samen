defmodule Samen.Billing.UsageReporter do
  @moduledoc """
  B8 — metered-usage batching + reporting (T25; ADR-038 §3.1 `report_usage/2` +
  idempotency-key rule; consumer map: "T25 (B8 usage) | §3.1 report_usage +
  idempotency-key rule").

  Vendor-generic (INV-4): this module names no vendor. It reads pending
  `UsageRecord` rows through the host-injected `Samen.Billing.UsageMirror` port
  and reports them through the host-configured `Samen.Billing.Provider` — exactly
  the same "core owns policy, the adapter only translates + transports" split
  every other billing consumer (`Reconciler`, `Checkout`, `Invoice`, `Dunning`)
  follows.

  ## The correctness contract (`report_pending/1`)

    1. **Fail-honest gate FIRST** (ADR-014/ADR-038 §3.2): an unconfigured
       provider is checked BEFORE the mirror is even read — `{:error,
       :not_configured}`, immediately, no batch built, no mirror call made.
       Pending records are untouched; they simply keep accumulating until a host
       configures a provider (done-criterion 3 — "records accumulate, reporter
       returns :not_configured, nothing marked sent").
    2. Reads up to `:limit` (default #{inspect(500)}) pending records
       (`UsageMirror.read_pending/2`, oldest-first). Zero pending rows is a true
       no-op: `{:ok, %{reported: 0}}` — never an error, never a wasted provider
       call.
    3. Builds ONE batch. Each item's idempotency key is DERIVED from the
       `UsageRecord`'s own id (`idempotency_key/1`: `"usage:" <> id`) — stable
       across retries and re-runs, so re-sending the SAME still-pending record
       always carries the SAME key and a compliant provider dedups on it,
       treating a redelivery as a safe no-op rather than double-billing.
    4. Calls `provider.report_usage/2` ONCE for the whole batch — never split,
       never partially dispatched.
    5. `{:ok, _}` from the provider ⇒ `UsageMirror.mark_reported/3` stamps EVERY
       id in the batch, ALL AT ONCE (the port's own all-or-nothing contract).
       Marking only ever follows a provider success for the EXACT batch that was
       marked — there is no window where a row is marked reported without the
       provider having accepted it.
    6. `{:error, reason}` from the provider ⇒ NOTHING is marked. Every record in
       the batch stays pending for the next run — no partial marking, no data
       loss (done-criterion 2). Because idempotency keys are per-record and
       stable (step 3), a retry after a transient provider failure is always
       safe even if the provider partially processed the failed call before
       erroring.

  ## Why "all requests in the batch, or none marked" is safe even for a
  ## per-record vendor call

  A vendor adapter's `report_usage/2` may internally iterate the batch making one
  HTTP call per record (a classic per-subscription-item metered-billing API
  shape). If the adapter's Nth call fails, its own contract is to return
  `{:error, _}` for
  the WHOLE batch (never a partial-success tuple) — this module never marks
  anything on error, so the retry re-sends the ENTIRE batch, including the
  records the adapter already got to before failing. That is safe (not a
  double-bill) specifically because each record's idempotency key is stable
  (step 3): the vendor dedups the ones it already saw.
  """

  alias Samen.Billing.UsageMirror

  @default_limit 500

  @type opts :: [
          provider: module(),
          provider_config: map(),
          usage_mirror: module(),
          usage_mirror_ref: UsageMirror.ref(),
          limit: pos_integer()
        ]

  @type outcome :: {:ok, %{reported: non_neg_integer()}} | {:error, term()}

  @doc """
  Batch-report every currently-pending usage record (bounded by `:limit`) through
  the configured provider. See the moduledoc for the full step-by-step contract.

  Required opts: `:provider` (a `Samen.Billing.Provider` impl), `:usage_mirror`
  (a `Samen.Billing.UsageMirror` impl), `:usage_mirror_ref`. Optional:
  `:provider_config` (default `%{}`), `:limit` (default #{@default_limit}).
  """
  @spec report_pending(opts()) :: outcome()
  def report_pending(opts) do
    provider = Keyword.fetch!(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config, %{})

    if provider.configured?(provider_config) do
      do_report(provider, provider_config, opts)
    else
      {:error, :not_configured}
    end
  end

  @doc "The idempotency key for a given `UsageRecord` id — derived, stable, reused on retry."
  @spec idempotency_key(String.t()) :: String.t()
  def idempotency_key(usage_record_id) when is_binary(usage_record_id) do
    "usage:" <> usage_record_id
  end

  # ---------------------------------------------------------------------------

  defp do_report(provider, provider_config, opts) do
    usage_mirror = Keyword.fetch!(opts, :usage_mirror)
    usage_mirror_ref = Keyword.fetch!(opts, :usage_mirror_ref)
    limit = Keyword.get(opts, :limit, @default_limit)

    case usage_mirror.read_pending(usage_mirror_ref, limit) do
      {:ok, []} ->
        {:ok, %{reported: 0}}

      {:ok, records} ->
        report_batch(provider, provider_config, usage_mirror, usage_mirror_ref, records)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp report_batch(provider, provider_config, usage_mirror, usage_mirror_ref, records) do
    batch = Enum.map(records, &to_batch_item/1)

    case provider.report_usage(batch, provider_config) do
      {:ok, _result} ->
        ids = Enum.map(records, & &1.id)
        reported_at = DateTime.utc_now()

        case usage_mirror.mark_reported(usage_mirror_ref, ids, reported_at) do
          {:ok, count} -> {:ok, %{reported: count}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        # NOTHING marked — every record in `records` stays pending (no
        # data-loss property, done-criterion 2).
        {:error, reason}
    end
  end

  defp to_batch_item(record) do
    %{
      usage_record_id: record.id,
      idempotency_key: idempotency_key(record.id),
      metric: Map.get(record, :metric),
      quantity: Map.get(record, :quantity),
      timestamp: Map.get(record, :period_end) || Map.get(record, :period_start),
      subscription_id: Map.get(record, :subscription_id),
      provider_ref: Map.get(record, :provider_ref)
    }
  end
end
