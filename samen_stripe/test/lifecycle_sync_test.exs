defmodule SamenStripe.LifecycleSyncTest do
  @moduledoc """
  B3 subscription-lifecycle sync — the T21 done-criteria, proven end-to-end and
  hermetically (ADR-038 §3.4; keyless lane 0, §7.1).

  The FULL real path runs with no network and no Stripe credential:

      signed Stripe webhook body
        → SamenStripe.Provider.verify_and_parse_event/3   (real Stripe t=,v1= scheme)
        → Samen.Billing.ProviderEvent (normalized, PII-redacted)
        → Samen.Billing.Reconciler.reconcile/2            (vendor-generic convergence)
        → SamenStripe.Provider.fetch_object/3             (authoritative re-fetch — §3.4(1))
             served by a CASSETTE transport (config[:transport], §7.2)
        → Samen.Billing.FakeMirror                        (the in-memory mirror port)

  Per-event `provider_config` carries the cassette for THAT event's fetch, so an older
  event's fetch returns the older object state — the exact replica-lag race the
  watermark guard defends against (a live event ALWAYS re-fetches current truth; the
  hermetic test models the state-as-of-delivery so a dropped guard is REFUTABLE).

  Done-criteria:
    1. upgrade + downgrade apply the fixture proration EXACTLY; cancel ends entitlement
       at period end (dates asserted).
    2. idempotence — every fixture kind replayed twice = a single state change.
    3. out-of-order — (updated, created) reversed converges to the in-order terminal
       state (property-style over ≥3 permutations).
    4. (sabotage lives in scripts/sabotages — dropping the ordering guard flips
       `out-of-order ... converges`.)
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{FakeMirror, ProviderEvent, Reconciler}
  alias Samen.Webhook.Signer
  alias SamenStripe.Provider

  @secret "whsec_test_5f3a9c2b1d4e6f8a0c2e4b6d8f0a1c3e"
  @secret_key "sk_test_lifecycle"

  @sub_id "sub_lifecycle"
  @cus_id "cus_lifecycle"

  # Monotonic event markers (Stripe `created`): T1 (created) < T2 (updated/cancelled).
  @t1_unix 1_782_518_400
  @t2_unix 1_783_000_000

  # Period-end (unix 1_785_196_800) — the entitlement grace boundary the cancel asserts.
  @period_end DateTime.from_unix!(1_785_196_800)

  # Proration values that MUST appear on the mirror EXACTLY (the fixtures' proration
  # lines sum to these — see sub_upgraded.json / sub_downgraded.json).
  @upgrade_proration_cents 3_137
  @downgrade_proration_cents -1_842

  # --- cassette + event helpers ----------------------------------------------

  defp fixture(name) do
    Path.join([__DIR__, "fixtures", name])
    |> File.read!()
    |> Jason.decode!()
  end

  # A transport (config[:transport]) that serves ONE fixture body for the fetch.
  defp cassette(fixture_name) do
    body = fixture(fixture_name)
    fn %{method: :get} -> {:ok, %{status: 200, body: body}} end
  end

  defp config(fixture_name) do
    %{secret_key: @secret_key, transport: cassette(fixture_name)}
  end

  # Build + sign + parse a real Stripe subscription webhook, returning the normalized
  # ProviderEvent (exercising the real signature-verify + parse path).
  defp event(stripe_type, created_unix) do
    body =
      Jason.encode!(%{
        "id" => "evt_#{stripe_type}_#{created_unix}",
        "type" => stripe_type,
        "created" => created_unix,
        "data" => %{
          "object" => %{
            "id" => @sub_id,
            "object" => "subscription",
            "customer" => @cus_id
          }
        }
      })

    ts = System.system_time(:second)
    sig = Signer.sign(body, ts, @secret)
    headers = [{"stripe-signature", sig}]

    {:ok, %ProviderEvent{} = ev} =
      Provider.verify_and_parse_event(body, headers, %{
        secret_key: @secret_key,
        webhook_secret: @secret
      })

    ev
  end

  defp opts(fixture_name, ref) do
    [mirror: FakeMirror, mirror_ref: ref, provider: Provider, provider_config: config(fixture_name)]
  end

  defp deliver(ref, stripe_type, created_unix, fixture_name) do
    Reconciler.reconcile(event(stripe_type, created_unix), opts(fixture_name, ref))
  end

  # ---------------------------------------------------------------------------
  # 1. proration applied EXACTLY + cancel entitlement grace
  # ---------------------------------------------------------------------------

  describe "done-criterion 1 — proration mirrored exactly; cancel grace dates" do
    test "upgrade applies the fixture proration verbatim" do
      ref = FakeMirror.new()
      deliver(ref, "customer.subscription.created", @t1_unix, "sub_created.json")

      assert {:ok, :applied, _} =
               deliver(ref, "customer.subscription.updated", @t2_unix, "sub_upgraded.json")

      sub = FakeMirror.get_subscription(ref, @sub_id)
      assert sub.plan_ref == "price_pro"
      assert sub.status == :active
      assert sub.proration_amount_cents == @upgrade_proration_cents
    end

    test "downgrade applies the (credit) fixture proration verbatim" do
      ref = FakeMirror.new()
      deliver(ref, "customer.subscription.created", @t1_unix, "sub_created.json")

      assert {:ok, :applied, _} =
               deliver(ref, "customer.subscription.updated", @t2_unix, "sub_downgraded.json")

      sub = FakeMirror.get_subscription(ref, @sub_id)
      assert sub.plan_ref == "price_basic"
      assert sub.proration_amount_cents == @downgrade_proration_cents
    end

    test "cancel ends entitlement AT PERIOD END (grace), not immediately" do
      ref = FakeMirror.new()
      FakeMirror.seed_entitlement(ref, @sub_id, :advanced_reporting)
      FakeMirror.seed_entitlement(ref, @sub_id, :api_access)

      deliver(ref, "customer.subscription.created", @t1_unix, "sub_created.json")

      assert {:ok, :applied, _} =
               deliver(ref, "customer.subscription.deleted", @t2_unix, "sub_cancelled.json")

      sub = FakeMirror.get_subscription(ref, @sub_id)
      assert sub.status == :cancelled

      ents = FakeMirror.list_entitlements(ref, @sub_id)
      assert length(ents) == 2

      for e <- ents do
        assert e.granted == true, "cancel must NOT revoke immediately (grace)"
        assert e.expires_at == @period_end, "entitlement must expire at current_period_end"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. idempotence — replay twice = single change (table over all sub kinds)
  # ---------------------------------------------------------------------------

  describe "done-criterion 2 — replay is a single state change (table-driven)" do
    for {stripe_type, fixture} <- [
          {"customer.subscription.created", "sub_created.json"},
          {"customer.subscription.updated", "sub_upgraded.json"},
          {"customer.subscription.deleted", "sub_cancelled.json"}
        ] do
      test "#{stripe_type} replayed twice = one change" do
        ref = FakeMirror.new()
        ev = event(unquote(stripe_type), @t2_unix)
        o = opts(unquote(fixture), ref)

        assert {:ok, :applied, _} = Reconciler.reconcile(ev, o)
        # Exact same event again (an operator/worker replay) is a no-op.
        assert {:ok, :duplicate} = Reconciler.reconcile(ev, o)

        assert FakeMirror.change_count(ref) == 1
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. out-of-order convergence (property-style, ≥3 permutations)
  # ---------------------------------------------------------------------------

  describe "done-criterion 3 — out-of-order converges to the in-order terminal state" do
    # created@T1 (basic), updated@T2 (pro). Terminal MUST be `pro` for EVERY ordering —
    # the late `created` is older than the applied `updated` and is discarded.
    @orderings [
      {"in-order", [:created, :updated]},
      {"reverse", [:updated, :created]},
      {"reverse + stale replay", [:updated, :created, :created]},
      {"interleaved stale replay", [:created, :updated, :created]}
    ]

    for {name, order} <- @orderings do
      test "converges — #{name}" do
        ref = FakeMirror.new()

        Enum.each(unquote(order), fn
          :created -> deliver(ref, "customer.subscription.created", @t1_unix, "sub_created.json")
          :updated -> deliver(ref, "customer.subscription.updated", @t2_unix, "sub_upgraded.json")
        end)

        sub = FakeMirror.get_subscription(ref, @sub_id)
        assert sub.plan_ref == "price_pro"
        assert sub.proration_amount_cents == @upgrade_proration_cents
        assert sub.provider_event_at == DateTime.from_unix!(@t2_unix)
      end
    end

    test "a strictly-older event is reported :stale and never clobbers newer state" do
      ref = FakeMirror.new()
      assert {:ok, :applied, _} = deliver(ref, "customer.subscription.updated", @t2_unix, "sub_upgraded.json")
      assert {:ok, :stale} = deliver(ref, "customer.subscription.created", @t1_unix, "sub_created.json")
      assert FakeMirror.get_subscription(ref, @sub_id).plan_ref == "price_pro"
      assert FakeMirror.change_count(ref) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # normalization + fail-honest spot checks (the adapter side of the seam)
  # ---------------------------------------------------------------------------

  describe "adapter fetch_object normalization" do
    test "maps Stripe fields to the vendor-neutral snapshot" do
      {:ok, snap} = Provider.fetch_object(:subscription, @sub_id, config("sub_created.json"))

      assert snap.provider_subscription_id == @sub_id
      assert snap.provider_customer_id == @cus_id
      assert snap.status == :active
      assert snap.plan_ref == "price_basic"
      assert snap.current_period_end == @period_end
      # No proration lines on the initial invoice → nil, never a fabricated 0.
      assert snap.proration_amount_cents == nil
    end

    test "unconfigured fetch refuses (fail-honest), configured 404 is :not_found" do
      assert {:error, :not_configured} = Provider.fetch_object(:subscription, @sub_id, %{})

      cfg = %{secret_key: @secret_key, transport: fn _ -> {:ok, %{status: 404, body: %{}}} end}
      assert {:error, :not_found} = Provider.fetch_object(:subscription, "sub_missing", cfg)
    end
  end
end
