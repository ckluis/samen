defmodule Samen.Billing.Dunning do
  @moduledoc """
  The vendor-generic B7 dunning logic (T24; ADR-038 §3.5 "B7 dunning (T24):
  driven exclusively from `:invoice_payment_failed` normalized events — never
  from polling, never simulated. Retry schedule is mirrored provider truth;
  the grace-period entitlement policy is core logic on the mirror").

  `samen_core` owns this logic (INV-4) — the vendor adapter package only
  translates + transports (`fetch_object(:invoice, …)`); it never decides
  org-scoping, the grace boundary, or what the mirror row looks like.

  `Samen.Billing.WebhookDispatch` (the shared T19 seam's billing consumer)
  wires THIS module onto the clean hook `Samen.Billing.Reconciler` already
  leaves for `:invoice_payment_failed` (`{:ok, :deferred_dunning}`) — the
  subscription-lifecycle reconciler is untouched by this task. Recovery
  (`recover/2`) is wired onto the SIBLING `:invoice_paid` kind (already routed
  to `Samen.Billing.Invoice`, T22) as an ADDITIONAL, best-effort consumer —
  Dunning never re-fetches or re-decides invoice state for recovery; it trusts
  that `Samen.Billing.Invoice` already reconciled the authoritative "paid" fact
  and merely closes ITS OWN case + restores entitlement.

  ## `reconcile/2` — open / advance (done-criterion 1)

  1. No `object_id` ref (the invoice's own provider id — the webhook object IS
     the invoice, exactly like `Samen.Billing.Invoice`) ⇒ `{:ok, :ignored}`.
  2. Idempotency + out-of-order gate (`gate/2` — the SAME two-clause shape
     `Samen.Billing.Reconciler.gate/2` uses, ADR-038 §3.4(2)/(3), applied here
     to the dunning case instead of the subscription mirror):
       * an EXACT replay of the event that already produced the current case's
         state (`last_event_id` match) is `{:ok, :duplicate}` — skips a wasted
         authoritative re-fetch;
       * a DIFFERENT event whose `occurred_at` is strictly OLDER than the
         case's stored `watermark` (the last-applied event's `occurred_at`) is
         `{:ok, :stale}` — DISCARDED before any fetch/write/entitlement-clip.
         This is what stops a stale, distinct-event-id `:invoice_payment_failed`
         arriving AFTER a later `:invoice_paid` recovery from re-opening the
         case or re-clipping a paid customer's entitlement to grace. A TIE
         (`occurred_at == watermark`) is NOT stale — it PROCEEDS, exactly
         matching the Reconciler's own tie semantics (`DateTime.compare/2 ==
         :lt` is the only short-circuit; `:eq`/`:gt` both proceed).
  3. Authoritative re-fetch (ADR-038 §3.4(1) — never trust the webhook payload
     for state): `provider.fetch_object(:invoice, invoice_id, provider_config)`.
     The retry-schedule fields (`attempt_count`, `next_payment_attempt`) and
     the grace boundary (`period_end`) are MIRRORED VERBATIM from this
     snapshot — never recomputed here (mirrors the invoice/subscription
     reconcilers' "provider is the source of truth" discipline).
  4. `dunning_mirror.write_case/2` upserts the case row, keyed on
     `provider_invoice_id` — creates on first delivery, UPDATES THE SAME ROW
     on every subsequent delivery (a further retry attempt re-mirrors the
     CURRENT attempt_count/next_payment_attempt onto the same row — "the
     retry schedule advances" IS this idempotent re-mirror, not a growing
     list).
  5. Grace-period entitlement (done-criterion 2): `mirror.apply_entitlement/3`
     is called with `{:grace_until, period_end}` for the invoice's
     subscription — entitlement remains active THROUGH the invoice's period
     end even though payment failed, exactly extending T21's cancel-grace
     model (`Samen.Billing.Mirror` §"Entitlement transition") to the
     payment-failure path. If the grace boundary elapses before a recovery,
     the SAME already-existing `expires_at`-vs-now check
     (`Samen.Scopes.Billing.Entitlement.entitled_direct?/4`) naturally flips
     to not-entitled — no separate "drop" code path is needed.
  6. Best-effort notification (done-criterion 3): a `:payment_failed`
     lifecycle email is enqueued via `Samen.Delivery.Lifecycle.deliver/2`,
     which routes through `Samen.Delivery.Chokepoint` (suppression honored)
     exactly like every other C2 send family. This RIDES ALONGSIDE the
     dunning-case write and NEVER fails/aborts it (mirrors
     `Samen.Delivery.Lifecycle`'s own "best-effort, never raises" contract).

  ## `recover/2` — close (done-criterion 1 + 2 "recovered" control)

  Triggered by `:invoice_paid` for an invoice that has an OPEN dunning case.
  An invoice that never failed (the overwhelming common case) has no case row
  (`exists: false`) ⇒ `{:ok, :ignored}` — a true no-op, never a spurious write.
  Runs through the SAME `gate/2` as `reconcile/2` (an exact-event-id replay is
  `{:ok, :duplicate}`; a stale, older-than-watermark recovery is `{:ok, :stale}`
  — coherent in both directions: a delayed `:invoice_paid` can no more clobber
  a NEWER dunning-open than a delayed `:invoice_payment_failed` can clobber a
  recovery). Otherwise: the case flips to `:recovered` (its `occurred_at`
  ADVANCES the watermark, so a later stale `:invoice_payment_failed` is
  correctly discarded per §"open / advance" step 2), entitlement is restored
  via `mirror.apply_entitlement/3` with `:active` (clears any grace
  `expires_at` — see `Samen.Billing.Mirror`'s moduledoc), and a best-effort
  `:payment_recovered` lifecycle email is enqueued the same way.

  ## Org resolution for notifications (an honest, host-injectable seam)

  A bare invoice webhook carries no `org_id` of its own (ingress happens before
  org attribution — the same posture `Samen.Billing.AshInvoiceMirror` documents).
  `opts[:org_id]` is caller-supplied (in production, `Samen.Billing.WebhookDispatch`
  resolves it via an OPTIONAL `:billing_dunning_org_resolver` config function,
  same host-injectable shape as `Samen.Delivery.Chokepoint`'s suppression
  module). Absent an org_id, `Samen.Delivery.Lifecycle.deliver/2` degrades to
  its own honest `{:ok, :skipped}` — the dunning-case/entitlement writes above
  are UNAFFECTED either way (notification is side-effect-only, never gates the
  case/entitlement outcome).
  """

  alias Samen.Billing.ProviderEvent
  alias Samen.Delivery.Lifecycle

  @type opts :: [
          provider: module(),
          provider_config: map(),
          dunning_mirror: module(),
          dunning_mirror_ref: term(),
          mirror: module(),
          mirror_ref: term(),
          org_id: String.t() | nil,
          notify: boolean()
        ]

  @type outcome ::
          {:ok, :applied, map()}
          | {:ok, :duplicate}
          | {:ok, :recovered, map()}
          | {:ok, :ignored}
          | {:error, term()}

  @doc """
  Open or advance a dunning case from a normalized `:invoice_payment_failed`
  `Samen.Billing.ProviderEvent`. See the moduledoc for the full per-step
  contract. Any other kind is `{:ok, :ignored}` (defensive —
  `Samen.Billing.WebhookDispatch` only ever routes `:invoice_payment_failed`
  here, via the reconciler's `{:ok, :deferred_dunning}` hook).
  """
  @spec reconcile(ProviderEvent.t(), opts()) :: outcome()
  def reconcile(%ProviderEvent{kind: :invoice_payment_failed, provider_refs: refs} = event, opts) do
    refs = refs || %{}

    case Map.get(refs, :object_id) do
      nil -> {:ok, :ignored}
      invoice_id -> open_or_advance(invoice_id, refs, event, opts)
    end
  end

  def reconcile(%ProviderEvent{}, _opts), do: {:ok, :ignored}

  @doc """
  Close a dunning case (if one is open) from a normalized `:invoice_paid`
  `Samen.Billing.ProviderEvent`. See the moduledoc. Any other kind, or an
  invoice with no open case, is `{:ok, :ignored}` (the true common-case no-op —
  most paid invoices never failed).
  """
  @spec recover(ProviderEvent.t(), opts()) :: outcome()
  def recover(%ProviderEvent{kind: :invoice_paid, provider_refs: refs} = event, opts) do
    refs = refs || %{}

    case Map.get(refs, :object_id) do
      nil -> {:ok, :ignored}
      invoice_id -> close_case(invoice_id, refs, event, opts)
    end
  end

  def recover(%ProviderEvent{}, _opts), do: {:ok, :ignored}

  # ---------------------------------------------------------------------------
  # open / advance

  defp open_or_advance(invoice_id, refs, event, opts) do
    dunning_mirror = Keyword.fetch!(opts, :dunning_mirror)
    dunning_mirror_ref = Keyword.fetch!(opts, :dunning_mirror_ref)
    provider = Keyword.fetch!(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config, %{})

    with {:ok, state} <- dunning_mirror.read_state(dunning_mirror_ref, invoice_id),
         :proceed <- gate(state, event),
         {:ok, snapshot} <- provider.fetch_object(:invoice, invoice_id, provider_config) do
      subscription_id = Map.get(refs, :subscription_id) || Map.get(snapshot, :provider_subscription_id)
      # The grace boundary: the failing invoice's OWN period end — mirrored
      # verbatim, never recomputed (extends T21's `{:grace_until, period_end}`
      # cancel-grace model to the payment-failure path).
      grace_until = Map.get(snapshot, :period_end)

      case_attrs = %{
        provider_invoice_id: invoice_id,
        provider_subscription_id: subscription_id,
        status: :open,
        attempt_count: Map.get(snapshot, :attempt_count),
        next_payment_attempt: Map.get(snapshot, :next_payment_attempt),
        grace_until: grace_until,
        occurred_at: event.occurred_at,
        last_event_id: event.event_id
      }

      case dunning_mirror.write_case(dunning_mirror_ref, case_attrs) do
        {:ok, applied} ->
          apply_grace(opts, subscription_id, grace_until)
          notify(opts, :payment_failed, refs, subscription_id)
          {:ok, :applied, applied}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:short, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  # The idempotency + out-of-order gate (mirrors `Samen.Billing.Reconciler.gate/2`
  # EXACTLY — same two clauses, same tie semantics, ADR-038 §3.4(2)/(3)):
  #
  #   1. an EXACT replay of the event that already produced the current case's
  #      state (`last_event_id` match) is a no-op (`{:ok, :duplicate}`) —
  #      checked FIRST, before any watermark comparison;
  #   2. a DIFFERENT event whose `occurred_at` is strictly OLDER than the
  #      case's stored watermark is DISCARDED (`{:ok, :stale}`) — never
  #      re-opens a recovered case, never re-clips entitlement. A TIE
  #      (`occurred_at == watermark`) is NOT stale — it proceeds, exactly like
  #      the Reconciler (`:lt` is the only short-circuit; `:eq`/`:gt` proceed).
  #
  # Used by BOTH `open_or_advance/4` and `close_case/4` — the watermark guard
  # is symmetric (a stale recovery can no more clobber a newer dunning-open
  # than a stale failure can clobber a newer recovery).
  defp gate(%{last_event_id: last_id}, %ProviderEvent{event_id: event_id})
       when not is_nil(last_id) and last_id == event_id do
    {:short, {:ok, :duplicate}}
  end

  defp gate(%{exists: true, watermark: %DateTime{} = watermark}, %ProviderEvent{occurred_at: occurred_at}) do
    case DateTime.compare(occurred_at, watermark) do
      :lt -> {:short, {:ok, :stale}}
      _ -> :proceed
    end
  end

  defp gate(_state, _event), do: :proceed

  # ---------------------------------------------------------------------------
  # close / recover

  defp close_case(invoice_id, refs, event, opts) do
    dunning_mirror = Keyword.fetch!(opts, :dunning_mirror)
    dunning_mirror_ref = Keyword.fetch!(opts, :dunning_mirror_ref)

    case dunning_mirror.read_state(dunning_mirror_ref, invoice_id) do
      {:ok, %{exists: false}} ->
        # This invoice never entered dunning — the true common-case no-op.
        {:ok, :ignored}

      {:ok, state} ->
        case gate(state, event) do
          {:short, outcome} ->
            outcome

          :proceed ->
            do_close(invoice_id, refs, event, state, dunning_mirror, dunning_mirror_ref, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_close(_invoice_id, _refs, _event, %{status: :recovered}, _dunning_mirror, _dunning_mirror_ref, _opts) do
    # Already recovered (a DIFFERENT, non-stale event for an already-closed
    # case — e.g. a provider redelivering `invoice.paid` under a new event id)
    # — a safe no-op, never a redundant re-notify/re-restore.
    {:ok, :duplicate}
  end

  defp do_close(invoice_id, refs, event, state, dunning_mirror, dunning_mirror_ref, opts) do
    subscription_id = Map.get(refs, :subscription_id) || Map.get(state, :provider_subscription_id)

    case_attrs = %{
      provider_invoice_id: invoice_id,
      provider_subscription_id: subscription_id,
      status: :recovered,
      occurred_at: event.occurred_at,
      last_event_id: event.event_id
    }

    case dunning_mirror.write_case(dunning_mirror_ref, case_attrs) do
      {:ok, applied} ->
        apply_active(opts, subscription_id)
        notify(opts, :payment_recovered, refs, subscription_id)
        {:ok, :recovered, applied}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # entitlement (via the narrow Mirror.apply_entitlement/3 seam — never
  # write_snapshot/3, which would clobber the subscription reconciler's own
  # watermark/last_event_id bookkeeping)

  defp apply_grace(_opts, nil, _grace_until), do: :ok

  defp apply_grace(opts, subscription_id, grace_until) do
    mirror = Keyword.fetch!(opts, :mirror)
    mirror_ref = Keyword.fetch!(opts, :mirror_ref)
    mirror.apply_entitlement(mirror_ref, subscription_id, {:grace_until, grace_until})
    :ok
  end

  defp apply_active(_opts, nil), do: :ok

  defp apply_active(opts, subscription_id) do
    mirror = Keyword.fetch!(opts, :mirror)
    mirror_ref = Keyword.fetch!(opts, :mirror_ref)
    mirror.apply_entitlement(mirror_ref, subscription_id, :active)
    :ok
  end

  # ---------------------------------------------------------------------------
  # notification — best-effort, rides alongside the case/entitlement write,
  # NEVER affects the returned outcome (mirrors Samen.Delivery.Lifecycle's own
  # "never raises, caller-safe" contract; the inner rescue is defense in depth
  # since Lifecycle.deliver/2 already never raises).

  defp notify(opts, event, refs, subscription_id) do
    if Keyword.get(opts, :notify, true) do
      org_id = Keyword.get(opts, :org_id)
      subscriber_id = Map.get(refs, :customer_id) || subscription_id

      Lifecycle.deliver(event, org_id: org_id, subscriber_id: subscriber_id)
    end

    :ok
  rescue
    _ -> :ok
  end
end
