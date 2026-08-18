defmodule Samen.Billing.WebhookDispatchTest do
  @moduledoc """
  Proves the T21 billing consumer of the T19 dispatch seam (ADR-038 §5.2 step 5):
  a stored `Samen.Webhook.Event` envelope is reconstructed into a `ProviderEvent` and
  reconciled into the configured mirror — with the provider + mirror resolved from host
  config (vendor-free; unconfigured is a safe `:ok` no-op).

  No DB: the envelope is an in-memory struct and the mirror is `FakeMirror`, so this is
  a pure routing + wiring proof (the convergence itself is proven in
  `billing_reconciler_test.exs` / `samen_stripe/test/lifecycle_sync_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Samen.Billing.{FakeCheckoutMirror, FakeInvoiceMirror, FakeMirror, WebhookDispatch}
  alias Samen.Webhook.Event

  defmodule LocalProvider do
    @behaviour Samen.Billing.Provider
    @impl true
    def configured?(_), do: true
    @impl true
    def fetch_object(:subscription, id, %{snapshot: snap}),
      do: {:ok, Map.put(snap, :provider_subscription_id, id)}

    def fetch_object(:invoice, id, %{invoice_snapshot: snap}),
      do: {:ok, Map.put(snap, :provider_invoice_id, id)}

    def fetch_object(:subscription, _id, %{fail: reason}), do: {:error, reason}
    def fetch_object(_k, _id, _c), do: {:error, :not_found}
    @impl true
    def create_checkout_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def create_portal_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_i, _o, _c), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_i, _ch, _c), do: {:error, :not_implemented}
    @impl true
    def report_usage(_b, _c), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_r, _h, _c), do: {:error, :not_implemented}
    @impl true
    def redact_payload(p), do: p
  end

  @t2 ~U[2026-07-10 00:00:00.000000Z]

  setup do
    on_exit(fn ->
      Application.delete_env(:samen_core, :billing_provider)
      Application.delete_env(:samen_core, :billing_mirror)
      Application.delete_env(:samen_core, :billing_checkout_mirror)
      Application.delete_env(:samen_core, :billing_invoice_mirror)
    end)

    :ok
  end

  defp configure(provider_config) do
    ref = FakeMirror.new()
    Application.put_env(:samen_core, :billing_provider, {LocalProvider, provider_config})
    Application.put_env(:samen_core, :billing_mirror, {FakeMirror, ref})
    ref
  end

  # T20/B2 — configures ONLY the checkout mirror slot (never :billing_mirror), proving
  # the two ports are genuinely separate config slots (Samen.Billing.CheckoutMirror seam).
  defp configure_checkout(provider_config) do
    ref = FakeCheckoutMirror.new()
    Application.put_env(:samen_core, :billing_provider, {LocalProvider, provider_config})
    Application.put_env(:samen_core, :billing_checkout_mirror, {FakeCheckoutMirror, ref})
    ref
  end

  defp envelope(kind, domain \\ "billing") do
    %Event{
      provider: "acme",
      event_id: "evt_#{kind}_1",
      kind: kind,
      domain: domain,
      occurred_at: @t2,
      payload: %{"id" => "sub_1", "customer" => "cus_1"}
    }
  end

  # A checkout.session envelope: `id` is the SESSION id, `subscription` the created
  # subscription, `metadata` carries the org/plan refs Samen.Billing.Checkout stamped
  # on the way out.
  defp checkout_envelope(kind, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          "id" => "cs_1",
          "customer" => "cus_1",
          "subscription" => "sub_1",
          "metadata" => %{"org_id" => "org_1", "plan_id" => "plan_1"}
        },
        overrides
      )

    %Event{
      provider: "acme",
      event_id: "evt_#{kind}_1",
      kind: kind,
      domain: "billing",
      occurred_at: @t2,
      payload: payload
    }
  end

  defp snap do
    %{
      provider_subscription_id: "sub_1",
      status: :active,
      current_period_end: ~U[2026-08-01 00:00:00Z],
      plan_ref: "price_pro",
      proration_amount_cents: 500
    }
  end

  # T22/B4+B6 — an invoice envelope: the webhook object IS the invoice, so `id` is
  # the invoice's OWN provider id (recovered as `object_id` by `refs_from_payload`).
  defp invoice_envelope(kind, overrides \\ %{}) do
    payload = Map.merge(%{"id" => "in_1", "customer" => "cus_1", "subscription" => "sub_1"}, overrides)

    %Event{
      provider: "acme",
      event_id: "evt_#{kind}_1",
      kind: kind,
      domain: "billing",
      occurred_at: @t2,
      payload: payload
    }
  end

  defp invoice_snap(overrides \\ %{}) do
    Map.merge(
      %{
        status: :open,
        amount_due_cents: 10_000,
        tax_amount_cents: nil,
        tax_lines: [],
        hosted_invoice_url: "https://provider.example.test/invoices/in_1"
      },
      overrides
    )
  end

  # T22/B4+B6 — configures ONLY the invoice mirror slot (never :billing_mirror or
  # :billing_checkout_mirror), proving the three ports are genuinely separate config
  # slots (Samen.Billing.InvoiceMirror seam).
  defp configure_invoice(provider_config) do
    ref = FakeInvoiceMirror.new()
    Application.put_env(:samen_core, :billing_provider, {LocalProvider, provider_config})
    Application.put_env(:samen_core, :billing_invoice_mirror, {FakeInvoiceMirror, ref})
    ref
  end

  test "a billing subscription envelope reconciles into the configured mirror" do
    ref = configure(%{snapshot: snap()})

    assert :ok = WebhookDispatch.dispatch(envelope("subscription_updated"), [])

    sub = FakeMirror.get_subscription(ref, "sub_1")
    assert sub.plan_ref == "price_pro"
    assert sub.proration_amount_cents == 500
    assert sub.last_event_id == "evt_subscription_updated_1"
  end

  test "invoice_payment_failed is acked (deferred to dunning), mirror untouched" do
    ref = configure(%{snapshot: snap()})
    assert :ok = WebhookDispatch.dispatch(envelope("invoice_payment_failed"), [])
    assert FakeMirror.change_count(ref) == 0
  end

  test "an unknown/unhandled billing kind is acked without touching the mirror" do
    ref = configure(%{snapshot: snap()})
    # payment_method_attached is a valid ADR kind but not yet consumed (T23 owns it) —
    # a genuinely unhandled kind, unlike checkout_completed (now T20's, see below).
    assert :ok = WebhookDispatch.dispatch(envelope("payment_method_attached"), [])
    assert FakeMirror.change_count(ref) == 0
  end

  # ---------------------------------------------------------------------------
  # T20/B2 — checkout kinds route to Samen.Billing.Checkout via a SEPARATE
  # :billing_checkout_mirror config slot, never T21's :billing_mirror/FakeMirror.
  # ---------------------------------------------------------------------------

  test "checkout_completed routes to the checkout mirror (billing_mirror untouched)" do
    lifecycle_ref = FakeMirror.new()
    Application.put_env(:samen_core, :billing_mirror, {FakeMirror, lifecycle_ref})
    checkout_ref = configure_checkout(%{snapshot: snap()})

    assert :ok = WebhookDispatch.dispatch(checkout_envelope("checkout_completed"), [])

    activation = FakeCheckoutMirror.get_activation(checkout_ref, "sub_1")
    assert activation.org_id == "org_1"
    assert activation.plan_id == "plan_1"
    assert FakeMirror.change_count(lifecycle_ref) == 0
  end

  test "checkout_expired routes to Checkout.reconcile as a no-op (cancel leaves state unchanged)" do
    checkout_ref = configure_checkout(%{snapshot: snap()})
    assert :ok = WebhookDispatch.dispatch(checkout_envelope("checkout_expired"), [])
    assert FakeCheckoutMirror.change_count(checkout_ref) == 0
  end

  test "checkout kind with NO :billing_checkout_mirror configured (but :billing_mirror set) is a safe :ok no-op" do
    lifecycle_ref = configure(%{snapshot: snap()})
    assert :ok = WebhookDispatch.dispatch(checkout_envelope("checkout_completed"), [])
    assert FakeMirror.change_count(lifecycle_ref) == 0
  end

  test "checkout replay is idempotent through the full dispatch path" do
    checkout_ref = configure_checkout(%{snapshot: snap()})
    ev = checkout_envelope("checkout_completed")

    assert :ok = WebhookDispatch.dispatch(ev, [])
    assert :ok = WebhookDispatch.dispatch(ev, [])

    assert FakeCheckoutMirror.change_count(checkout_ref) == 1
  end

  # ---------------------------------------------------------------------------
  # T22/B4+B6 — invoice kinds route to Samen.Billing.Invoice via a SEPARATE
  # :billing_invoice_mirror config slot, never :billing_mirror/:billing_checkout_mirror.
  # ---------------------------------------------------------------------------

  test "invoice_finalized routes to the invoice mirror (billing_mirror untouched)" do
    lifecycle_ref = FakeMirror.new()
    Application.put_env(:samen_core, :billing_mirror, {FakeMirror, lifecycle_ref})
    invoice_ref = configure_invoice(%{invoice_snapshot: invoice_snap()})

    assert :ok = WebhookDispatch.dispatch(invoice_envelope("invoice_finalized"), [])

    invoice = FakeInvoiceMirror.get_invoice(invoice_ref, "in_1")
    assert invoice.status == :open
    assert invoice.hosted_invoice_url == "https://provider.example.test/invoices/in_1"
    assert FakeMirror.change_count(lifecycle_ref) == 0
  end

  test "invoice_paid re-mirrors the SAME invoice through the full dispatch path (idempotent upsert)" do
    invoice_ref = configure_invoice(%{invoice_snapshot: invoice_snap()})

    assert :ok = WebhookDispatch.dispatch(invoice_envelope("invoice_finalized"), [])

    Application.put_env(
      :samen_core,
      :billing_provider,
      {LocalProvider, %{invoice_snapshot: invoice_snap(%{status: :paid, amount_paid_cents: 10_000})}}
    )

    assert :ok = WebhookDispatch.dispatch(invoice_envelope("invoice_paid"), [])

    invoice = FakeInvoiceMirror.get_invoice(invoice_ref, "in_1")
    assert invoice.status == :paid
    assert FakeInvoiceMirror.change_count(invoice_ref) == 2
  end

  test "invoice kind with NO :billing_invoice_mirror configured (but :billing_mirror set) is a safe :ok no-op" do
    lifecycle_ref = configure(%{snapshot: snap()})
    assert :ok = WebhookDispatch.dispatch(invoice_envelope("invoice_finalized"), [])
    assert FakeMirror.change_count(lifecycle_ref) == 0
  end

  test "invoice replay is idempotent through the full dispatch path" do
    invoice_ref = configure_invoice(%{invoice_snapshot: invoice_snap()})
    ev = invoice_envelope("invoice_finalized")

    assert :ok = WebhookDispatch.dispatch(ev, [])
    assert :ok = WebhookDispatch.dispatch(ev, [])

    assert FakeInvoiceMirror.change_count(invoice_ref) == 1
  end

  test "a non-billing (delivery) envelope is acked, never reconciled" do
    ref = configure(%{snapshot: snap()})
    assert :ok = WebhookDispatch.dispatch(envelope("delivered", "delivery"), [])
    assert FakeMirror.change_count(ref) == 0
  end

  test "unconfigured host (no provider/mirror) is a safe :ok no-op" do
    # no configure/1 — env is empty
    assert :ok = WebhookDispatch.dispatch(envelope("subscription_updated"), [])
  end

  test "a transient fetch failure surfaces {:error, _} for the worker to retry/DLQ" do
    configure(%{fail: :timeout})

    assert {:error, {:fetch_failed, :timeout}} =
             WebhookDispatch.dispatch(envelope("subscription_updated"), [])
  end
end
