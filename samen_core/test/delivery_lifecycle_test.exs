defmodule Samen.Delivery.LifecycleTest do
  @moduledoc """
  ADR-014 fail-honest boundary carried to TRANSACTIONAL LIFECYCLE EMAILS (F7 G11).

  The lifecycle worker (`Samen.Delivery.Lifecycle.EmailWorker`) is the
  transactional sibling of `Samen.Scopes.Marketing.SendWorker`: it dispatches
  event-triggered lifecycle mail (welcome/onboarding/trial-ending/payment-failed/
  subscription-cancelled) through the SAME `Samen.Delivery.Adapter` boundary under
  the SAME Invariant D1.

  AC coverage:
    * GREEN — with `LocalSink` (test env / configured adapter) an enqueued
      lifecycle email reaches the `:sent` terminal via a *configured* adapter that
      returned `{:ok, _}`.
    * RED (D1) — an UNCONFIGURED adapter in a non-`:test` env is NOT `:sent`
      (`{:error, :adapter_unconfigured}`); NO decision branch routes an
      unconfigured/failed adapter to `:sent`.
    * Anti-tautology — a CONFIGURED adapter IS routed to `:deliver` / returns `:ok`,
      so the blocked/refusal assertions are provably non-vacuous.
    * Token-only — bounded event enum + opaque ids only; an unbounded/absent event
      is discarded, never delivered.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.{Adapter, LocalSink, Message}
  alias Samen.Delivery.Lifecycle
  alias Samen.Delivery.Lifecycle.EmailWorker

  # A configured, always-succeeding adapter (anti-tautology green).
  defmodule OkAdapter do
    @behaviour Adapter
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{} = m, _config), do: {:ok, %{provider_id: "life-#{m.send_id}"}}
  end

  # A configured adapter that fails dispatch (RP-D2).
  defmodule ErrAdapter do
    @behaviour Adapter
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{}, _config), do: {:error, :esp_timeout}
  end

  # An adapter whose configured?/1 is false (creds absent) — must NOT be sent.
  defmodule UnconfiguredAdapter do
    @behaviour Adapter
    @impl true
    def configured?(_config), do: false
    @impl true
    def deliver(%Message{}, _config), do: {:ok, %{lie: true}}
  end

  defp job(args), do: %Oban.Job{args: args}

  defp args(overrides \\ %{}) do
    Map.merge(
      %{
        "send_id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "org_id" => "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        "subscriber_id" => "cccccccc-cccc-cccc-cccc-cccccccccccc",
        "event" => "subscription_cancelled"
      },
      overrides
    )
  end

  setup do
    # Oban.insert (enqueue seam tests) writes an oban_jobs row via the test repo.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SamenCore.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(SamenCore.TestRepo, {:shared, self()})

    prev = Application.get_env(:samen_core, EmailWorker)
    prev_mkt = Application.get_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
    prev_env = Application.get_env(:samen_core, :delivery_env)

    on_exit(fn ->
      restore(EmailWorker, prev)
      restore(Samen.Scopes.Marketing.SendWorker, prev_mkt)

      if prev_env,
        do: Application.put_env(:samen_core, :delivery_env, prev_env),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  # ---------------------------------------------------------------------------
  # Bounded event enum (token-only args).

  describe "lifecycle event enum (token-only)" do
    test "events/0 is the bounded lifecycle set" do
      assert EmailWorker.events() ==
               ~w(welcome onboarding trial_ending payment_failed subscription_cancelled)
    end

    test "valid_event?/1 accepts recognised events (string or atom), rejects free text" do
      assert EmailWorker.valid_event?("welcome")
      assert EmailWorker.valid_event?(:payment_failed)
      refute EmailWorker.valid_event?("../../etc/passwd")
      refute EmailWorker.valid_event?("arbitrary")
      refute EmailWorker.valid_event?(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-honest decision (EmailWorker.decide/3) — Invariant D1 carried.

  describe "fail-honest decision (EmailWorker.decide/3)" do
    test "RP-D1: nil adapter in a non-:test env is BLOCKED, never sent" do
      assert {:blocked, :adapter_unconfigured} = EmailWorker.decide(nil, %{}, :prod)
      assert {:blocked, :adapter_unconfigured} = EmailWorker.decide(nil, %{}, :dev)
    end

    test "RP-D1: an adapter whose configured?/1 is false is BLOCKED, never sent" do
      assert {:blocked, :adapter_unconfigured} =
               EmailWorker.decide(UnconfiguredAdapter, %{}, :prod)
    end

    test "no branch routes an unconfigured adapter to :deliver in any non-test env" do
      for env <- [:prod, :dev, :staging] do
        assert {:blocked, :adapter_unconfigured} = EmailWorker.decide(nil, %{}, env)
        assert {:blocked, :adapter_unconfigured} =
                 EmailWorker.decide(UnconfiguredAdapter, %{}, env)
      end
    end

    test "anti-tautology (RP-D1 non-vacuous): a CONFIGURED adapter is routed to :deliver" do
      assert {:deliver, OkAdapter, %{}} = EmailWorker.decide(OkAdapter, %{}, :prod)
    end

    test ":test env falls back to LocalSink for a nil adapter (honest capture, not a prod lie)" do
      assert {:deliver, LocalSink, %{}} = EmailWorker.decide(nil, %{}, :test)
    end

    test "LocalSink is NEVER the fallback in a non-:test env" do
      assert {:blocked, _} = EmailWorker.decide(nil, %{}, :prod)
      assert {:blocked, _} = EmailWorker.decide(nil, %{}, :dev)
    end
  end

  # ---------------------------------------------------------------------------
  # perform/1 honors the adapter outcome (GREEN + RED-D1 + RED-D2).

  describe "perform/1 honors adapter outcome" do
    test "GREEN: adapter {:ok, receipt} → perform returns :ok (the :sent path)" do
      Application.put_env(:samen_core, EmailWorker, adapter: OkAdapter, adapter_config: %{})
      assert EmailWorker.perform(job(args())) == :ok
    end

    test "GREEN: default LocalSink in :test env captures the lifecycle email → :ok" do
      # No adapter wired + env resolves to :test → LocalSink honest capture.
      Application.delete_env(:samen_core, EmailWorker)
      Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
      Application.put_env(:samen_core, :delivery_env, :test)
      assert EmailWorker.perform(job(args())) == :ok
    end

    test "RP-D2: adapter {:error, reason} → {:error, reason}, provably NOT sent" do
      Application.put_env(:samen_core, EmailWorker, adapter: ErrAdapter, adapter_config: %{})
      assert {:error, :esp_timeout} = EmailWorker.perform(job(args()))
    end

    test "RP-D1 (integration): unconfigured adapter in non-:test env → job errors, not :ok" do
      Application.put_env(:samen_core, EmailWorker, adapter: UnconfiguredAdapter)
      Application.put_env(:samen_core, :delivery_env, :prod)

      result = EmailWorker.perform(job(args()))
      assert {:error, :adapter_unconfigured} = result
      refute result == :ok, "a blocked lifecycle email must NEVER return :ok (the sent signal)"
    end

    test "RP-D1 (integration): NO adapter at all in non-:test env → blocked, not :ok" do
      Application.delete_env(:samen_core, EmailWorker)
      Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
      Application.put_env(:samen_core, :delivery_env, :prod)

      assert {:error, :adapter_unconfigured} = EmailWorker.perform(job(args()))
    end

    test "malformed args (no send_id) are discarded, never sent" do
      assert {:discard, _} =
               EmailWorker.perform(job(%{"org_id" => "x", "event" => "welcome"}))
    end

    test "unbounded/absent event is discarded, never sent (token-only)" do
      assert {:discard, _} = EmailWorker.perform(job(args(%{"event" => "arbitrary_free_text"})))
      assert {:discard, _} = EmailWorker.perform(job(Map.delete(args(), "event")))
    end
  end

  # ---------------------------------------------------------------------------
  # Marketing-adapter fallback (a host wires ONE adapter → lifecycle uses it).

  describe "marketing adapter fallback" do
    test "a configured marketing adapter is reused when no lifecycle adapter is set" do
      Application.delete_env(:samen_core, EmailWorker)

      Application.put_env(:samen_core, Samen.Scopes.Marketing.SendWorker,
        adapter: OkAdapter,
        adapter_config: %{}
      )

      Application.put_env(:samen_core, :delivery_env, :prod)
      assert EmailWorker.perform(job(args())) == :ok
    end

    test "a nil marketing adapter does NOT rescue a nil lifecycle adapter (D1 holds)" do
      Application.delete_env(:samen_core, EmailWorker)
      Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
      Application.put_env(:samen_core, :delivery_env, :prod)

      # resolve_adapter/0 must stay nil → decide → blocked (never a fake sink send).
      assert EmailWorker.resolve_adapter() == nil
      assert {:error, :adapter_unconfigured} = EmailWorker.perform(job(args()))
    end
  end

  # ---------------------------------------------------------------------------
  # The enqueue seam (Samen.Delivery.Lifecycle.deliver/2) — fail-closed + best-effort.

  describe "enqueue seam: Lifecycle.deliver/2" do
    test "an unrecognised event is SKIPPED (nothing enqueued, fail-closed)" do
      assert {:ok, :skipped} =
               Lifecycle.deliver(:not_a_real_event, org_id: "o", subscriber_id: "s")
    end

    test "a missing subscriber ref is SKIPPED (nothing enqueued)" do
      assert {:ok, :skipped} = Lifecycle.deliver(:welcome, org_id: "o")
    end

    test "a missing org ref is SKIPPED (nothing enqueued)" do
      assert {:ok, :skipped} = Lifecycle.deliver(:welcome, subscriber_id: "s")
    end

    test "a valid event + refs builds token-only args and enqueues via Oban" do
      # Oban testing: :manual mode captures the job without executing it.
      assert {:ok, %Oban.Job{worker: worker, args: args}} =
               Lifecycle.deliver(:subscription_cancelled,
                 org_id: "org-1",
                 subscriber_id: "sub-1",
                 template_id: "tpl-1"
               )

      assert worker == "Samen.Delivery.Lifecycle.EmailWorker"
      assert args["event"] == "subscription_cancelled"
      assert args["org_id"] == "org-1"
      assert args["subscriber_id"] == "sub-1"
      assert args["template_id"] == "tpl-1"
      assert is_binary(args["send_id"]) and args["send_id"] != ""

      # Token-only: NO plaintext-PII-shaped keys in the persisted args.
      refute Map.has_key?(args, "email")
      refute Map.has_key?(args, "to")
      refute Map.has_key?(args, "recipient_email")
    end

    test ":customer_id is accepted as the subscriber ref (billing-friendly alias)" do
      assert {:ok, %Oban.Job{args: args}} =
               Lifecycle.deliver(:payment_failed, org_id: "org-1", customer_id: "cust-9")

      assert args["subscriber_id"] == "cust-9"
      assert args["event"] == "payment_failed"
    end
  end

  # ---------------------------------------------------------------------------
  # Worker Oban options (queue/idempotency invariants).

  describe "EmailWorker Oban options" do
    test "runs in the :webhooks_out queue with capped attempts and per-send unique" do
      assert EmailWorker.__opts__()[:queue] == :webhooks_out
      assert EmailWorker.__opts__()[:max_attempts] == 20
      assert EmailWorker.__opts__()[:unique][:period] == 60
    end
  end
end
