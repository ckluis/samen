defmodule SamenStripe.UsageTest do
  @moduledoc """
  B8 metered-usage reporting — the T25 done-criteria, proven end-to-end and
  hermetically (ADR-038 §3.1 `report_usage/2` + idempotency-key rule; keyless
  lane 0, §7.1).

  The FULL real path runs with no network and no Stripe credential:

      pending Samen.Billing.FakeUsageMirror rows
        → Samen.Billing.UsageReporter.report_pending/1   (vendor-generic batching)
        → SamenStripe.Provider.report_usage/2            (real Stripe usage_records
             POST shape, form-encoded, one call per record)
             served by an INJECTED CAPTURING transport (config[:transport], §7.1 lane 0)
        → Samen.Billing.FakeUsageMirror.mark_reported/3  (the in-memory mirror port)

  `Samen.Core`'s OWN `samen_core/test/billing_usage_reporter_test.exs` proves the
  SAME contract again with the core `FakeProvider` (no Stripe at all) — this file
  is what proves the Stripe adapter's real HTTP-shaped request/response handling
  on top of that vendor-generic logic (the split ADR-038 §2 calls "adapters
  translate and transport; core owns state and convergence").

  Done-criteria:
    1. Pending records batch into ONE `report_usage/2` call; each item on the
       wire carries quantity/timestamp/an `Idempotency-Key`-bound key; a
       successful report marks every record reported; re-running does NOT
       re-send them (no second HTTP call).
    2. Provider (HTTP) failure leaves every record in the batch PENDING — no
       data loss; a later retry (once Stripe is reachable again) succeeds and
       marks them, reusing the SAME idempotency keys.
    3. Unconfigured adapter (no `secret_key`): `report_pending/1` returns
       `{:error, :not_configured}`; the mirror is never even read; nothing is
       marked sent (fail-honest, ADR-014) — and NO HTTP call is made.
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.{FakeUsageMirror, UsageReporter}
  alias SamenStripe.Provider

  @secret_key "sk_test_usage"

  # --- transport + fixture helpers --------------------------------------------

  defp capturing_transport(response_fun) do
    parent = self()

    fn request ->
      send(parent, {:captured_request, request})
      response_fun.(request)
    end
  end

  defp drain_captured_requests(acc \\ []) do
    receive do
      {:captured_request, req} -> drain_captured_requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seed_two_pending(mirror_ref) do
    FakeUsageMirror.seed(mirror_ref, %{
      id: "ur_1",
      metric: :api_calls,
      quantity: 42,
      period_start: ~U[2026-07-01 00:00:00Z],
      period_end: ~U[2026-07-31 23:59:59Z],
      subscription_id: "sub_row_1",
      provider_ref: "si_stripe_1"
    })

    FakeUsageMirror.seed(mirror_ref, %{
      id: "ur_2",
      metric: :seats,
      quantity: 3,
      period_start: ~U[2026-07-01 00:00:00Z],
      period_end: ~U[2026-07-31 23:59:59Z],
      subscription_id: "sub_row_2",
      provider_ref: "si_stripe_2"
    })

    mirror_ref
  end

  defp reporter_opts(mirror_ref, provider_config) do
    [
      provider: Provider,
      provider_config: provider_config,
      usage_mirror: FakeUsageMirror,
      usage_mirror_ref: mirror_ref
    ]
  end

  defp ok_usage_record_response(request) do
    quantity = Map.get(request.form, "quantity")

    {:ok,
     %{
       status: 200,
       body: %{
         "id" => "mbur_#{System.unique_integer([:positive])}",
         "quantity" => quantity,
         "object" => "usage_record"
       }
     }}
  end

  # ---------------------------------------------------------------------------
  describe "done-criterion 1: batch → real Stripe request shape → mark → not re-sent" do
    test "each usage record posts quantity/timestamp/Idempotency-Key to the subscription-item endpoint" do
      transport = capturing_transport(&ok_usage_record_response/1)
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()
      config = %{secret_key: @secret_key, transport: transport}

      assert {:ok, %{reported: 2}} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, config))

      requests = drain_captured_requests()
      assert length(requests) == 2

      for req <- requests do
        assert req.method == :post
        assert String.starts_with?(req.url, "https://api.stripe.com/v1/subscription_items/")
        assert String.ends_with?(req.url, "/usage_records")
        assert req.form["action"] == "increment"
        assert is_binary(req.idempotency_key)
        assert String.starts_with?(req.idempotency_key, "usage:")
      end

      req1 = Enum.find(requests, &String.contains?(&1.url, "si_stripe_1"))
      assert req1.form["quantity"] == 42
      assert req1.form["timestamp"] == DateTime.to_unix(~U[2026-07-31 23:59:59Z])
      assert req1.idempotency_key == UsageReporter.idempotency_key("ur_1")

      req2 = Enum.find(requests, &String.contains?(&1.url, "si_stripe_2"))
      assert req2.form["quantity"] == 3
      assert req2.idempotency_key == UsageReporter.idempotency_key("ur_2")

      refute req1.idempotency_key == req2.idempotency_key
    end

    test "reported records are marked, and a re-run does NOT re-send them" do
      transport = capturing_transport(&ok_usage_record_response/1)
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()
      config = %{secret_key: @secret_key, transport: transport}

      assert {:ok, %{reported: 2}} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, config))

      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_2")
      assert length(drain_captured_requests()) == 2

      # Re-run against the SAME (now fully-reported) mirror: no pending rows left,
      # so report_usage/2 (and therefore the HTTP transport) is never called again.
      assert {:ok, %{reported: 0}} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, config))

      assert drain_captured_requests() == []
    end
  end

  describe "done-criterion 2: provider (HTTP) failure ⇒ no data loss" do
    test "a non-200 response leaves the WHOLE batch pending; a later retry succeeds and marks them" do
      failing_transport =
        capturing_transport(fn _req ->
          {:ok, %{status: 500, body: %{"error" => "server_error"}}}
        end)

      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()
      failing_config = %{secret_key: @secret_key, transport: failing_transport}

      assert {:error, {:http_error, 500}} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, failing_config))

      # Drain the (partial-batch) requests this failed attempt made — a fresh
      # mailbox for the next attempt's assertions below.
      drain_captured_requests()

      # No data loss: BOTH records still pending, even though (in a real batch
      # with >1 item) the first item's call may have already reached Stripe —
      # marking is all-or-nothing and only ever follows a whole-batch success.
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_2")

      # A transport-level (connection) failure is equally honest — no data loss.
      offline_transport = capturing_transport(fn _req -> {:error, :econnrefused} end)
      offline_config = %{secret_key: @secret_key, transport: offline_transport}

      assert {:error, :econnrefused} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, offline_config))

      drain_captured_requests()
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_1")

      # Retry once Stripe recovers: succeeds, marks both, REUSING the same
      # idempotency keys the failed attempts already sent.
      recovered_transport = capturing_transport(&ok_usage_record_response/1)
      recovered_config = %{secret_key: @secret_key, transport: recovered_transport}

      assert {:ok, %{reported: 2}} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, recovered_config))

      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_2")

      retry_requests = drain_captured_requests()
      retry_keys = retry_requests |> Enum.map(& &1.idempotency_key) |> Enum.sort()

      assert retry_keys ==
               Enum.sort([
                 UsageReporter.idempotency_key("ur_1"),
                 UsageReporter.idempotency_key("ur_2")
               ])
    end
  end

  describe "done-criterion 3: unconfigured adapter is fail-honest" do
    test "no secret_key ⇒ :not_configured, records accumulate untouched, NO HTTP call" do
      transport = capturing_transport(&ok_usage_record_response/1)
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()
      config = %{transport: transport}

      assert {:error, :not_configured} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, config))

      assert drain_captured_requests() == []
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_2")
      assert FakeUsageMirror.mark_count(mirror_ref) == 0
    end

    test "Provider.report_usage/2 itself refuses honestly when unconfigured (never a fake :ok)" do
      assert {:error, :not_configured} = Provider.report_usage([%{quantity: 1}], %{})
    end
  end

  describe "a missing provider_ref refuses before any HTTP call for that record" do
    test "a batch item with no subscription-item ref halts the batch (fail-honest, not a skip)" do
      transport = capturing_transport(&ok_usage_record_response/1)
      mirror_ref = FakeUsageMirror.new()

      FakeUsageMirror.seed(mirror_ref, %{
        id: "ur_no_ref",
        metric: :api_calls,
        quantity: 1,
        period_start: ~U[2026-07-01 00:00:00Z],
        period_end: ~U[2026-07-31 23:59:59Z],
        subscription_id: "sub_row_3",
        provider_ref: nil
      })

      config = %{secret_key: @secret_key, transport: transport}

      assert {:error, :missing_provider_ref} =
               UsageReporter.report_pending(reporter_opts(mirror_ref, config))

      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_no_ref")
    end
  end
end
