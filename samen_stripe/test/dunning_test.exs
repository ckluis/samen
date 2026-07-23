defmodule SamenStripe.DunningTest do
  @moduledoc """
  B7 dunning (T24) — the done-criteria, proven end-to-end and hermetically
  (ADR-038 §3.5; keyless lane 0, §7.1).

  The FULL real path runs with no network and no Stripe credential:

      signed Stripe webhook body
        → SamenStripe.Provider.verify_and_parse_event/3   (real Stripe t=,v1= scheme)
        → Samen.Billing.ProviderEvent (normalized, PII-redacted)
        → Samen.Billing.Dunning.reconcile/2 | .recover/2   (vendor-generic dunning logic)
        → SamenStripe.Provider.fetch_object/3              (authoritative re-fetch — §3.4(1))
             served by a CASSETTE transport (config[:transport], §7.2)
        → Samen.Billing.FakeDunningMirror                  (the in-memory case mirror)
        → Samen.Billing.FakeMirror.apply_entitlement/3      (the grace/recovery seam)

  Done-criteria:
    1. a payment_failed fixture opens a dunning case; a SECOND payment_failed
       fixture for the SAME invoice advances the retry schedule
       (attempt_count / next_payment_attempt) on the SAME row (mirrored
       provider truth, never invented here); a recovery fixture (`invoice.paid`)
       closes it. The exact same event replayed twice is a no-op.
    2. grace-period policy: entitlement remains active THROUGH the failing
       invoice's period end (even though payment failed) — asserted before
       AND after that boundary via the SAME `expires_at`-vs-`now` predicate
       `Samen.Scopes.Billing.Entitlement` uses in production; a recovered
       payment restores full access (control: `expires_at` cleared, entitled
       at any time).

  `notify: false` is passed throughout — the delivery-chokepoint/suppression
  proof (done-criterion 3) lives in `samen_core/test/billing_dunning_test.exs`,
  where Oban + the TestRepo sandbox are actually available (`samen_stripe`'s
  test env is pure `ExUnit.start()`, no DB — see that file's moduledoc for why).
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{Dunning, FakeDunningMirror, FakeMirror, ProviderEvent}
  alias Samen.Webhook.Signer
  alias SamenStripe.Provider

  @secret "whsec_test_5f3a9c2b1d4e6f8a0c2e4b6d8f0a1c3e"
  @secret_key "sk_test_dunning"

  @invoice_id "in_dunning_1"
  @cus_id "cus_dunning_1"
  @sub_id "sub_dunning_1"

  @t1_unix 1_782_300_000
  @t2_unix 1_782_900_000
  @t3_unix 1_783_100_000
  @grace_until DateTime.from_unix!(1_784_600_000)

  # Mirrors `Samen.Scopes.Billing.Entitlement`'s own predicate: granted &&
  # (expires_at is nil OR expires_at is in the future).
  defp entitled?(row, now),
    do: row.granted == true and (is_nil(row.expires_at) or DateTime.compare(row.expires_at, now) == :gt)

  # --- cassette + event helpers ----------------------------------------------

  defp fixture(name) do
    Path.join([__DIR__, "fixtures", name])
    |> File.read!()
    |> Jason.decode!()
  end

  defp cassette(fixture_name) do
    body = fixture(fixture_name)
    fn %{method: :get} -> {:ok, %{status: 200, body: body}} end
  end

  defp config(fixture_name) do
    %{secret_key: @secret_key, transport: cassette(fixture_name)}
  end

  # Build + sign + parse a real Stripe invoice webhook, returning the
  # normalized ProviderEvent (exercising the real signature-verify + parse
  # path). The webhook object IS the invoice — id/customer/subscription are
  # recovered from it exactly as `SamenStripe.Provider.extract_refs/1` does
  # for a live delivery.
  defp event(stripe_type, created_unix) do
    body =
      Jason.encode!(%{
        "id" => "evt_#{stripe_type}_#{created_unix}_#{System.unique_integer([:positive])}",
        "type" => stripe_type,
        "created" => created_unix,
        "data" => %{
          "object" => %{
            "id" => @invoice_id,
            "object" => "invoice",
            "customer" => @cus_id,
            "subscription" => @sub_id
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

  defp opts(fixture_name, dunning_ref, mirror_ref) do
    [
      provider: Provider,
      provider_config: config(fixture_name),
      dunning_mirror: FakeDunningMirror,
      dunning_mirror_ref: dunning_ref,
      mirror: FakeMirror,
      mirror_ref: mirror_ref,
      notify: false
    ]
  end

  # ---------------------------------------------------------------------------
  # done-criterion 1 — open / advance / recover, idempotent
  # ---------------------------------------------------------------------------

  describe "done-criterion 1 — payment_failed opens a case; retries advance it; recovery closes it" do
    test "invoice.payment_failed opens a dunning case mirroring the fixture's retry-schedule fields" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :applied, _} =
               Dunning.reconcile(
                 event("invoice.payment_failed", @t1_unix),
                 opts("invoice_payment_failed_1.json", dref, mref)
               )

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :open
      assert c.provider_subscription_id == @sub_id
      assert c.attempt_count == 1
      assert c.next_payment_attempt == DateTime.from_unix!(1_782_400_000)
      assert c.grace_until == @grace_until
    end

    test "a SECOND payment_failed fixture for the SAME invoice advances the retry schedule on the SAME row" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :applied, _} =
               Dunning.reconcile(
                 event("invoice.payment_failed", @t1_unix),
                 opts("invoice_payment_failed_1.json", dref, mref)
               )

      assert {:ok, :applied, _} =
               Dunning.reconcile(
                 event("invoice.payment_failed", @t2_unix),
                 opts("invoice_payment_failed_2.json", dref, mref)
               )

      # TWO writes, but still ONE case row (keyed on the ONE invoice) — not a
      # duplicate case, a genuine re-mirror of the same row.
      assert FakeDunningMirror.change_count(dref) == 2

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.attempt_count == 2
      assert c.next_payment_attempt == DateTime.from_unix!(1_783_000_000)
    end

    test "the exact same event replayed twice is a no-op (single change)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      ev = event("invoice.payment_failed", @t1_unix)
      o = opts("invoice_payment_failed_1.json", dref, mref)

      assert {:ok, :applied, _} = Dunning.reconcile(ev, o)
      assert {:ok, :duplicate} = Dunning.reconcile(ev, o)

      assert FakeDunningMirror.change_count(dref) == 1
    end

    test "invoice.paid closes an open case (recovery)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(event("invoice.payment_failed", @t1_unix), opts("invoice_payment_failed_1.json", dref, mref))

      assert {:ok, :recovered, _} =
               Dunning.recover(event("invoice.paid", @t3_unix), opts("invoice_paid_recovered.json", dref, mref))

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :recovered
    end

    test "invoice.paid for an invoice that never failed is a true no-op (no case ever opened)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :ignored} =
               Dunning.recover(event("invoice.paid", @t3_unix), opts("invoice_paid_recovered.json", dref, mref))

      assert FakeDunningMirror.get_case(dref, @invoice_id) == nil
      assert FakeDunningMirror.change_count(dref) == 0
    end

    test "recovery replayed twice is a no-op (single recovered change)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(event("invoice.payment_failed", @t1_unix), opts("invoice_payment_failed_1.json", dref, mref))
      recovery_ev = event("invoice.paid", @t3_unix)
      o = opts("invoice_paid_recovered.json", dref, mref)

      assert {:ok, :recovered, _} = Dunning.recover(recovery_ev, o)
      assert {:ok, :duplicate} = Dunning.recover(recovery_ev, o)

      # 1 change opening the case + 1 change recovering it — the replayed
      # recover call adds NO third change.
      assert FakeDunningMirror.change_count(dref) == 2
    end

    test "ATTEMPT 2 FIX: a stale payment_failed (distinct event_id, older than the recovery) never re-opens the case" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      Dunning.reconcile(event("invoice.payment_failed", @t1_unix), opts("invoice_payment_failed_1.json", dref, mref))
      Dunning.recover(event("invoice.paid", @t3_unix), opts("invoice_paid_recovered.json", dref, mref))

      # A stale, DISTINCT-event-id failure between t1 and t3 (older than the
      # recovery watermark) — must be discarded, never re-opening the case.
      stale_unix = 1_782_500_000

      assert {:ok, :stale} =
               Dunning.reconcile(
                 event("invoice.payment_failed", stale_unix),
                 opts("invoice_payment_failed_1.json", dref, mref)
               )

      c = FakeDunningMirror.get_case(dref, @invoice_id)
      assert c.status == :recovered
      assert FakeDunningMirror.change_count(dref) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 2 — grace-period entitlement policy
  # ---------------------------------------------------------------------------

  describe "done-criterion 2 — grace-period entitlement: active through grace end, then drops; recovery restores" do
    test "entitlement remains active until the invoice's period end (grace), then drops" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      assert {:ok, :applied, _} =
               Dunning.reconcile(
                 event("invoice.payment_failed", @t1_unix),
                 opts("invoice_payment_failed_1.json", dref, mref)
               )

      [ent] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent.expires_at == @grace_until

      # Before grace end: still entitled (the payment-failure grace holds).
      assert entitled?(ent, DateTime.add(@grace_until, -3600, :second))
      # After grace end (no recovery arrived): entitlement has dropped.
      refute entitled?(ent, DateTime.add(@grace_until, 3600, :second))
    end

    test "a recovered payment restores full access (control: expires_at cleared)" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()
      FakeMirror.seed_entitlement(mref, @sub_id, :advanced_reporting)

      Dunning.reconcile(event("invoice.payment_failed", @t1_unix), opts("invoice_payment_failed_1.json", dref, mref))

      [ent_before] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent_before.expires_at == @grace_until

      assert {:ok, :recovered, _} =
               Dunning.recover(event("invoice.paid", @t3_unix), opts("invoice_paid_recovered.json", dref, mref))

      [ent_after] = FakeMirror.list_entitlements(mref, @sub_id)
      assert ent_after.expires_at == nil

      # Entitled at ANY time now — including well past the old grace boundary.
      assert entitled?(ent_after, DateTime.add(@grace_until, 365 * 86_400, :second))
    end
  end

  # ---------------------------------------------------------------------------
  # routing — any other kind is a defensive no-op
  # ---------------------------------------------------------------------------

  describe "reconcile/2 and recover/2 — any other kind is a defensive no-op" do
    test "reconcile/2 ignores a non-payment-failed kind" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :ignored} =
               Dunning.reconcile(event("invoice.finalized", @t1_unix), opts("invoice_payment_failed_1.json", dref, mref))

      assert FakeDunningMirror.change_count(dref) == 0
    end

    test "recover/2 ignores a non-invoice-paid kind" do
      dref = FakeDunningMirror.new()
      mref = FakeMirror.new()

      assert {:ok, :ignored} =
               Dunning.recover(
                 event("invoice.payment_failed", @t1_unix),
                 opts("invoice_payment_failed_1.json", dref, mref)
               )

      assert FakeDunningMirror.change_count(dref) == 0
    end
  end
end
