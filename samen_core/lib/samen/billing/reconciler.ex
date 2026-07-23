defmodule Samen.Billing.Reconciler do
  @moduledoc """
  The vendor-generic subscription-lifecycle convergence engine (B3; T21). Implements
  the ADR-038 §3.4 **fetch-on-event** model: a verified webhook event names a provider
  object; the reconciler re-fetches the AUTHORITATIVE snapshot via the provider's
  `fetch_object/3` and upserts the host mirror through the `Samen.Billing.Mirror` port
  — **never from the event payload** (§3.4(1)).

  `samen_core` owns state + convergence; the adapter only translates + transports
  (ADR-038 §2). This module names no vendor (INV-4); the provider specifics live in
  the adapter package behind `fetch_object/3`, and the storage specifics behind the mirror
  port.

  ## The two hazards this exists to get right (design-constraint bugs live here)

  ### 1. Idempotency (done-criterion 2)

  There is ONE coherent idempotency story, reconciled with T19's ingress replay index
  (ADR-038 §3.4(2)):

    * At ingress, the `{provider, event_id}` unique index makes a duplicate DELIVERY a
      DB no-op — the event is never even re-dispatched (T19).
    * Here, if it IS re-dispatched (an operator DLQ replay, an at-least-once worker
      retry), the mirror's `last_event_id` bookkeeping makes re-applying the SAME event
      a no-op (`{:ok, :duplicate}`). The upsert is idempotent by
      `provider_subscription_id` regardless.

  ### 2. Out-of-order convergence (done-criterion 3)

  The guard is the **event's own monotonic marker** (`occurred_at` — the provider's
  event timestamp; e.g. the provider's `created` marker), compared against the mirror row's stored
  watermark. A strictly-OLDER event is DISCARDED (`{:ok, :stale}`) — it never clobbers
  newer state. This is what makes `(updated, created)` delivered in reverse converge to
  the SAME terminal state as in-order: the late `created` is older than the applied
  `updated`, so it is dropped. A naive last-write-wins (re-applying the stale event's
  older snapshot) is the bug the reconciler + its sabotage twin refute.

  ## Proration (done-criterion 1)

  Proration is provider-computed. The reconciler MIRRORS whatever
  `proration_amount_cents` the adapter's snapshot carries onto the mirror — it never
  recomputes proration math (ADR-038 §3.4(4)). The lifecycle test asserts the mirrored
  value equals the fixture EXACTLY.

  ## Entitlement lifecycle (done-criterion 1 — the T24/T23 seam)

  A cancel (a `:subscription_deleted` event, a `:cancelled` terminal status, or a
  scheduled `cancel_at`) ends entitlement AT PERIOD END (grace), not immediately: the
  reconciler passes `{:grace_until, period_end}` to the mirror. An active subscription
  passes `:active`. This is the clean seam T24 dunning builds the grace-period policy
  on; T21 leaves the `:invoice_payment_failed` kind explicitly UNHANDLED here
  (`{:ok, :deferred_dunning}`) so dunning wires in without touching lifecycle sync.

  ## Scope

  This engine handles ONLY the subscription lifecycle kinds. Checkout (`T20`), invoices
  (`T22`), payment methods (`T23`), and usage (`T25`) events are `{:ok, :ignored}` here
  — their owners consume the same dispatch seam.
  """

  alias Samen.Billing.ProviderEvent

  @subscription_kinds [:subscription_created, :subscription_updated, :subscription_deleted]
  @grace_statuses [:cancelled]

  @type opts :: [
          mirror: module(),
          mirror_ref: term(),
          provider: module(),
          provider_config: map()
        ]

  @type outcome ::
          {:ok, :applied, map()}
          | {:ok, :duplicate}
          | {:ok, :stale}
          | {:ok, :ignored}
          | {:ok, :deferred_dunning}
          | {:error, term()}

  @doc """
  Reconcile one normalized `Samen.Billing.ProviderEvent` against the mirror.

  `opts` (required): `:mirror` (a `Samen.Billing.Mirror` impl), `:mirror_ref` (its
  opaque handle), `:provider` (a `Samen.Billing.Provider` impl), `:provider_config`
  (the provider's config map — carries creds and, in hermetic tests, the injected
  transport that serves cassettes).
  """
  @spec reconcile(ProviderEvent.t(), opts()) :: outcome()
  def reconcile(%ProviderEvent{kind: kind} = event, opts) do
    cond do
      kind in @subscription_kinds -> reconcile_subscription(event, opts)
      # The clean T24 hook: dunning is driven off payment-failure events, NOT here.
      kind == :invoice_payment_failed -> {:ok, :deferred_dunning}
      # Every other kind belongs to a sibling task (checkout/invoice/payment-method/usage).
      true -> {:ok, :ignored}
    end
  end

  # ---------------------------------------------------------------------------

  defp reconcile_subscription(%ProviderEvent{} = event, opts) do
    mirror = Keyword.fetch!(opts, :mirror)
    ref = Keyword.fetch!(opts, :mirror_ref)
    provider = Keyword.fetch!(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config, %{})

    case subscription_ref(event) do
      nil ->
        {:error, :missing_subscription_ref}

      sub_id ->
        with {:ok, state} <- mirror.read_state(ref, sub_id),
             :proceed <- gate(state, event) do
          apply_event(event, sub_id, %{
            mirror: mirror,
            ref: ref,
            provider: provider,
            provider_config: provider_config
          })
        else
          {:short, outcome} -> outcome
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The idempotency + out-of-order gate. Returns `:proceed` or a `{:short, outcome}`.
  defp gate(%{last_event_id: last_id}, %ProviderEvent{event_id: event_id})
       when not is_nil(last_id) and last_id == event_id do
    # Exact replay of the event that produced the current state — idempotent no-op.
    {:short, {:ok, :duplicate}}
  end

  defp gate(%{exists: true, watermark: %DateTime{} = watermark}, %ProviderEvent{occurred_at: occurred_at}) do
    # Out-of-order guard: a strictly-older event never clobbers newer applied state.
    case DateTime.compare(occurred_at, watermark) do
      :lt -> {:short, {:ok, :stale}}
      _ -> :proceed
    end
  end

  defp gate(_state, _event), do: :proceed

  defp apply_event(%ProviderEvent{} = event, sub_id, %{
         mirror: mirror,
         ref: ref,
         provider: provider,
         provider_config: provider_config
       }) do
    # Fetch the AUTHORITATIVE object (§3.4(1)) — never trust the event payload for state.
    case provider.fetch_object(:subscription, sub_id, provider_config) do
      {:ok, snapshot} when is_map(snapshot) ->
        snapshot =
          snapshot
          |> Map.put(:provider_subscription_id, sub_id)
          |> Map.put(:provider_event_at, event.occurred_at)
          |> Map.put(:last_event_id, event.event_id)

        action = entitlement_action(event.kind, snapshot)

        case mirror.write_snapshot(ref, snapshot, action) do
          {:ok, applied} -> {:ok, :applied, applied}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        # Fetch failed (transient / not_found) — surface it; the worker retries / DLQs.
        {:error, {:fetch_failed, reason}}
    end
  end

  # Derive the entitlement transition from the terminal subscription state.
  defp entitlement_action(kind, snapshot) do
    status = Map.get(snapshot, :status)
    cancel_at = Map.get(snapshot, :cancel_at)

    cond do
      kind == :subscription_deleted or status in @grace_statuses or not is_nil(cancel_at) ->
        # Grace: entitlement ends at period end (or the scheduled cancel boundary).
        {:grace_until, grace_boundary(snapshot)}

      status in [:active, :trialing] ->
        :active

      true ->
        :none
    end
  end

  # The grace boundary is the scheduled cancel time when set, else the current period end.
  defp grace_boundary(snapshot) do
    Map.get(snapshot, :cancel_at) || Map.get(snapshot, :current_period_end)
  end

  # The subscription's provider id: prefer the explicit subscription ref, fall back to
  # the event's primary object id (a `customer.subscription.*` event's object IS the
  # subscription, so `object_id` is the subscription id).
  defp subscription_ref(%ProviderEvent{provider_refs: refs}) when is_map(refs) do
    Map.get(refs, :subscription_id) || Map.get(refs, :object_id)
  end

  defp subscription_ref(_), do: nil
end
