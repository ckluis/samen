defmodule Samen.Billing.ProviderTest do
  @moduledoc """
  ADR-038 §3.1–§3.2 `Samen.Billing.Provider` behaviour conformance (T18/B1).

  Coverage:
    * The behaviour defines exactly the callbacks ADR-038 §3.1 specifies.
    * The fail-honest table (§3.2): `Samen.Billing.FakeProvider`, unconfigured,
      refuses EVERY callback except `configured?/1` and `redact_payload/1` with
      `{:error, :not_configured}` — never a fake `{:ok, _}`.
    * Anti-tautology (mirrors `Samen.Files.StorageTest`'s S3 discipline): a
      CONFIGURED fake genuinely records the call and returns real (fake-tagged)
      data, proving the refusal above is a real gate, not a constant.
    * `Samen.Scopes.Billing.SyncAdapter` (+ its tautological `Stub`) is gone —
      §3.6 supersession.
  """
  use ExUnit.Case, async: false

  alias Samen.Billing.{FakeProvider, Provider, ProviderEvent}

  setup do
    FakeProvider.reset()
    :ok
  end

  # ---------------------------------------------------------------------------
  # §3.1 — the behaviour defines exactly the ADR's callbacks.

  describe "Provider behaviour shape (§3.1)" do
    test "defines every callback the ADR specifies" do
      callbacks = Provider.behaviour_info(:callbacks)

      assert {:configured?, 1} in callbacks
      assert {:create_checkout_session, 2} in callbacks
      assert {:create_portal_session, 2} in callbacks
      assert {:cancel_subscription, 3} in callbacks
      assert {:change_subscription, 3} in callbacks
      assert {:fetch_object, 3} in callbacks
      assert {:report_usage, 2} in callbacks
      assert {:verify_and_parse_event, 3} in callbacks
      assert {:redact_payload, 1} in callbacks
      assert length(callbacks) == 9
    end
  end

  # ---------------------------------------------------------------------------
  # §3.2 — the fail-honest table: unconfigured refuses EVERY callback.

  describe "fail-honest table (§3.2): FakeProvider unconfigured" do
    test "configured?/1 is false by default (no live vendor, no live network)" do
      refute FakeProvider.configured?(%{})
      refute FakeProvider.configured?(%{configured: false})
    end

    test "create_checkout_session refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.create_checkout_session(%{}, %{})
    end

    test "create_portal_session refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.create_portal_session(%{}, %{})
    end

    test "cancel_subscription refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.cancel_subscription("sub_1", [], %{})
    end

    test "change_subscription refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.change_subscription("sub_1", %{}, %{})
    end

    test "fetch_object refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.fetch_object(:customer, "cus_1", %{})
    end

    test "report_usage refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.report_usage([%{}], %{})
    end

    test "verify_and_parse_event refuses with :not_configured" do
      assert {:error, :not_configured} = FakeProvider.verify_and_parse_event("{}", [], %{})
    end

    test "no call is recorded as successful while unconfigured (nothing to record)" do
      FakeProvider.create_checkout_session(%{}, %{})
      FakeProvider.fetch_object(:invoice, "in_1", %{})
      assert FakeProvider.calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # redact_payload/1 is exempt from the fail-honest gate (pure, no creds needed)
  # and does real work — proving it is not a pass-through no-op.

  describe "redact_payload/1 — exempt from configured?/1, genuinely strips PII" do
    test "runs even with an empty (unconfigured) config-independent call and strips known PII keys" do
      payload = %{email: "person@example.com", name: "Person", amount_cents: 500, currency: "usd"}
      redacted = FakeProvider.redact_payload(payload)

      refute Map.has_key?(redacted, :email)
      refute Map.has_key?(redacted, :name)
      assert redacted.amount_cents == 500
      assert redacted.currency == "usd"
    end
  end

  # ---------------------------------------------------------------------------
  # Anti-tautology: a CONFIGURED fake genuinely records + returns real data.

  describe "anti-tautology: a CONFIGURED FakeProvider is a real, call-recording double" do
    test "create_checkout_session returns a fake-tagged session and records the call" do
      config = %{configured: true}
      attrs = %{org_id: "org_1", plan_id: "plan_1", price_ref: "price_1"}

      assert {:ok, %{provider_session_id: sid, url: url, fake: true}} =
               FakeProvider.create_checkout_session(attrs, config)

      assert is_binary(sid)
      assert String.starts_with?(url, "https://")
      assert [{:create_checkout_session, ^attrs}] = FakeProvider.calls()
    end

    test "fetch_object returns a fake-tagged normalized object and records the call" do
      config = %{configured: true}

      assert {:ok, %{kind: :subscription, provider_id: "sub_42", fake: true}} =
               FakeProvider.fetch_object(:subscription, "sub_42", config)

      assert [{:fetch_object, %{kind: :subscription, provider_id: "sub_42"}}] = FakeProvider.calls()
    end

    test "verify_and_parse_event returns a real %ProviderEvent{} struct when configured" do
      assert {:ok, %ProviderEvent{provider: :fake, kind: :unhandled}} =
               FakeProvider.verify_and_parse_event("{}", [], %{configured: true})
    end

    test "report_usage counts the batch honestly (reported == length(batch))" do
      batch = [%{id: "u1"}, %{id: "u2"}, %{id: "u3"}]
      assert {:ok, %{reported: 3}} = FakeProvider.report_usage(batch, %{configured: true})
    end
  end

  # ---------------------------------------------------------------------------
  # §3.6 supersession — the old tautological stub is gone.

  describe "§3.6 supersession: SyncAdapter + its always-:ok Stub no longer exist" do
    test "Samen.Scopes.Billing.SyncAdapter is gone" do
      refute Code.ensure_loaded?(Samen.Scopes.Billing.SyncAdapter)
    end

    test "Samen.Scopes.Billing.SyncAdapter.Stub is gone" do
      refute Code.ensure_loaded?(Samen.Scopes.Billing.SyncAdapter.Stub)
    end
  end
end
