defmodule Samen.Billing.DunningTest do
  @moduledoc """
  Core-side, VENDOR-FREE proof of the B7 dunning logic (T24; ADR-038 §3.5).

  Mirrors `samen_stripe/test/dunning_test.exs`'s done-criteria 1-2 with a
  test-local provider double (no Stripe, no `samen_stripe`) so `samen_core`
  proves dunning-case routing/idempotency/retry-advance + the grace-period
  entitlement seam on its OWN — the INV-4 posture (core green with every
  adapter absent).

  ADDITIONALLY proves done-criterion 3 — dunning notifications route through
  `Samen.Delivery.Chokepoint` (suppression honored) — using the REAL
  `Samen.Delivery.Lifecycle.EmailWorker` + `Samen.Delivery.FakeProvider`,
  the SAME pattern `samen_core/test/delivery/lifecycle_send_test.exs` uses
  (Oban + the `SamenCore.TestRepo` sandbox are available here; `samen_stripe`'s
  test env is a plain `ExUnit.start()` with no DB, so that proof cannot live
  there).
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Samen.Billing.{Dunning, FakeDunningMirror, FakeMirror, ProviderEvent}
  alias Samen.Delivery.{Chokepoint, FakeProvider}
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias SamenCore.TestRepo

  defmodule LocalProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double: serves a canned invoice snapshot."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(config), do: Map.get(config, :configured, true) == true

    @impl true
    def fetch_object(:invoice, _id, %{snapshot: snap}), do: {:ok, snap}
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}

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

  @invoice_id "in_1"
  @cus_id "cus_1"
  @sub_id "sub_1"
  @period_end ~U[2026-08-01 00:00:00Z]

  defp snap(overrides \\ %{}) do
    Map.merge(
      %{
        provider_customer_id: @cus_id,
        provider_subscription_id: @sub_id,
        status: :open,
        period_end: @period_end,
        attempt_count: 1,
        next_payment_attempt: ~U[2026-07-25 00:00:00Z]
      },
      overrides
    )
  end

  defp event(kind, refs, occurred_at \\ ~U[2026-07-10 00:00:00Z]) do
    %ProviderEvent{
      provider: :fake,
      event_id: "evt_#{kind}_#{System.unique_integer([:positive])}",
      kind: kind,
      occurred_at: occurred_at,
      provider_refs: refs,
      payload: %{}
    }
  end

  defp refs(overrides \\ %{}) do
    Map.merge(%{object_id: @invoice_id, customer_id: @cus_id, subscription_id: @sub_id}, overrides)
  end

  defp opts(dunning_ref, mirror_ref, snapshot \\ nil, extra \\ []) do
    Keyword.merge(
      [
        provider: LocalProvider,
        provider_config: %{snapshot: snapshot || snap()},
        dunning_mirror: FakeDunningMirror,
        dunning_mirror_ref: dunning_ref,
        mirror: FakeMirror,
        mirror_ref: mirror_ref,
        notify: false
      ],
      extra
    )
  end

  # Mirrors `Samen.Scopes.Billing.Entitlement`'s own predicate: granted &&
  # (expires_at is nil OR expires_at is in the future).
  defp entitled?(row, now),
    do: row.granted == true and (is_nil(row.expires_at) or DateTime.compare(row.expires_at, now) == :gt)

  # ---------------------------------------------------------------------------
  # done-criterion 1 — reconcile/2 open/advance, idempotent
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — :invoice_payment_failed opens/advances a dunning case" do
    test "opens a case mirroring attempt_count/next_payment_attempt/grace_until verbatim" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :applied, _} = Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :open
      assert c.provider_subscription_id == @sub_id
      assert c.attempt_count == 1
      assert c.next_payment_attempt == ~U[2026-07-25 00:00:00Z]
      assert c.grace_until == @period_end
    end

    test "a second, DIFFERENT event for the SAME invoice advances the retry schedule on the SAME row" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref))

      advanced = snap(%{attempt_count: 2, next_payment_attempt: ~U[2026-07-28 00:00:00Z]})
      assert {:ok, :applied, _} = Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref, advanced))

      assert FakeDunningMirror.change_count(dref) == 2
      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.attempt_count == 2
      assert c.next_payment_attempt == ~U[2026-07-28 00:00:00Z]
    end

    test "no invoice ref (object_id absent) is ignored, never errors" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :ignored} = Dunning.reconcile(event(:invoice_payment_failed, %{}), opts(dref, mref))
      assert FakeDunningMirror.change_count(dref) == 0
    end

    test "a transient fetch failure surfaces {:error, _} for the worker to retry/DLQ" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      failing_opts = opts(dref, mref) |> Keyword.put(:provider_config, %{})

      assert {:error, :not_found} = Dunning.reconcile(event(:invoice_payment_failed, refs()), failing_opts)
      assert FakeDunningMirror.change_count(dref) == 0
    end

    test "the exact same event replayed twice is a no-op (single change)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      ev = event(:invoice_payment_failed, refs())
      o = opts(dref, mref)

      assert {:ok, :applied, _} = Dunning.reconcile(ev, o)
      assert {:ok, :duplicate} = Dunning.reconcile(ev, o)
      assert FakeDunningMirror.change_count(dref) == 1
    end

    test "a subscription-lifecycle kind reaching Dunning.reconcile/2 is a defensive no-op" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :ignored} = Dunning.reconcile(event(:subscription_updated, refs()), opts(dref, mref))
      assert FakeDunningMirror.change_count(dref) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 1 (recovery) + done-criterion 2 (grace-period entitlement)
  # ---------------------------------------------------------------------------

  describe "recover/2 — :invoice_paid closes an open case + restores entitlement" do
    test "closes the case; entitlement expires_at is CLEARED (full access restored)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref))
      [ent] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent.expires_at == @period_end

      assert {:ok, :recovered, _} = Dunning.recover(event(:invoice_paid, refs()), opts(dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :recovered

      [ent2] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent2.expires_at == nil
      assert entitled?(ent2, DateTime.add(@period_end, 365 * 86_400, :second))
    end

    test "an invoice that never failed is a true no-op (no spurious case created)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :ignored} = Dunning.recover(event(:invoice_paid, refs()), opts(dref, mref))
      assert FakeDunningMirror.get_case(dref, @invoice_id) == nil
      assert FakeDunningMirror.change_count(dref) == 0
    end

    test "recovery replayed twice is a no-op" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref))
      ev = event(:invoice_paid, refs())
      o = opts(dref, mref)

      assert {:ok, :recovered, _} = Dunning.recover(ev, o)
      assert {:ok, :duplicate} = Dunning.recover(ev, o)
      assert FakeDunningMirror.change_count(dref) == 2
    end

    test "a non-invoice-paid kind reaching recover/2 is a defensive no-op" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      assert {:ok, :ignored} = Dunning.recover(event(:invoice_finalized, refs()), opts(dref, mref))
    end
  end

  describe "grace-period policy (done-criterion 2): active through grace end, then drops" do
    test "entitled before grace end; not entitled after (no recovery arrived)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref))
      [ent] = FakeMirror.list_entitlements(mref, @sub_id)

      assert entitled?(ent, DateTime.add(@period_end, -3600, :second))
      refute entitled?(ent, DateTime.add(@period_end, 3600, :second))
    end
  end

  # ---------------------------------------------------------------------------
  # ATTEMPT 2 FIX — out-of-order guard (ADR-038 §3.4(3), mirrors
  # Samen.Billing.Reconciler.gate/2 exactly). Reproduces the live-verifier bug:
  # a stale, DISTINCT-event-id `:invoice_payment_failed` arriving AFTER an
  # `:invoice_paid` recovery must be discarded (`:stale`) — it must NEVER
  # re-open a recovered case or re-clip a paid customer's entitlement back to
  # grace, just because its event_id differs from the one that closed it.
  # ---------------------------------------------------------------------------

  describe "out-of-order guard (attempt 2 fix): stale events after recovery never re-open" do
    @t1 ~U[2026-07-10 00:00:00Z]
    @t0_stale ~U[2026-07-12 00:00:00Z]
    @t2_recovery ~U[2026-07-15 00:00:00Z]
    @t3_newer ~U[2026-07-20 00:00:00Z]

    test "RED-on-revert: a stale payment_failed (distinct event_id, older than the recovery) is discarded — case stays CLOSED, entitlement stays ACTIVE" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      # Open, then recover (a genuine paid-in-full customer).
      assert {:ok, :applied, _} = Dunning.reconcile(event(:invoice_payment_failed, refs(), @t1), opts(dref, mref))
      assert {:ok, :recovered, _} = Dunning.recover(event(:invoice_paid, refs(), @t2_recovery), opts(dref, mref))

      [ent_after_recovery] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent_after_recovery.expires_at == nil

      # A STALE :invoice_payment_failed — a DISTINCT event_id, occurred_at
      # BEFORE the recovery — arrives late (e.g. a delayed/retried webhook
      # delivery). This must be discarded, never re-applied.
      assert {:ok, :stale} =
               Dunning.reconcile(event(:invoice_payment_failed, refs(), @t0_stale), opts(dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :recovered, "a stale failure must NOT re-open the recovered case"

      [ent_final] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent_final.expires_at == nil,
             "a stale failure must NOT re-clip a paid customer's entitlement back to grace"

      # No third write at all — the stale event never reached write_case/2.
      assert FakeDunningMirror.change_count(dref) == 2
    end

    test "control: a genuinely NEWER payment_failed after recovery legitimately re-opens (a real new dunning cycle)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      Dunning.reconcile(event(:invoice_payment_failed, refs(), @t1), opts(dref, mref))
      Dunning.recover(event(:invoice_paid, refs(), @t2_recovery), opts(dref, mref))

      assert {:ok, :applied, _} =
               Dunning.reconcile(event(:invoice_payment_failed, refs(), @t3_newer), opts(dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :open, "a genuinely NEWER failure is a real new dunning cycle, not stale"

      [ent] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent.expires_at == @period_end
    end

    test "tie: occurred_at EQUAL to the recovery watermark proceeds (T21 tie semantics — not stale)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      Dunning.reconcile(event(:invoice_payment_failed, refs(), @t1), opts(dref, mref))
      Dunning.recover(event(:invoice_paid, refs(), @t2_recovery), opts(dref, mref))

      # SAME timestamp as the recovery — a tie is NOT `:lt`, so it PROCEEDS,
      # exactly matching Samen.Billing.Reconciler.gate/2's own tie semantics
      # (defined, deterministic — not stale-by-omission).
      assert {:ok, :applied, _} =
               Dunning.reconcile(event(:invoice_payment_failed, refs(), @t2_recovery), opts(dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :open
    end

    test "the stale guard is symmetric: a stale invoice_paid after a NEWER re-open cannot clobber it" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      Dunning.reconcile(event(:invoice_payment_failed, refs(), @t1), opts(dref, mref))
      Dunning.recover(event(:invoice_paid, refs(), @t2_recovery), opts(dref, mref))
      Dunning.reconcile(event(:invoice_payment_failed, refs(), @t3_newer), opts(dref, mref))

      # A stale invoice_paid (distinct event_id, older than the t3 re-open)
      # must not close the newer case.
      assert {:ok, :stale} =
               Dunning.recover(event(:invoice_paid, refs(), @t0_stale), opts(dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :open, "a stale recovery must NOT close the newer, still-open case"

      [ent] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent.expires_at == @period_end, "a stale recovery must NOT restore entitlement early"
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 3 — notifications route through Samen.Delivery.Chokepoint
  # (suppression honored)
  # ---------------------------------------------------------------------------

  describe "notifications route through Samen.Delivery.Chokepoint (suppression honored)" do
    @env_keys [:delivery_provider, :delivery_provider_overrides, :delivery_env]
    @app_keys [EmailWorker, Chokepoint]

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

      prev_env = for k <- @env_keys, into: %{}, do: {k, Application.get_env(:samen_core, k)}
      prev_app = for k <- @app_keys, into: %{}, do: {k, Application.get_env(:samen_core, k)}

      FakeProvider.reset()

      on_exit(fn ->
        for {k, v} <- prev_env, do: restore(k, v)
        for {k, v} <- prev_app, do: restore(k, v)
      end)

      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:samen_core, key)
    defp restore(key, val), do: Application.put_env(:samen_core, key, val)

    defp configure_fake_provider do
      Application.put_env(:samen_core, :delivery_provider, {FakeProvider, %{configured: true}})
      Application.delete_env(:samen_core, :delivery_provider_overrides)
      Application.delete_env(:samen_core, EmailWorker)
    end

    defp delivered_to?(org_id, subscriber_id) do
      Enum.any?(FakeProvider.calls(), fn
        {:deliver, %{message: m}} -> m.org_id == org_id and m.to_subscriber_id == subscriber_id
        _ -> false
      end)
    end

    # The most recently-enqueued EmailWorker job row (Oban `testing: :manual`
    # writes the row without auto-executing it — same posture
    # `delivery_lifecycle_test.exs`'s enqueue-seam test relies on).
    defp latest_job(worker_name) do
      TestRepo.one(
        from(j in Oban.Job, where: j.worker == ^worker_name, order_by: [desc: j.id], limit: 1)
      )
    end

    defmodule PairSuppression do
      @moduledoc "Test-only suppression check: a fixed set of (org_id, subscriber_id) pairs."
      def suppressed?(org_id, subscriber_id) do
        Process.get(:billing_dunning_test_suppressed, MapSet.new())
        |> MapSet.member?({org_id, subscriber_id})
      end
    end

    defp suppress!(org_id, subscriber_id) do
      Application.put_env(:samen_core, Chokepoint, suppression_module: PairSuppression)
      current = Process.get(:billing_dunning_test_suppressed, MapSet.new())
      Process.put(:billing_dunning_test_suppressed, MapSet.put(current, {org_id, subscriber_id}))
    end

    test "a payment_failed case enqueues a lifecycle notification that reaches the configured provider" do
      configure_fake_provider()
      org_id = Ash.UUID.generate()
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :applied, _} =
               Dunning.reconcile(
                 event(:invoice_payment_failed, refs()),
                 opts(dref, mref, nil, notify: true, org_id: org_id)
               )

      job = latest_job("Samen.Delivery.Lifecycle.EmailWorker")
      assert job.args["event"] == "payment_failed"
      assert job.args["org_id"] == org_id
      assert job.args["subscriber_id"] == @cus_id

      assert :ok = EmailWorker.perform(%Oban.Job{args: job.args})
      assert delivered_to?(org_id, @cus_id)
    end

    test "recovery enqueues a payment_recovered notification" do
      configure_fake_provider()
      org_id = Ash.UUID.generate()
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(event(:invoice_payment_failed, refs()), opts(dref, mref, nil, notify: false))

      assert {:ok, :recovered, _} =
               Dunning.recover(event(:invoice_paid, refs()), opts(dref, mref, nil, notify: true, org_id: org_id))

      job = latest_job("Samen.Delivery.Lifecycle.EmailWorker")
      assert job.args["event"] == "payment_recovered"

      assert :ok = EmailWorker.perform(%Oban.Job{args: job.args})
      assert delivered_to?(org_id, @cus_id)
    end

    test "a SUPPRESSED recipient is refused AT THE CHOKEPOINT — the provider is NEVER called" do
      configure_fake_provider()
      org_id = Ash.UUID.generate()
      suppress!(org_id, @cus_id)
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(
        event(:invoice_payment_failed, refs()),
        opts(dref, mref, nil, notify: true, org_id: org_id)
      )

      job = latest_job("Samen.Delivery.Lifecycle.EmailWorker")
      assert {:error, :suppressed} = EmailWorker.perform(%Oban.Job{args: job.args})
      refute delivered_to?(org_id, @cus_id)
      assert FakeProvider.calls() == [], "a suppressed dunning email must NEVER reach the provider"
    end

    test "ANTI-TAUTOLOGY: an UNsuppressed recipient (different customer, same org) genuinely dispatches" do
      configure_fake_provider()
      org_id = Ash.UUID.generate()
      suppress!(org_id, "cus_other_suppressed")
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(
        event(:invoice_payment_failed, refs()),
        opts(dref, mref, nil, notify: true, org_id: org_id)
      )

      job = latest_job("Samen.Delivery.Lifecycle.EmailWorker")
      assert :ok = EmailWorker.perform(%Oban.Job{args: job.args})
      assert delivered_to?(org_id, @cus_id)
    end
  end
end
