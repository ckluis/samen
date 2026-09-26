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
    3. Builds ONE batch of DELTAS (T163; ADR-051 P2). A record is pending while
       `quantity > reported_quantity`; its batch item carries only the unreported
       part, `quantity - reported_quantity`, because the provider's metered-usage
       call INCREMENTS (the reference adapter posts an increment action): sending a
       grown total again would bill the already-reported part twice. Each item's
       idempotency key is DERIVED from the delta it carries
       (`idempotency_key/3`: `"usage:<id>:<from>-<to>"`) — stable across retries,
       so re-sending the SAME delta always carries the SAME key and a compliant
       provider dedups it; and a key never names two different quantities (a
       provider may reject a reused key with different parameters).
    4. Calls `provider.report_usage/2` ONCE for the whole batch — never split,
       never partially dispatched.
    5. `{:ok, _}` from the provider ⇒ `UsageMirror.mark_reported/3` stamps EVERY
       record in the batch, ALL AT ONCE (the port's own all-or-nothing contract),
       moving each `reported_quantity` to exactly the `to` value that was SENT —
       not to the record's current quantity, which a rebuild may have grown in the
       meantime (that later growth is the next run's delta).
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

  @doc """
  The idempotency key for reporting the delta `from → to` of one `UsageRecord`:
  derived, stable across retries, and unique per delta (ADR-051 P2).
  """
  @spec idempotency_key(String.t(), non_neg_integer(), pos_integer()) :: String.t()
  def idempotency_key(usage_record_id, from, to)
      when is_binary(usage_record_id) and is_integer(from) and is_integer(to) and from < to do
    "usage:#{usage_record_id}:#{from}-#{to}"
  end

  # ---------------------------------------------------------------------------

  defp do_report(provider, provider_config, opts) do
    usage_mirror = Keyword.fetch!(opts, :usage_mirror)
    usage_mirror_ref = Keyword.fetch!(opts, :usage_mirror_ref)
    limit = Keyword.get(opts, :limit, @default_limit)

    case usage_mirror.read_pending(usage_mirror_ref, limit) do
      {:ok, records} ->
        # Defensive: a record with no positive delta is not pending, whatever the
        # mirror returned. It is neither sent nor marked.
        case Enum.filter(records, &(delta(&1) > 0)) do
          [] -> {:ok, %{reported: 0}}
          pending -> report_batch(provider, provider_config, usage_mirror, usage_mirror_ref, pending)
        end


      {:error, reason} ->
        {:error, reason}
    end
  end

  defp report_batch(provider, provider_config, usage_mirror, usage_mirror_ref, records) do
    batch = Enum.map(records, &to_batch_item/1)

    case provider.report_usage(batch, provider_config) do
      {:ok, _result} ->
        # Mark each record at exactly the quantity that was SENT (its `to`).
        marks = Enum.map(records, &{&1.id, Map.get(&1, :quantity)})
        reported_at = DateTime.utc_now()

        case usage_mirror.mark_reported(usage_mirror_ref, marks, reported_at) do
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
    from = reported_quantity(record)
    to = Map.get(record, :quantity)

    %{
      usage_record_id: record.id,
      idempotency_key: idempotency_key(record.id, from, to),
      metric: Map.get(record, :metric),
      # The DELTA: the provider increments, so only the unreported part is sent.
      quantity: to - from,
      timestamp: Map.get(record, :period_end) || Map.get(record, :period_start),
      subscription_id: Map.get(record, :subscription_id),
      provider_ref: Map.get(record, :provider_ref)
    }
  end

  defp reported_quantity(record), do: Map.get(record, :reported_quantity) || 0

  defp delta(record) do
    case Map.get(record, :quantity) do
      q when is_integer(q) -> q - reported_quantity(record)
      _ -> 0
    end
  end
end
