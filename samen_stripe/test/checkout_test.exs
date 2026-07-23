defmodule SamenStripe.CheckoutTest do
  @moduledoc """
  B2 hosted checkout — the T20 done-criteria, proven hermetically (keyless, M2 default;
  no network, no Stripe credential).

  The full real path runs through the CORE, vendor-generic session-creation logic (ADR-038
  §3.1/§2 — "adapters translate and transport; core owns state and convergence"):

      Samen.Billing.Checkout.create_session/2      (validates attrs, FORCES org-scoped
                                                      redirect URLs — done-criterion 3)
        → SamenStripe.Provider.create_checkout_session/2   (Stripe form assembly)
             served by an injected CAPTURING transport (config[:transport], §7.1 lane 0)

  and the success/cancel webhook half through the shared dispatch seam's consumer logic:

      signed Stripe webhook body
        → SamenStripe.Provider.verify_and_parse_event/3    (real Stripe t=,v1= scheme)
        → Samen.Billing.ProviderEvent (normalized, PII-redacted)
        → Samen.Billing.Checkout.reconcile/2                (T20's checkout half of the
                                                              WebhookDispatch seam)
        → SamenStripe.Provider.fetch_object/3                (authoritative re-fetch)
             served by a CASSETTE transport
        → Samen.Billing.FakeCheckoutMirror                   (in-memory port; the REAL
             Ash-backed write path is proven in samen_web's
             `samen/billing/checkout_reconcile_test.exs`, per the CheckoutMirror seam doc)

  Done-criteria:
    1. session created from an existing Plan/Price (fixture asserts payload fields);
       success webhook creates/activates Subscription + Entitlement (mirror-level proof
       here; real-resource proof in samen_web); cancel (`checkout.session.expired`)
       webhook leaves state UNCHANGED (asserted both).
    2. idempotent — success delivered twice ⇒ ONE activation.
    3. tenant redirect URLs are ALWAYS org-scoped.
    4. no PII in the Stripe checkout payload beyond the ADR-listed fields (INV-1,
       snapshot-tested against the captured form).
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{Checkout, FakeCheckoutMirror, ProviderEvent}
  alias Samen.Webhook.Signer
  alias SamenStripe.Provider

  @secret "whsec_test_checkout_9f1a2b3c4d5e6f70"
  @secret_key "sk_test_checkout"

  @org_id "org_checkout_1"
  # An EXISTING Plan/Price (as a real host would source them from the Billing scope's
  # Ash resources — samen_stripe itself is DB-free, so these stand in as their refs).
  @plan_id "plan_growth_uuid"
  @price_ref "price_growth_monthly"

  @session_id "cs_test_123"
  @sub_id "sub_checkout_1"
  @cus_id "cus_checkout_1"

  @period_end DateTime.from_unix!(1_785_196_800)

  # --- session-creation helpers -----------------------------------------------

  defp capturing_transport(response_fun) do
    parent = self()

    fn request ->
      send(parent, {:captured_request, request})
      response_fun.(request)
    end
  end

  defp session_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        org_id: @org_id,
        plan_id: @plan_id,
        price_ref: @price_ref,
        success_url: "https://app.example.test/billing/success",
        cancel_url: "https://app.example.test/billing/cancel"
      },
      overrides
    )
  end

  defp create_session(attrs, config_overrides) do
    config = Map.merge(%{secret_key: @secret_key}, config_overrides)
    Checkout.create_session(attrs, provider: Provider, provider_config: config)
  end

  # ---------------------------------------------------------------------------
  # 1 + 3. session creation: existing Plan/Price, org-scoped redirects
  # ---------------------------------------------------------------------------

  describe "done-criteria 1/3 — session created from an existing Plan/Price; org-scoped redirects" do
    test "a configured create_session builds the Stripe form and returns the session ref + url" do
      transport =
        capturing_transport(fn _req ->
          {:ok, %{status: 200, body: %{"id" => @session_id, "url" => "https://checkout.stripe.com/pay/#{@session_id}"}}}
        end)

      assert {:ok, %{provider_session_id: @session_id, url: url}} =
               create_session(session_attrs(), %{transport: transport})

      assert url == "https://checkout.stripe.com/pay/#{@session_id}"

      assert_received {:captured_request, %{method: :post, form: form}}
      assert form["line_items[0][price]"] == @price_ref
      assert form["mode"] == "subscription"
    end

    test "tenant redirect URLs are ALWAYS org-scoped — the org_id query param is FORCED" do
      transport =
        capturing_transport(fn _req -> {:ok, %{status: 200, body: %{"id" => @session_id, "url" => "https://x.test"}}} end)

      assert {:ok, _} = create_session(session_attrs(), %{transport: transport})

      assert_received {:captured_request, %{form: form}}
      success_uri = URI.parse(form["success_url"])
      cancel_uri = URI.parse(form["cancel_url"])

      assert URI.decode_query(success_uri.query) == %{"org_id" => @org_id}
      assert URI.decode_query(cancel_uri.query) == %{"org_id" => @org_id}
    end

    test "a caller-spoofed org_id in the redirect URL is OVERWRITTEN by the authoritative org_id" do
      spoofed_attrs =
        session_attrs(%{
          success_url: "https://app.example.test/billing/success?org_id=attacker_org&ref=abc",
          cancel_url: "https://app.example.test/billing/cancel?org_id=attacker_org"
        })

      transport =
        capturing_transport(fn _req -> {:ok, %{status: 200, body: %{"id" => @session_id, "url" => "https://x.test"}}} end)

      assert {:ok, _} = create_session(spoofed_attrs, %{transport: transport})

      assert_received {:captured_request, %{form: form}}
      success_query = URI.decode_query(URI.parse(form["success_url"]).query)
      assert success_query["org_id"] == @org_id
      refute success_query["org_id"] == "attacker_org"
      # A non-org_id query param is preserved.
      assert success_query["ref"] == "abc"
    end

    test "missing required attrs refuse BEFORE any provider call (never a partial session)" do
      transport = capturing_transport(fn _req -> {:ok, %{status: 200, body: %{"id" => "x", "url" => "x"}}} end)

      assert {:error, {:missing_attrs, missing}} =
               create_session(%{org_id: @org_id}, %{transport: transport})

      assert :plan_id in missing
      refute_received {:captured_request, _}
    end

    test "unconfigured provider refuses with :not_configured (fail-honest, ADR-014)" do
      assert {:error, :not_configured} =
               Checkout.create_session(session_attrs(), provider: Provider, provider_config: %{})
    end
  end

  # ---------------------------------------------------------------------------
  # 4. INV-1 — no PII beyond the ADR-listed checkout fields
  # ---------------------------------------------------------------------------

  describe "done-criterion 4 — no PII in the Stripe checkout payload beyond the ADR-listed fields (INV-1)" do
    test "the outbound form carries ONLY org_id/plan_id/price_ref/success_url/cancel_url/customer — never email/name" do
      transport =
        capturing_transport(fn _req -> {:ok, %{status: 200, body: %{"id" => @session_id, "url" => "https://x.test"}}} end)

      assert {:ok, _} =
               create_session(session_attrs(%{customer_ref: @cus_id}), %{transport: transport})

      assert_received {:captured_request, %{form: form}}

      allowed_keys = ~w(
        mode line_items[0][price] line_items[0][quantity]
        success_url cancel_url metadata[org_id] metadata[plan_id] customer
      )

      assert Enum.sort(Map.keys(form)) == Enum.sort(allowed_keys)

      # Snapshot: no email/name/phone/address-shaped key anywhere in the payload.
      pii_markers = ~w(email name phone address billing_details customer_email)

      for {k, v} <- form do
        refute Enum.any?(pii_markers, &String.contains?(String.downcase(k), &1)),
               "form key #{k} looks PII-shaped"

        refute is_binary(v) and String.contains?(String.downcase(v), "@"),
               "form value for #{k} looks like an email: #{v}"
      end

      assert form["metadata[org_id]"] == @org_id
      assert form["metadata[plan_id]"] == @plan_id
      assert form["customer"] == @cus_id
    end

    test "customer_ref is OPTIONAL — omitting it never invents a fake customer/PII" do
      transport =
        capturing_transport(fn _req -> {:ok, %{status: 200, body: %{"id" => @session_id, "url" => "https://x.test"}}} end)

      assert {:ok, _} = create_session(session_attrs(), %{transport: transport})

      assert_received {:captured_request, %{form: form}}
      refute Map.has_key?(form, "customer")
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook reconciliation (success creates/activates, cancel/expired is a no-op,
  # replay is idempotent) — mirror-level proof; the REAL Ash write path lives in
  # samen_web/test/samen/billing/checkout_reconcile_test.exs.
  # ---------------------------------------------------------------------------

  defp checkout_event(stripe_type, extra_object \\ %{}) do
    object =
      Map.merge(
        %{
          "id" => @session_id,
          "object" => "checkout.session",
          "customer" => @cus_id,
          "subscription" => @sub_id,
          "metadata" => %{"org_id" => @org_id, "plan_id" => @plan_id}
        },
        extra_object
      )

    body =
      Jason.encode!(%{
        "id" => "evt_#{stripe_type}_#{System.unique_integer([:positive])}",
        "type" => stripe_type,
        "created" => 1_782_518_400,
        "data" => %{"object" => object}
      })

    ts = System.system_time(:second)
    sig = Signer.sign(body, ts, @secret)
    headers = [{"stripe-signature", sig}]

    {:ok, %ProviderEvent{} = ev} =
      Provider.verify_and_parse_event(body, headers, %{secret_key: @secret_key, webhook_secret: @secret})

    ev
  end

  defp subscription_snapshot_transport do
    fn %{method: :get} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "id" => @sub_id,
           "customer" => @cus_id,
           "status" => "active",
           "current_period_start" => 1_782_518_400,
           "current_period_end" => DateTime.to_unix(@period_end),
           "items" => %{"data" => [%{"price" => %{"id" => @price_ref, "currency" => "usd"}}]}
         }
       }}
    end
  end

  defp reconcile_opts(mirror_ref) do
    [
      provider: Provider,
      provider_config: %{secret_key: @secret_key, transport: subscription_snapshot_transport()},
      checkout_mirror: FakeCheckoutMirror,
      checkout_mirror_ref: mirror_ref
    ]
  end

  describe "done-criterion 1 — success webhook activates; cancel (expired) leaves state unchanged" do
    test "checkout.session.completed activates a subscription (mirror-level)" do
      ref = FakeCheckoutMirror.new()
      event = checkout_event("checkout.session.completed")

      assert {:ok, :applied, applied} = Checkout.reconcile(event, reconcile_opts(ref))
      assert applied.provider_subscription_id == @sub_id
      assert applied.org_id == @org_id

      activation = FakeCheckoutMirror.get_activation(ref, @sub_id)
      assert activation.org_id == @org_id
      assert activation.plan_id == @plan_id
      assert activation.snapshot.status == :active
    end

    test "checkout.session.expired (the CANCEL webhook) leaves state UNCHANGED — no activation" do
      ref = FakeCheckoutMirror.new()
      event = checkout_event("checkout.session.expired")

      assert {:ok, :expired} = Checkout.reconcile(event, reconcile_opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 0
      assert FakeCheckoutMirror.get_activation(ref, @sub_id) == nil
    end

    test "BOTH asserted together: success activates, a SEPARATE expired session activates nothing" do
      ref = FakeCheckoutMirror.new()

      assert {:ok, :applied, _} = Checkout.reconcile(checkout_event("checkout.session.completed"), reconcile_opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 1

      other_session_expired =
        checkout_event("checkout.session.expired", %{"id" => "cs_other", "subscription" => "sub_other"})

      assert {:ok, :expired} = Checkout.reconcile(other_session_expired, reconcile_opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 1
      assert FakeCheckoutMirror.get_activation(ref, "sub_other") == nil
    end
  end

  describe "done-criterion 2 — idempotent: success delivered twice ⇒ ONE activation" do
    test "the SAME checkout.session.completed event replayed twice activates once" do
      ref = FakeCheckoutMirror.new()
      event = checkout_event("checkout.session.completed")

      assert {:ok, :applied, _} = Checkout.reconcile(event, reconcile_opts(ref))
      assert {:ok, :duplicate} = Checkout.reconcile(event, reconcile_opts(ref))

      assert FakeCheckoutMirror.change_count(ref) == 1
    end

    test "a DIFFERENT completed event for the SAME subscription is also a no-op (idempotent by provider_subscription_id, not event_id)" do
      ref = FakeCheckoutMirror.new()

      assert {:ok, :applied, _} = Checkout.reconcile(checkout_event("checkout.session.completed"), reconcile_opts(ref))

      # A distinct event_id (Stripe retried the webhook with a fresh delivery, or an
      # operator re-triggered) for the SAME subscription must still be a safe no-op.
      assert {:ok, :duplicate} =
               Checkout.reconcile(checkout_event("checkout.session.completed"), reconcile_opts(ref))

      assert FakeCheckoutMirror.change_count(ref) == 1
    end
  end

  describe "a non-subscription checkout (no `subscription` ref) is ignored, never errors" do
    test "a one-time-payment checkout.session.completed (no subscription created) is a safe no-op" do
      ref = FakeCheckoutMirror.new()
      event = checkout_event("checkout.session.completed", %{"subscription" => nil})

      assert {:ok, :ignored} = Checkout.reconcile(event, reconcile_opts(ref))
      assert FakeCheckoutMirror.change_count(ref) == 0
    end
  end
end
