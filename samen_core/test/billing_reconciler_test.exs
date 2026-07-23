defmodule Samen.Billing.ReconcilerTest do
  @moduledoc """
  Core-side, VENDOR-FREE proof of the B3 convergence engine (T21; ADR-038 §3.4).

  This mirrors the `samen_stripe/test/lifecycle_sync_test.exs` done-criteria but with a
  test-local provider (no Stripe, no `samen_stripe`) so `samen_core` proves the
  reconciler's idempotency + out-of-order convergence + entitlement-grace + proration
  mirroring on its OWN — the INV-4 posture (core green with every adapter absent) and a
  ci-fast-lane guard on the engine.

  The provider double serves the snapshot injected into `provider_config[:snapshot]`,
  so each reconcile call models the object state as-fetched at THAT event's delivery
  (an older snapshot for an older event — exactly the replica-lag race the watermark
  guard defends against).
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{FakeMirror, ProviderEvent, Reconciler}

  # --- a vendor-free provider double: fetch_object returns the injected snapshot ------
  defmodule SnapshotProvider do
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(config), do: Map.get(config, :configured, true) == true
    @impl true
    def fetch_object(:subscription, _id, %{snapshot: snap}), do: {:ok, snap}
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}
    @impl true
    def create_checkout_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def create_portal_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_id, _o, _c), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_id, _ch, _c), do: {:error, :not_implemented}
    @impl true
    def report_usage(_b, _c), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_r, _h, _c), do: {:error, :not_implemented}
    @impl true
    def redact_payload(p), do: p
  end

  @sub_id "sub_lifecycle_1"
  @t1 ~U[2026-07-01 00:00:00.000000Z]
  @t2 ~U[2026-07-10 00:00:00.000000Z]
  @period_end ~U[2026-08-01 00:00:00.000000Z]

  defp event(kind, occurred_at, refs \\ %{subscription_id: @sub_id}) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_#{kind}_#{DateTime.to_unix(occurred_at)}",
      kind: kind,
      occurred_at: occurred_at,
      provider_refs: refs,
      payload: %{}
    }
  end

  defp snap(overrides) do
    Map.merge(
      %{
        provider_subscription_id: @sub_id,
        provider_customer_id: "cus_1",
        status: :active,
        current_period_start: @t1,
        current_period_end: @period_end,
        plan_ref: "price_basic",
        proration_amount_cents: 0,
        currency: "usd"
      },
      overrides
    )
  end

  defp opts(ref, snapshot), do: [mirror: FakeMirror, mirror_ref: ref, provider: SnapshotProvider, provider_config: %{snapshot: snapshot}]

  describe "proration is mirrored from the provider EXACTLY (done-criterion 1)" do
    test "an upgrade applies the fixture proration verbatim" do
      ref = FakeMirror.new()
      up = snap(%{plan_ref: "price_pro", proration_amount_cents: 3_137})

      assert {:ok, :applied, _} =
               Reconciler.reconcile(event(:subscription_updated, @t2), opts(ref, up))

      mirrored = FakeMirror.get_subscription(ref, @sub_id)
      assert mirrored.plan_ref == "price_pro"
      # Exact mirror — never recomputed.
      assert mirrored.proration_amount_cents == 3_137
    end

    test "a downgrade applies the (negative/credit) fixture proration verbatim" do
      ref = FakeMirror.new()
      down = snap(%{plan_ref: "price_basic", proration_amount_cents: -1_842})

      assert {:ok, :applied, _} =
               Reconciler.reconcile(event(:subscription_updated, @t2), opts(ref, down))

      assert FakeMirror.get_subscription(ref, @sub_id).proration_amount_cents == -1_842
    end
  end

  describe "cancel ends entitlement AT PERIOD END (grace) — done-criterion 1" do
    test "subscription_deleted sets every entitlement expires_at to current_period_end" do
      ref = FakeMirror.new()
      FakeMirror.seed_entitlement(ref, @sub_id, :advanced_reporting)
      FakeMirror.seed_entitlement(ref, @sub_id, :api_access)

      cancelled = snap(%{status: :cancelled, current_period_end: @period_end})

      assert {:ok, :applied, _} =
               Reconciler.reconcile(event(:subscription_deleted, @t2), opts(ref, cancelled))

      ents = FakeMirror.list_entitlements(ref, @sub_id)
      assert length(ents) == 2
      # Grace: still granted, but expiring at period end — NOT immediately revoked.
      for e <- ents do
        assert e.granted == true
        assert e.expires_at == @period_end
      end
    end
  end

  describe "idempotency — replay is a single state change (done-criterion 2)" do
    for kind <- [:subscription_created, :subscription_updated, :subscription_deleted] do
      test "#{kind} replayed twice = one change" do
        ref = FakeMirror.new()
        s = snap(%{status: if(unquote(kind) == :subscription_deleted, do: :cancelled, else: :active)})
        e = event(unquote(kind), @t2)

        assert {:ok, :applied, _} = Reconciler.reconcile(e, opts(ref, s))
        assert {:ok, :duplicate} = Reconciler.reconcile(e, opts(ref, s))

        assert FakeMirror.change_count(ref) == 1
      end
    end
  end

  describe "out-of-order convergence (done-criterion 3, property-style)" do
    # created@t1 (basic), updated@t2 (pro). Terminal must be `pro` for EVERY ordering.
    defp created_ev, do: event(:subscription_created, @t1)
    defp updated_ev, do: event(:subscription_updated, @t2)
    defp created_snap, do: snap(%{plan_ref: "price_basic", proration_amount_cents: 0})
    defp updated_snap, do: snap(%{plan_ref: "price_pro", proration_amount_cents: 3_137})

    defp deliver(ref, {ev, s}), do: Reconciler.reconcile(ev, opts(ref, s))

    permutations = [
      {"in-order", [:created, :updated]},
      {"reverse", [:updated, :created]},
      {"reverse + stale replay", [:updated, :created, :created]},
      {"in-order + stale replay of created after updated", [:created, :updated, :created]}
    ]

    for {name, order} <- permutations do
      test "converges to the same terminal state — #{name}" do
        ref = FakeMirror.new()

        steps =
          Enum.map(unquote(order), fn
            :created -> {created_ev(), created_snap()}
            :updated -> {updated_ev(), updated_snap()}
          end)

        Enum.each(steps, &deliver(ref, &1))

        terminal = FakeMirror.get_subscription(ref, @sub_id)
        # The newer (updated) state ALWAYS wins — the stale `created` never clobbers it.
        assert terminal.plan_ref == "price_pro"
        assert terminal.proration_amount_cents == 3_137
        assert terminal.provider_event_at == @t2
      end
    end

    test "a strictly-older event is reported :stale and does not mutate the mirror" do
      ref = FakeMirror.new()
      assert {:ok, :applied, _} = deliver(ref, {updated_ev(), updated_snap()})
      assert {:ok, :stale} = deliver(ref, {created_ev(), created_snap()})
      assert FakeMirror.change_count(ref) == 1
      assert FakeMirror.get_subscription(ref, @sub_id).plan_ref == "price_pro"
    end
  end

  describe "scope + T24 hook" do
    test "invoice_payment_failed is deferred to dunning (clean T24 seam), never applied here" do
      ref = FakeMirror.new()
      assert {:ok, :deferred_dunning} =
               Reconciler.reconcile(event(:invoice_payment_failed, @t2), opts(ref, snap(%{})))

      assert FakeMirror.change_count(ref) == 0
    end

    test "non-subscription kinds are ignored (owned by sibling tasks)" do
      ref = FakeMirror.new()

      for kind <- [:checkout_completed, :invoice_paid, :payment_method_attached, :unhandled] do
        assert {:ok, :ignored} = Reconciler.reconcile(event(kind, @t2), opts(ref, snap(%{})))
      end

      assert FakeMirror.change_count(ref) == 0
    end

    test "a subscription event with no resolvable subscription ref errors honestly" do
      ref = FakeMirror.new()

      assert {:error, :missing_subscription_ref} =
               Reconciler.reconcile(event(:subscription_updated, @t2, %{}), opts(ref, snap(%{})))
    end
  end
end
