defmodule Samen.Delivery.DeliverabilityTest do
  @moduledoc """
  C4 (T30) — the deliverability-webhook DOMAIN pipeline (ADR-038 §4.4; handoff
  done-criteria 1-2).

  `samen_core` is vendor-free (INV-4) and cannot depend on `samen_postmark`, so
  the `ProviderEvent` structs here are hand-constructed to the EXACT shape
  `samen_postmark/test/deliverability_test.exs` proves `SamenPostmark.Provider.
  verify_and_parse_event/3` produces for real Postmark Bounce/SpamComplaint
  fixture bodies (same `kind`, same `provider_message_id` extraction, same
  redacted-payload posture) — see that file's moduledoc for the split
  rationale. Together the two files prove the FULL C4 pipeline: real Postmark
  fixture -> adapter parse -> domain match -> `EmailEvent`/`Suppression` rows ->
  `Chokepoint` refuses the next send.

  Coverage:

    1. Bounce -> `EmailEvent` + `Suppression` row; complaint likewise.
    2. The suppressed address is then REFUSED by the REAL T28
       `Samen.Delivery.Chokepoint`, wired to the REAL T30
       `Samen.Delivery.SuppressionCheck` backing store (not a test fake) —
       closes the GAP T28 named.
    3. Unmatched events (no receipt) retry (`{:error, :no_matching_receipt}`),
       never fabricate a match.
    4. `:delivered` records an `EmailEvent`, never a `Suppression` row.
    5. Open/click consent-aware gate (c9): flag OFF -> dropped (red); flag ON,
       no consent -> STILL dropped; flag ON + consent -> recorded (control).
    6. Idempotency: replaying the SAME provider event twice never double-records.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.{Chokepoint, Deliverability, EmailEvent, FakeProvider, ProviderEvent, Suppression, SuppressionCheck}
  alias Samen.Delivery.Message
  alias Samen.FeatureFlags.Cache
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    # The "delivery.open_click_tracking" flag name is shared across every
    # test in this file — invalidate the shared ETS cache so one test's
    # :loader override (or the real absent-config default) never leaks into
    # another (mirrors feature_flags_engine_test.exs's own discipline).
    Cache.invalidate_all()

    prev = Application.get_env(:samen_core, Chokepoint)
    prev_check = Application.get_env(:samen_core, SuppressionCheck)

    # Wire the REAL production suppression store (T30 closes the T28 GAP) —
    # Chokepoint -> SuppressionCheck -> Suppression (dlv_suppression), not a
    # test-injected fake.
    Application.put_env(:samen_core, Chokepoint, suppression_module: SuppressionCheck)
    Application.put_env(:samen_core, SuppressionCheck, repo: TestRepo)

    FakeProvider.reset()

    on_exit(fn ->
      if prev, do: Application.put_env(:samen_core, Chokepoint, prev), else: Application.delete_env(:samen_core, Chokepoint)

      if prev_check,
        do: Application.put_env(:samen_core, SuppressionCheck, prev_check),
        else: Application.delete_env(:samen_core, SuppressionCheck)

      Cache.invalidate_all()
    end)

    :ok
  end

  defp org_id, do: Ash.UUID.generate()
  defp subscriber_id, do: Ash.UUID.generate()
  defp send_id, do: Ash.UUID.generate()

  defp receipt(org, subscriber, send) do
    fn
      "match-me" -> {:ok, %{send_id: send, org_id: org, subscriber_id: subscriber}}
      _ -> :not_found
    end
  end

  defp bounce_event(provider_message_id \\ "match-me", event_id \\ nil) do
    %ProviderEvent{
      provider: :postmark,
      event_id: event_id || "evt-bounce-#{System.unique_integer([:positive])}",
      kind: :bounce,
      provider_message_id: provider_message_id,
      occurred_at: DateTime.utc_now(),
      # Already redacted, exactly as SamenPostmark.Provider.redact_payload/1
      # would leave it (structural fields only — no PII).
      payload: %{"MessageID" => provider_message_id, "Type" => "HardBounce"}
    }
  end

  defp complaint_event(provider_message_id \\ "match-me", event_id \\ nil) do
    %ProviderEvent{
      provider: :postmark,
      event_id: event_id || "evt-complaint-#{System.unique_integer([:positive])}",
      kind: :complaint,
      provider_message_id: provider_message_id,
      occurred_at: DateTime.utc_now(),
      payload: %{"MessageID" => provider_message_id, "Type" => "SpamComplaint"}
    }
  end

  defp delivered_event(provider_message_id \\ "match-me") do
    %ProviderEvent{
      provider: :postmark,
      event_id: "evt-delivered-#{System.unique_integer([:positive])}",
      kind: :delivered,
      provider_message_id: provider_message_id,
      occurred_at: DateTime.utc_now(),
      payload: %{"MessageID" => provider_message_id}
    }
  end

  defp open_event(provider_message_id \\ "match-me") do
    %ProviderEvent{
      provider: :postmark,
      event_id: "evt-open-#{System.unique_integer([:positive])}",
      kind: :open,
      provider_message_id: provider_message_id,
      occurred_at: DateTime.utc_now(),
      payload: %{"MessageID" => provider_message_id}
    }
  end

  # ---------------------------------------------------------------------------
  # 1. Bounce / complaint -> EmailEvent + Suppression.

  describe "bounce fixture => EmailEvent + Suppression row (handoff done-criterion 1)" do
    test "records a matched EmailEvent AND suppresses (org_id, subscriber_id)" do
      org = org_id()
      sub = subscriber_id()
      snd = send_id()

      assert :ok =
               Deliverability.handle_event(bounce_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, snd)
               )

      [row] = EmailEvent.list_for_subscriber(TestRepo, org, sub)
      assert row.kind == "bounce"
      assert row.send_id == snd
      assert row.provider == "postmark"

      assert Suppression.suppressed?(TestRepo, org, sub)
      suppression = Suppression.get(TestRepo, org, sub)
      assert suppression.reason == "bounce"
      assert suppression.source_provider == "postmark"
    end
  end

  describe "complaint fixture => EmailEvent + Suppression row (handoff done-criterion 1)" do
    test "records a matched EmailEvent AND suppresses" do
      org = org_id()
      sub = subscriber_id()
      snd = send_id()

      assert :ok =
               Deliverability.handle_event(complaint_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, snd)
               )

      [row] = EmailEvent.list_for_subscriber(TestRepo, org, sub)
      assert row.kind == "complaint"

      assert Suppression.suppressed?(TestRepo, org, sub)
      assert Suppression.get(TestRepo, org, sub).reason == "complaint"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. The suppressed address is refused by the REAL T28 Chokepoint (integration).

  describe "suppressed address then refused by the T28 chokepoint (integration assert)" do
    test "RED: a bounced recipient's next send is refused, FakeProvider.deliver/2 never called" do
      org = org_id()
      sub = subscriber_id()

      assert :ok =
               Deliverability.handle_event(bounce_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id())
               )

      Application.put_env(:samen_core, :delivery_provider, {FakeProvider, %{configured: true}})
      on_exit(fn -> Application.delete_env(:samen_core, :delivery_provider) end)

      message = %Message{send_id: Ash.UUID.generate(), org_id: org, to_subscriber_id: sub}

      assert {:error, :suppressed} = Chokepoint.send(message, env: :test)

      refute Enum.any?(FakeProvider.calls(), fn
               {:deliver, %{message: m}} -> m.org_id == org and m.to_subscriber_id == sub
               _ -> false
             end)
    end

    test "CONTROL: an unrelated (never-bounced) recipient sends normally through the SAME chokepoint" do
      org = org_id()
      bounced_sub = subscriber_id()
      clean_sub = subscriber_id()

      assert :ok =
               Deliverability.handle_event(bounce_event("clean-control-msg"),
                 repo: TestRepo,
                 receipt_lookup: fn
                   "clean-control-msg" -> {:ok, %{send_id: send_id(), org_id: org, subscriber_id: bounced_sub}}
                   _ -> :not_found
                 end
               )

      Application.put_env(:samen_core, :delivery_provider, {FakeProvider, %{configured: true}})
      on_exit(fn -> Application.delete_env(:samen_core, :delivery_provider) end)

      message = %Message{send_id: Ash.UUID.generate(), org_id: org, to_subscriber_id: clean_sub}

      assert {:ok, _receipt} = Chokepoint.send(message, env: :test)

      assert Enum.any?(FakeProvider.calls(), fn
               {:deliver, %{message: m}} -> m.org_id == org and m.to_subscriber_id == clean_sub
               _ -> false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Unmatched events retry, never fabricate a match.

  describe "unmatched events (no receipt) never fabricate a match" do
    test "returns {:error, :no_matching_receipt}; no EmailEvent/Suppression row written" do
      org = org_id()
      sub = subscriber_id()

      assert {:error, :no_matching_receipt} =
               Deliverability.handle_event(bounce_event("unknown-msg-id"),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id())
               )

      assert EmailEvent.list_for_subscriber(TestRepo, org, sub) == []
      refute Suppression.suppressed?(TestRepo, org, sub)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. :delivered records an EmailEvent, never a Suppression row.

  describe "delivered events record ONLY an EmailEvent (never suppress)" do
    test "a delivered event does not touch Suppression" do
      org = org_id()
      sub = subscriber_id()

      assert :ok =
               Deliverability.handle_event(delivered_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id())
               )

      [row] = EmailEvent.list_for_subscriber(TestRepo, org, sub)
      assert row.kind == "delivered"
      refute Suppression.suppressed?(TestRepo, org, sub)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Open/click consent-aware gate (c9) — default OFF.

  defmodule AlwaysConsents do
    def consented?(_org_id, _subscriber_id), do: true
  end

  defmodule NeverConsents do
    def consented?(_org_id, _subscriber_id), do: false
  end

  describe "open/click: consent-aware flag (c9)" do
    test "RED: flag OFF => events ignored, even with consent" do
      org = org_id()
      sub = subscriber_id()

      assert :ok =
               Deliverability.handle_event(open_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id()),
                 tracking_consent_module: AlwaysConsents,
                 flag_evaluate_opts: [loader: fn _ -> {:ok, nil} end]
               )

      assert EmailEvent.list_for_subscriber(TestRepo, org, sub) == []
    end

    test "RED: flag ON, NO consent => events still ignored" do
      org = org_id()
      sub = subscriber_id()

      assert :ok =
               Deliverability.handle_event(open_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id()),
                 tracking_consent_module: NeverConsents,
                 flag_evaluate_opts: [loader: fn _ -> {:ok, %{enabled: true, rollout_pct: 100, target_rules: [], variants: %{}}} end]
               )

      assert EmailEvent.list_for_subscriber(TestRepo, org, sub) == []
    end

    test "CONTROL: flag ON + consent => recorded" do
      org = org_id()
      sub = subscriber_id()

      assert :ok =
               Deliverability.handle_event(open_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id()),
                 tracking_consent_module: AlwaysConsents,
                 flag_evaluate_opts: [loader: fn _ -> {:ok, %{enabled: true, rollout_pct: 100, target_rules: [], variants: %{}}} end]
               )

      [row] = EmailEvent.list_for_subscriber(TestRepo, org, sub)
      assert row.kind == "open"
    end

    test "default posture (no flag row configured anywhere) is OFF — c9's default" do
      org = org_id()
      sub = subscriber_id()

      # No :flag_evaluate_opts at all — exercises the REAL default loader path
      # (an unseen flag name resolves OFF, RP-F4 fail-safe), proving c9's
      # "ships default-OFF" claim without any test-only override.
      assert :ok =
               Deliverability.handle_event(open_event(),
                 repo: TestRepo,
                 receipt_lookup: receipt(org, sub, send_id()),
                 tracking_consent_module: AlwaysConsents
               )

      assert EmailEvent.list_for_subscriber(TestRepo, org, sub) == []
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Idempotency — replaying the same event never double-records.

  describe "idempotency: replaying the SAME provider event never double-records" do
    test "a duplicate bounce (same provider + event_id) is a safe no-op" do
      org = org_id()
      sub = subscriber_id()
      event = bounce_event("match-me", "evt-fixed-id-for-replay")

      assert :ok = Deliverability.handle_event(event, repo: TestRepo, receipt_lookup: receipt(org, sub, send_id()))
      assert :ok = Deliverability.handle_event(event, repo: TestRepo, receipt_lookup: receipt(org, sub, send_id()))

      assert length(EmailEvent.list_for_subscriber(TestRepo, org, sub)) == 1
    end
  end
end
