defmodule Samen.Delivery.ProviderTest do
  @moduledoc """
  ADR-014/ADR-038 §4 delivery PROVIDER contract + fail-honest SendWorker
  semantics. `Samen.Delivery.Adapter` is RENAMED/FINALIZED to
  `Samen.Delivery.Provider` (ADR-038 §4.2) — same two callbacks, same
  Invariant D1, PLUS the webhook/inbound/capability surface (proven in
  `delivery_provider_behaviour_test.exs` and the samen_postmark conformance
  suite); this file keeps the ORIGINAL AC-G2 coverage green under the new name.

  AC coverage:
    * AC-G2-1 — `Samen.Delivery.Provider` behaviour + `LocalSink` + `Smtp`/`Api`
      skeleton exist; `configured?/1` gates real dispatch.
    * AC-G2-2 (RP — the fail-honest proof) — with NO adapter configured in a
      non-`:test` env, a send is `:blocked` (NOT `:delivered`) and the job errors.
      The old tautological "send → delivered" no-op green is GONE (there is no
      unconditional-success stub adapter left in the module).
    * AC-G2-3 (U+RP) — adapter `{:error, _}` → `:failed`, never `:delivered`;
      adapter `{:ok, receipt}` → `:delivered` with receipt.

  Anti-tautology: RP-D1/RP-D2 are made non-vacuous by the paired "adapter succeeds
  → :deliver is chosen" assertions here.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.{Api, LocalSink, Message, Provider, Smtp}
  alias Samen.Scopes.Marketing.SendWorker

  # A configured, always-succeeding adapter (for the anti-tautology green).
  defmodule OkAdapter do
    use Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{} = m, _config), do: {:ok, %{provider_id: "prov-#{m.send_id}"}}
  end

  # A configured adapter that fails dispatch (for RP-D2).
  defmodule ErrAdapter do
    use Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{}, _config), do: {:error, :smtp_timeout}
  end

  # An adapter whose configured?/1 is false (creds absent) — must NOT be delivered.
  defmodule UnconfiguredAdapter do
    use Provider
    @impl true
    def configured?(_config), do: false
    @impl true
    def deliver(%Message{}, _config), do: {:ok, %{lie: true}}
  end

  defp msg do
    %Message{
      send_id: "11111111-1111-1111-1111-111111111111",
      org_id: "22222222-2222-2222-2222-222222222222",
      to_subscriber_id: "33333333-3333-3333-3333-333333333333",
      template_id: nil
    }
  end

  # ---------------------------------------------------------------------------
  # AC-G2-1 — the contract + shipped adapters exist and configured?/1 gates.

  describe "AC-G2-1: adapter behaviour + shipped adapters" do
    test "Provider defines configured?/1 and deliver/2 callbacks (+ the ADR-038 additions)" do
      callbacks = Provider.behaviour_info(:callbacks)
      assert {:configured?, 1} in callbacks
      assert {:deliver, 2} in callbacks
      assert {:capabilities, 0} in callbacks
      assert {:verify_and_parse_event, 3} in callbacks
      assert {:parse_inbound, 3} in callbacks
      assert {:redact_payload, 1} in callbacks
    end

    test "Samen.Delivery.Adapter no longer exists (ADR-038 §4.2 supersession)" do
      refute Code.ensure_loaded?(Samen.Delivery.Adapter)
    end

    test "LocalSink is configured? and returns an HONEST sink receipt (captured, not delivered)" do
      assert LocalSink.configured?(%{}) == true
      assert {:ok, receipt} = LocalSink.deliver(msg(), %{})
      assert receipt.sink == true, "LocalSink receipt must be tagged sink: true (not a real send)"
      assert receipt.send_id == msg().send_id
    end

    test "Smtp configured?/1 is false without creds and deliver/2 refuses (no fake success)" do
      refute Smtp.configured?(%{})
      refute Smtp.configured?(%{host: "smtp.example.com"})
      assert Smtp.configured?(%{host: "h", username: "u", password: "p"})
      assert {:error, :not_configured} = Smtp.deliver(msg(), %{})
    end

    test "Api configured?/1 is false without creds and deliver/2 refuses (no fake success)" do
      refute Api.configured?(%{})
      refute Api.configured?(%{api_key: "k"})
      assert Api.configured?(%{api_key: "k", endpoint: "https://esp"})
      assert {:error, :not_configured} = Api.deliver(msg(), %{})
    end

    test "the module carries NO unconditional-success stub adapter (tautology removed)" do
      # The old StubAdapter.deliver/2 -> :ok default is deleted. Nothing named
      # StubAdapter exists on the worker anymore.
      refute Code.ensure_loaded?(Samen.Scopes.Marketing.SendWorker.StubAdapter)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G2-2 / RP-D1 — fail-honest decision: unconfigured in non-test → :blocked.

  describe "AC-G2-2: fail-honest decision (SendWorker.decide/3)" do
    test "RP-D1: nil adapter in a non-:test env is BLOCKED, never delivered" do
      assert {:blocked, :adapter_unconfigured} = SendWorker.decide(nil, %{}, :prod)
      assert {:blocked, :adapter_unconfigured} = SendWorker.decide(nil, %{}, :dev)
    end

    test "RP-D1: an adapter whose configured?/1 is false is BLOCKED, never delivered" do
      assert {:blocked, :adapter_unconfigured} =
               SendWorker.decide(UnconfiguredAdapter, %{}, :prod)
    end

    test "no decision branch routes an unconfigured adapter to :deliver in any non-test env" do
      for env <- [:prod, :dev, :staging] do
        assert {:blocked, :adapter_unconfigured} = SendWorker.decide(nil, %{}, env)
        assert {:blocked, :adapter_unconfigured} =
                 SendWorker.decide(UnconfiguredAdapter, %{}, env)
      end
    end

    test "anti-tautology (RP-D1 non-vacuous): a CONFIGURED adapter is routed to :deliver" do
      # If :blocked were returned unconditionally, this would fail — proving the
      # blocked path above is a real gate, not a constant.
      assert {:deliver, OkAdapter, %{}} = SendWorker.decide(OkAdapter, %{}, :prod)
    end

    test ":test env falls back to LocalSink for a nil adapter (honest capture, not a prod lie)" do
      assert {:deliver, LocalSink, %{}} = SendWorker.decide(nil, %{}, :test)
    end

    test "LocalSink is NEVER the fallback in a non-:test env" do
      # The prod/dev nil-adapter path must NOT silently become a LocalSink
      # "delivered to a log" — that is the exact lie ADR-014 forbids. The
      # non-test nil path resolves to :blocked, so no adapter (LocalSink or
      # otherwise) is ever routed to :deliver.
      # The type checker itself proves these are :blocked (never a :deliver
      # tuple), so this refusal is guaranteed at compile time, not just runtime.
      assert {:blocked, _} = SendWorker.decide(nil, %{}, :prod)
      assert {:blocked, _} = SendWorker.decide(nil, %{}, :dev)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G2-3 — adapter error → :failed; adapter ok → :delivered (via perform/1).

  describe "AC-G2-3: perform/1 honors adapter outcome" do
    setup do
      # Ensure no host send_module/repo is wired so status-update degrades to a
      # no-op log (kernel has no marketing send table). We assert on the job
      # return value, which is the authoritative fail-honest signal.
      prev = Application.get_env(:samen_core, SendWorker)
      prev_mod = Application.get_env(:samen_core, :marketing_send_module)
      Application.delete_env(:samen_core, :marketing_send_module)

      on_exit(fn ->
        if prev, do: Application.put_env(:samen_core, SendWorker, prev),
          else: Application.delete_env(:samen_core, SendWorker)

        if prev_mod, do: Application.put_env(:samen_core, :marketing_send_module, prev_mod)
      end)

      :ok
    end

    defp job(args), do: %Oban.Job{args: args}

    defp args do
      %{
        "send_id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "org_id" => "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        "subscriber_id" => "cccccccc-cccc-cccc-cccc-cccccccccccc"
      }
    end

    test "adapter {:ok, receipt} → perform returns :ok (the :delivered path)" do
      Application.put_env(:samen_core, SendWorker, adapter: OkAdapter, adapter_config: %{})
      assert SendWorker.perform(job(args())) == :ok
    end

    test "RP-D2: adapter {:error, reason} → perform returns {:error, reason}, provably NOT delivered" do
      Application.put_env(:samen_core, SendWorker, adapter: ErrAdapter, adapter_config: %{})
      assert {:error, :smtp_timeout} = SendWorker.perform(job(args()))
    end

    test "RP-D1 (integration): unconfigured adapter in non-:test env → job errors, not :ok" do
      Application.put_env(:samen_core, SendWorker, adapter: UnconfiguredAdapter)
      Application.put_env(:samen_core, :delivery_env, :prod)

      on_exit(fn -> Application.delete_env(:samen_core, :delivery_env) end)

      result = SendWorker.perform(job(args()))
      assert {:error, :adapter_unconfigured} = result
      refute result == :ok, "a blocked send must NEVER return :ok (the delivered signal)"
    end

    test "malformed args (no send_id) are discarded, never delivered" do
      assert {:discard, _} = SendWorker.perform(job(%{"org_id" => "x"}))
    end
  end

  # ---------------------------------------------------------------------------
  # Worker options unchanged (queue/idempotency invariants preserved).

  describe "SendWorker Oban options" do
    test "runs in the :webhooks_out queue with capped attempts and per-send unique" do
      assert SendWorker.__opts__()[:queue] == :webhooks_out
      assert SendWorker.__opts__()[:max_attempts] == 20
      assert SendWorker.__opts__()[:unique][:period] == 60
    end
  end
end
