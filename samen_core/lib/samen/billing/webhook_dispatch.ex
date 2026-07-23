defmodule Samen.Billing.WebhookDispatch do
  @moduledoc """
  The billing consumer of the T19 webhook-dispatch seam (ADR-038 §5.2 step 5; T21/B3).

  T19 shipped `Samen.Webhook.Dispatch` with only the honest `:unhandled` default and
  named T21 as the billing consumer. This module IS that consumer: wired via

      config :samen_core, :webhook_dispatch, Samen.Billing.WebhookDispatch

  it reconstructs a `Samen.Billing.ProviderEvent` from a stored `Samen.Webhook.Event`
  envelope and hands it to `Samen.Billing.Reconciler`, which converges the configured
  mirror (`Samen.Billing.Mirror` impl) via the fetch-on-event model (§3.4).

  ## Vendor-free by construction (INV-4)

  This module names no vendor. The provider adapter + the mirror impl are BOTH resolved
  from host config, so a host that does not use samen billing sync (or has not wired an
  adapter) makes this a safe `:ok` no-op — never a crash, never a fake reconcile:

      config :samen_core, :billing_provider, {MyApp.BillingAdapter.Provider, %{secret_key: "sk_...", ...}}
      config :samen_core, :billing_mirror,   {MyApp.BillingMirror, mirror_ref}

  The shipped `Samen.Billing.Mirror` impl is the honest in-memory `FakeMirror` (the
  proven convergence target for the reconciler tests). The PRODUCTION impl — an
  Ash-backed mirror writing the host's governed `Subscription`/`Entitlement` resources —
  is the documented next step (GAP T21-G1): it needs the subscription convergence
  bookkeeping (out-of-order watermark + last-applied event id) stored either as
  dedicated typed columns on the `Subscription` blueprint (a demo/driftwood/pawchart
  migration + catalog + gen_app golden update) or in a core infra table (the
  `Samen.Webhook.Event` / `Samen.AuditEvent` catalog-exempt precedent). The reconciler,
  the mirror port, and this consumer are all vendor-generic and mirror-agnostic, so that
  impl plugs in with zero change here.

  ## The stored envelope → ProviderEvent reconstruction

  The ingress persists the REDACTED payload + normalized `kind`/`occurred_at`/`event_id`
  (T19 §5.3); it does NOT persist the structured `provider_refs` (no such column). For a
  subscription webhook the payload object IS the subscription, so its id/customer refs
  are recovered from the redacted payload's generic `"id"`/`"customer"` keys (redaction
  strips PII, never provider ids — §5.4). Reconciliation then re-fetches the
  AUTHORITATIVE object anyway, so the reconstructed payload is only used for its refs.

  ## Result mapping (the DLQ contract, §5.2 step 5)

  `Samen.Billing.Reconciler` (subscription-lifecycle kinds) / `Samen.Billing.Checkout`
  (checkout kinds — T20/B2, routed here instead: see `Samen.Billing.CheckoutMirror`'s
  moduledoc for the full row-ownership seam between the two) / `Samen.Billing.Invoice`
  (invoice kinds — T22/B4+B6, `:invoice_finalized`/`:invoice_paid`, its own
  `Samen.Billing.InvoiceMirror` port + `:billing_invoice_mirror` config slot) /
  `Samen.Billing.Dunning` (B7/T24 — wired onto the Reconciler's `:invoice_payment_failed`
  `{:ok, :deferred_dunning}` hook for open/advance, and ADDITIONALLY consulted after
  `Samen.Billing.Invoice` on `:invoice_paid` for recovery; its own
  `Samen.Billing.DunningMirror` port + `:billing_dunning_mirror` config slot) outcomes
  map to the dispatch contract:

    * `:applied | :duplicate | :stale | :ignored | :expired | :deferred_dunning` ⇒
      `:ok` (handled, or safely-not-ours — the envelope is marked processed).
    * `{:error, reason}` ⇒ `{:error, reason}` — a transient failure (e.g. an
      authoritative re-fetch that timed out); the worker retries, then DLQs (§5.5).
      Reconciliation is idempotent, so a retry/DLQ-replay is always safe (§3.4).
  """

  @behaviour Samen.Webhook.Dispatch

  alias Samen.Billing.{Checkout, Dunning, Invoice, ProviderEvent, Reconciler}
  alias Samen.Webhook.Event

  # The checkout kinds routed to Samen.Billing.Checkout (T20/B2) instead of the
  # subscription-lifecycle Reconciler (T21/B3) — the seam is the KIND, not a separate
  # dispatch config slot; both consumers share this one wired module (ADR-038 §5).
  @checkout_kinds ~w(checkout_completed checkout_expired)a

  # The invoice kinds routed to Samen.Billing.Invoice (T22/B4+B6). NOT
  # `:invoice_payment_failed` — that kind is T24 dunning's exclusive trigger
  # (ADR-038 §3.5 B7 rule); it stays routed to `dispatch_lifecycle` below, where
  # `Samen.Billing.Reconciler` already leaves it explicitly `{:ok, :deferred_dunning}`.
  @invoice_kinds ~w(invoice_finalized invoice_paid)a

  # The bounded kinds this consumer actively reconciles (subscription lifecycle +
  # checkout + invoice). Everything else (delivery kinds, billing kinds owned by
  # sibling tasks, e.g. payment_method_* — T23) is acked as a safe no-op.
  @known_kinds ~w(
    subscription_created subscription_updated subscription_deleted
    invoice_payment_failed
  )a ++ @checkout_kinds ++ @invoice_kinds

  @impl true
  def dispatch(%Event{domain: "billing"} = event, _opts) do
    provider_event = to_provider_event(event)

    cond do
      provider_event.kind in @checkout_kinds -> dispatch_checkout(provider_event)
      provider_event.kind in @invoice_kinds -> dispatch_invoice(provider_event)
      true -> dispatch_lifecycle(provider_event)
    end
  end

  # Non-billing envelopes (delivery — T30) are not this consumer's concern; ack.
  def dispatch(%Event{}, _opts), do: :ok

  # ---------------------------------------------------------------------------

  defp dispatch_lifecycle(provider_event) do
    with {:ok, provider, provider_config} <- billing_provider(),
         {:ok, mirror, mirror_ref} <- billing_mirror() do
      case Reconciler.reconcile(provider_event,
             provider: provider,
             provider_config: provider_config,
             mirror: mirror,
             mirror_ref: mirror_ref
           ) do
        {:ok, :applied, _applied} -> :ok
        # T24 — the clean hook: the reconciler leaves :invoice_payment_failed
        # explicitly unhandled; Dunning takes it from here.
        {:ok, :deferred_dunning} -> dispatch_dunning(provider_event, provider, provider_config, mirror, mirror_ref)
        {:ok, _outcome} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # No adapter / no mirror wired — this host is not running samen billing sync.
      # Ack the envelope honestly (nothing to reconcile), never crash the worker.
      :not_configured -> :ok
    end
  end

  # T24/B7 — open/advance a dunning case. A SEPARATE :billing_dunning_mirror config
  # slot (Samen.Billing.DunningMirror), never T21's :billing_mirror (see that
  # module's moduledoc for why entitlement writes route through the narrow
  # apply_entitlement/3 seam instead of a full write_snapshot/3). Unwired ⇒ an
  # honest :ok no-op — the same "host not running this yet" posture every other
  # slot here has.
  defp dispatch_dunning(provider_event, provider, provider_config, mirror, mirror_ref) do
    case billing_dunning_mirror() do
      {:ok, dunning_mirror, dunning_mirror_ref} ->
        case Dunning.reconcile(provider_event,
               provider: provider,
               provider_config: provider_config,
               mirror: mirror,
               mirror_ref: mirror_ref,
               dunning_mirror: dunning_mirror,
               dunning_mirror_ref: dunning_mirror_ref,
               org_id: dunning_org_id(provider_event)
             ) do
          {:ok, _outcome, _applied} -> :ok
          {:ok, _outcome} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :not_configured ->
        :ok
    end
  end

  # T20/B2 — checkout kinds resolve the SEPARATE :billing_checkout_mirror config slot
  # (Samen.Billing.CheckoutMirror), never T21's :billing_mirror (see the seam doc).
  defp dispatch_checkout(provider_event) do
    with {:ok, provider, provider_config} <- billing_provider(),
         {:ok, mirror, mirror_ref} <- billing_checkout_mirror() do
      case Checkout.reconcile(provider_event,
             provider: provider,
             provider_config: provider_config,
             checkout_mirror: mirror,
             checkout_mirror_ref: mirror_ref
           ) do
        {:ok, :applied, _applied} -> :ok
        {:ok, _outcome} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :not_configured -> :ok
    end
  end

  # T22/B4+B6 — invoice kinds resolve the SEPARATE :billing_invoice_mirror config
  # slot (Samen.Billing.InvoiceMirror), never T21's :billing_mirror or T20's
  # :billing_checkout_mirror (see Samen.Billing.InvoiceMirror's moduledoc for why
  # invoices get their own port).
  defp dispatch_invoice(provider_event) do
    with {:ok, provider, provider_config} <- billing_provider(),
         {:ok, mirror, mirror_ref} <- billing_invoice_mirror() do
      result =
        case Invoice.reconcile(provider_event,
               provider: provider,
               provider_config: provider_config,
               invoice_mirror: mirror,
               invoice_mirror_ref: mirror_ref
             ) do
          {:ok, :applied, _applied} -> :ok
          {:ok, _outcome} -> :ok
          {:error, reason} -> {:error, reason}
        end

      # T24/B7 recovery — an ADDITIONAL, best-effort consumer of :invoice_paid
      # (never a replacement for Samen.Billing.Invoice's own reconcile above,
      # which stays the sole owner of the Invoice mirror row). A no-op when
      # this invoice never had an open dunning case (the common case).
      if result == :ok and provider_event.kind == :invoice_paid do
        dispatch_dunning_recovery(provider_event, provider, provider_config)
      end

      result
    else
      :not_configured -> :ok
    end
  end

  defp dispatch_dunning_recovery(provider_event, provider, provider_config) do
    with {:ok, mirror, mirror_ref} <- billing_mirror(),
         {:ok, dunning_mirror, dunning_mirror_ref} <- billing_dunning_mirror() do
      Dunning.recover(provider_event,
        provider: provider,
        provider_config: provider_config,
        mirror: mirror,
        mirror_ref: mirror_ref,
        dunning_mirror: dunning_mirror,
        dunning_mirror_ref: dunning_mirror_ref,
        org_id: dunning_org_id(provider_event)
      )
    else
      :not_configured -> :ok
    end
  end

  defp to_provider_event(%Event{} = event) do
    payload = event.payload || %{}

    %ProviderEvent{
      provider: safe_atom(event.provider),
      event_id: event.event_id,
      kind: kind_atom(event.kind),
      occurred_at: event.occurred_at,
      provider_refs: refs_from_payload(payload),
      payload: payload
    }
  end

  # The subscription/customer refs recovered from the redacted payload (generic keys —
  # a subscription webhook's object IS the subscription). For checkout kinds, the
  # webhook object IS the checkout session: `id` is the SESSION id (not a subscription
  # id — kept as `object_id`, unused by the checkout reconciler), `subscription` is the
  # subscription created BY the checkout, and `metadata.{org_id,plan_id}` are the refs
  # `Samen.Billing.Checkout.create_session/2` stamped on the way out (§ metadata is not
  # PII, so it survives `redact_payload/1` unredacted).
  defp refs_from_payload(payload) do
    metadata = payload["metadata"] || payload[:metadata] || %{}

    %{}
    |> put_ref(:object_id, payload["id"] || payload[:id])
    |> put_ref(:customer_id, payload["customer"] || payload[:customer])
    |> put_ref(:subscription_id, payload["subscription"] || payload[:subscription])
    |> put_ref(:org_id, metadata["org_id"] || metadata[:org_id])
    |> put_ref(:plan_id, metadata["plan_id"] || metadata[:plan_id])
  end

  defp put_ref(refs, _key, nil), do: refs
  defp put_ref(refs, key, value) when is_binary(value), do: Map.put(refs, key, value)
  defp put_ref(refs, _key, _value), do: refs

  # Map the stored kind string to the bounded ProviderEvent kind atom; anything unknown
  # (or unparseable) is `:unhandled` (the reconciler `:ignore`s it).
  defp kind_atom(kind) when is_binary(kind) do
    atom = safe_atom(kind)
    if atom in @known_kinds, do: atom, else: :unhandled
  end

  defp kind_atom(_), do: :unhandled

  defp safe_atom(value) when is_atom(value), do: value

  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unhandled
  end

  defp safe_atom(_), do: :unhandled

  defp billing_provider do
    case Application.get_env(:samen_core, :billing_provider) do
      {module, config} when is_atom(module) and is_map(config) -> {:ok, module, config}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, %{}}
      _ -> :not_configured
    end
  end

  defp billing_mirror do
    case Application.get_env(:samen_core, :billing_mirror) do
      {module, ref} when is_atom(module) -> {:ok, module, ref}
      _ -> :not_configured
    end
  end

  # T20/B2 — the checkout-activation port, SEPARATE from :billing_mirror (see
  # Samen.Billing.CheckoutMirror's moduledoc for why this is a distinct config slot).
  defp billing_checkout_mirror do
    case Application.get_env(:samen_core, :billing_checkout_mirror) do
      {module, ref} when is_atom(module) -> {:ok, module, ref}
      _ -> :not_configured
    end
  end

  # T22/B4+B6 — the invoice-mirror port, SEPARATE from :billing_mirror and
  # :billing_checkout_mirror (see Samen.Billing.InvoiceMirror's moduledoc).
  defp billing_invoice_mirror do
    case Application.get_env(:samen_core, :billing_invoice_mirror) do
      {module, ref} when is_atom(module) -> {:ok, module, ref}
      _ -> :not_configured
    end
  end

  # T24/B7 — the dunning-case mirror port, SEPARATE from :billing_mirror,
  # :billing_checkout_mirror, and :billing_invoice_mirror (see
  # Samen.Billing.DunningMirror's moduledoc).
  defp billing_dunning_mirror do
    case Application.get_env(:samen_core, :billing_dunning_mirror) do
      {module, ref} when is_atom(module) -> {:ok, module, ref}
      _ -> :not_configured
    end
  end

  # T24/B7 — an OPTIONAL, host-injectable org resolver for dunning
  # notifications (a bare invoice webhook carries no org_id of its own; see
  # Samen.Billing.Dunning's moduledoc "Org resolution"). Unwired ⇒ nil, which
  # Samen.Delivery.Lifecycle.deliver/2 already degrades to an honest
  # {:ok, :skipped} for — never a crash, never a guessed org.
  #
  #     config :samen_core, :billing_dunning_org_resolver, fn provider_refs -> ... end
  defp dunning_org_id(%ProviderEvent{provider_refs: refs}) do
    case Application.get_env(:samen_core, :billing_dunning_org_resolver) do
      fun when is_function(fun, 1) -> fun.(refs || %{})
      _ -> nil
    end
  rescue
    # A raising resolver degrades to "couldn't resolve" — notify.ex-only impact
    # (Lifecycle.deliver/2 skips honestly); never crashes the dunning write.
    _ -> nil
  end
end
