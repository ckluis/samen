defmodule Samen.Billing.CheckoutTest do
  @moduledoc """
  Core-side, VENDOR-FREE proof of the B2 checkout logic (T20; ADR-038 §3.1/§3.4).

  Mirrors `samen_stripe/test/checkout_test.exs`'s done-criteria but with a test-local
  provider double (no Stripe, no `samen_stripe`) so `samen_core` proves session-creation
  validation/org-scoping + the checkout-reconciliation routing/idempotency on its OWN
  — the INV-4 posture (core green with every adapter absent).
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{Checkout, FakeCheckoutMirror, ProviderEvent}

  defmodule LocalProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double: records the checkout attrs it received."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(config), do: Map.get(config, :configured, true) == true

    @impl true
    def create_checkout_session(_attrs, %{configured: false}), do: {:error, :not_configured}

    def create_checkout_session(attrs, _config) do
      {:ok, %{provider_session_id: "sess_1", url: "https://fake.test/checkout/sess_1", received_attrs: attrs}}
    end

    @impl true
    def fetch_object(:subscription, _id, %{snapshot: snap}), do: {:ok, snap}
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}

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

  @org_id "org_1"
  @plan_id "plan_1"
  @sub_id "sub_checkout_1"
  @cus_id "cus_checkout_1"

  defp snap(overrides \\ %{}) do
    Map.merge(%{status: :active, current_period_end: ~U[2026-08-01 00:00:00Z]}, overrides)
  end

  defp event(kind, refs) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_#{kind}_#{System.unique_integer([:positive])}",
      kind: kind,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: refs,
      payload: %{}
    }
  end

  defp opts(mirror_ref, snapshot \\ nil) do
    [
      provider: LocalProvider,
      provider_config: %{snapshot: snapshot || snap()},
      checkout_mirror: FakeCheckoutMirror,
      checkout_mirror_ref: mirror_ref
    ]
  end

  # ---------------------------------------------------------------------------
  # Session creation — validation + org-scoping (done-criterion 3)
  # ---------------------------------------------------------------------------

  describe "create_session/2 — validation" do
    test "all required attrs present delegates to the provider" do
      attrs = %{
        org_id: @org_id,
        plan_id: @plan_id,
        price_ref: "price_1",
        success_url: "https://app.test/success",
        cancel_url: "https://app.test/cancel"
      }

      assert {:ok, %{provider_session_id: "sess_1", received_attrs: received}} =
               Checkout.create_session(attrs, provider: LocalProvider, provider_config: %{})

      assert received.org_id == @org_id
    end

    test "a missing required attr refuses BEFORE any provider call" do
      attrs = %{org_id: @org_id, plan_id: @plan_id}

      assert {:error, {:missing_attrs, missing}} =
               Checkout.create_session(attrs, provider: LocalProvider, provider_config: %{})

      assert :price_ref in missing
      assert :success_url in missing
      assert :cancel_url in missing
    end

    test "blank-string attrs are treated as missing (anti-tautology: nil isn't the only refusal shape)" do
      attrs = %{
        org_id: @org_id,
        plan_id: @plan_id,
        price_ref: "",
        success_url: "https://app.test/success",
        cancel_url: "https://app.test/cancel"
      }

      assert {:error, {:missing_attrs, [:price_ref]}} =
               Checkout.create_session(attrs, provider: LocalProvider, provider_config: %{})
    end
  end

  describe "create_session/2 — tenant redirect URLs are ALWAYS org-scoped (done-criterion 3)" do
    test "org_id is stamped onto success_url/cancel_url" do
      attrs = %{
        org_id: @org_id,
        plan_id: @plan_id,
        price_ref: "price_1",
        success_url: "https://app.test/success",
        cancel_url: "https://app.test/cancel"
      }

      {:ok, %{received_attrs: received}} =
        Checkout.create_session(attrs, provider: LocalProvider, provider_config: %{})

      assert URI.decode_query(URI.parse(received.success_url).query) == %{"org_id" => @org_id}
      assert URI.decode_query(URI.parse(received.cancel_url).query) == %{"org_id" => @org_id}
    end

    test "a caller-supplied mismatched org_id in the URL is OVERWRITTEN, never trusted" do
      attrs = %{
        org_id: @org_id,
        plan_id: @plan_id,
        price_ref: "price_1",
        success_url: "https://app.test/success?org_id=someone_else",
        cancel_url: "https://app.test/cancel"
      }

      {:ok, %{received_attrs: received}} =
        Checkout.create_session(attrs, provider: LocalProvider, provider_config: %{})

      query = URI.decode_query(URI.parse(received.success_url).query)
      assert query["org_id"] == @org_id
    end
  end

  # ---------------------------------------------------------------------------
  # Reconciliation — success activates, expired is a no-op, idempotent (done-criteria 1/2)
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — :checkout_completed activates via the mirror" do
    test "activates once and returns the applied summary" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, org_id: @org_id, plan_id: @plan_id, customer_id: @cus_id}

      assert {:ok, :applied, applied} =
               Checkout.reconcile(event(:checkout_completed, refs), opts(ref))

      assert applied.provider_subscription_id == @sub_id
      assert applied.org_id == @org_id

      activation = FakeCheckoutMirror.get_activation(ref, @sub_id)
      assert activation.plan_id == @plan_id
      assert activation.customer_ref == @cus_id
    end

    test "a non-subscription-mode checkout (no subscription_id ref) is ignored, never errors" do
      ref = FakeCheckoutMirror.new()
      refs = %{org_id: @org_id, plan_id: @plan_id}

      assert {:ok, :ignored} = Checkout.reconcile(event(:checkout_completed, refs), opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 0
    end

    test "missing org_id ref surfaces as an actionable error (never silently swallowed)" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, plan_id: @plan_id}

      assert {:error, {:missing_ref, :org_id}} = Checkout.reconcile(event(:checkout_completed, refs), opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 0
    end

    test "a transient fetch failure surfaces {:error, _} for the worker to retry/DLQ" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, org_id: @org_id, plan_id: @plan_id}
      # An empty provider_config makes the LocalProvider's fetch_object catch-all fire.
      failing_opts = opts(ref) |> Keyword.put(:provider_config, %{})

      assert {:error, :not_found} = Checkout.reconcile(event(:checkout_completed, refs), failing_opts)
      assert FakeCheckoutMirror.change_count(ref) == 0
    end
  end

  describe "reconcile/2 — :checkout_expired (the CANCEL webhook) leaves state unchanged" do
    test "expired is a pure no-op regardless of refs" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, org_id: @org_id, plan_id: @plan_id}

      assert {:ok, :expired} = Checkout.reconcile(event(:checkout_expired, refs), opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 0
      assert FakeCheckoutMirror.get_activation(ref, @sub_id) == nil
    end
  end

  describe "reconcile/2 — done-criterion 2: idempotent (success delivered twice ⇒ ONE subscription)" do
    test "the SAME event replayed twice activates once" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, org_id: @org_id, plan_id: @plan_id}
      ev = event(:checkout_completed, refs)

      assert {:ok, :applied, _} = Checkout.reconcile(ev, opts(ref))
      assert {:ok, :duplicate} = Checkout.reconcile(ev, opts(ref))

      assert FakeCheckoutMirror.change_count(ref) == 1
    end

    test "a DIFFERENT event_id for the SAME provider_subscription_id is still a no-op" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, org_id: @org_id, plan_id: @plan_id}

      assert {:ok, :applied, _} = Checkout.reconcile(event(:checkout_completed, refs), opts(ref))
      assert {:ok, :duplicate} = Checkout.reconcile(event(:checkout_completed, refs), opts(ref))

      assert FakeCheckoutMirror.change_count(ref) == 1
    end
  end

  describe "reconcile/2 — any other kind is a defensive no-op" do
    test "a subscription-lifecycle kind reaching Checkout.reconcile/2 is ignored (routing belongs to WebhookDispatch)" do
      ref = FakeCheckoutMirror.new()
      refs = %{subscription_id: @sub_id, org_id: @org_id}

      assert {:ok, :ignored} = Checkout.reconcile(event(:subscription_updated, refs), opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 0
    end
  end
end
