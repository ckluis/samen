defmodule Samen.Billing.UsageReporterTest do
  @moduledoc """
  Core-side, VENDOR-FREE proof of the B8 usage-reporting batching worker (T25;
  ADR-038 §3.1 `report_usage/2` + idempotency-key rule).

  Uses the core `Samen.Billing.FakeProvider` (no `samen_stripe`, no network) +
  `Samen.Billing.FakeUsageMirror` — the INV-4 posture (core proves the full
  batching/idempotency/no-data-loss/fail-honest contract with every adapter
  absent). `samen_stripe/test/usage_test.exs` proves the SAME contract again
  through the real Stripe HTTP-shaped adapter (cassette/captured-request
  transport).

  Done-criteria proven here (T25 handoff):
    1. Pending records batch into ONE `report_usage/2` call carrying
       quantity/timestamp/idempotency-key per record; a successful report marks
       every record reported; a re-run does NOT re-send them (mark_count stays
       flat, no second provider call).
    2. Provider failure leaves every record in the batch PENDING (no data loss);
       a later retry (once the provider recovers) succeeds and marks them.
    3. An unconfigured provider: `report_pending/1` returns `{:error,
       :not_configured}`, the mirror is never even read, nothing is marked sent
       (fail-honest, ADR-014).
  """
  use ExUnit.Case, async: false

  alias Samen.Billing.{FakeProvider, FakeUsageMirror, UsageReporter}

  setup do
    FakeProvider.reset()
    :ok
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

  defp opts(mirror_ref, overrides \\ []) do
    Keyword.merge(
      [
        provider: FakeProvider,
        provider_config: %{configured: true},
        usage_mirror: FakeUsageMirror,
        usage_mirror_ref: mirror_ref
      ],
      overrides
    )
  end

  # T163 (ADR-051 P2): the provider INCREMENTS, so a tally that grew after it was
  # reported must send only its delta — never its whole total again.
  defmodule GrowingProvider do
    @moduledoc false
    # A provider that, while the batch is "in flight", grows the mirrored tally —
    # a rebuild landing between read_pending and mark_reported.
    def configured?(_config), do: true

    def report_usage(batch, %{mirror: ref, grow: {id, to}} = config) do
      row = Samen.Billing.FakeUsageMirror.get(ref, id)
      Samen.Billing.FakeUsageMirror.seed(ref, %{row | quantity: to})
      Samen.Billing.FakeProvider.report_usage(batch, Map.drop(config, [:mirror, :grow]))
    end
  end

  defp seed_one(mirror_ref, quantity, reported_quantity) do
    FakeUsageMirror.seed(mirror_ref, %{
      id: "ur_1",
      metric: :api_calls,
      quantity: quantity,
      reported_quantity: reported_quantity,
      period_start: ~U[2026-07-01 00:00:00Z],
      period_end: ~U[2026-07-31 23:59:59Z],
      subscription_id: "sub_row_1",
      provider_ref: "si_stripe_1"
    })
  end

  # Chronological (FakeProvider.calls/0 is newest-first).
  defp batches, do: for({:report_usage, %{batch: b}} <- Enum.reverse(FakeProvider.calls()), do: b)

  describe "T163 P2: deltas — a grown tally never re-bills what was already reported" do
    test "a tally that grew after it was reported sends ONLY the delta, under a delta key" do
      mirror_ref = FakeUsageMirror.new() |> seed_one(42, 0)
      assert {:ok, %{reported: 1}} = UsageReporter.report_pending(opts(mirror_ref))
      assert %{reported_quantity: 42} = FakeUsageMirror.get(mirror_ref, "ur_1")

      # A rebuild grows the tally from 42 to 50 (late events in the same period).
      seed_one(mirror_ref, 50, 42)
      assert {:ok, %{reported: 1}} = UsageReporter.report_pending(opts(mirror_ref))

      assert [[first], [second]] = batches()
      assert first.quantity == 42
      assert second.quantity == 8, "the provider increments: sending 50 again would bill 42 twice"
      assert second.idempotency_key == UsageReporter.idempotency_key("ur_1", 42, 50)
      refute second.idempotency_key == first.idempotency_key
      assert %{reported_quantity: 50} = FakeUsageMirror.get(mirror_ref, "ur_1")
    end

    test "POSITIVE CONTROL: an unchanged, fully reported tally is not sent at all" do
      mirror_ref = FakeUsageMirror.new() |> seed_one(42, 42)
      assert {:ok, %{reported: 0}} = UsageReporter.report_pending(opts(mirror_ref))
      assert batches() == []
    end

    test "a retried delta carries the SAME key and the SAME quantity" do
      mirror_ref = FakeUsageMirror.new() |> seed_one(50, 42)

      FakeProvider.configure_report_usage_result({:error, :temporary_outage})
      assert {:error, :temporary_outage} = UsageReporter.report_pending(opts(mirror_ref))
      assert %{reported_quantity: 42} = FakeUsageMirror.get(mirror_ref, "ur_1")

      FakeProvider.configure_report_usage_result(nil)
      assert {:ok, %{reported: 1}} = UsageReporter.report_pending(opts(mirror_ref))

      assert [[failed], [retried]] = batches()
      assert {failed.quantity, failed.idempotency_key} == {retried.quantity, retried.idempotency_key}
      assert retried.quantity == 8
    end

    test "growth DURING a report is marked at the value SENT, and goes out as the next delta" do
      mirror_ref = FakeUsageMirror.new() |> seed_one(42, 0)

      grow_opts =
        opts(mirror_ref,
          provider: GrowingProvider,
          provider_config: %{configured: true, mirror: mirror_ref, grow: {"ur_1", 50}}
        )

      assert {:ok, %{reported: 1}} = UsageReporter.report_pending(grow_opts)
      # The provider was sent 42; the tally is now 50. Marking it 50 would silently
      # drop the 8 that arrived mid-flight.
      assert %{quantity: 50, reported_quantity: 42} = FakeUsageMirror.get(mirror_ref, "ur_1")

      assert {:ok, %{reported: 1}} = UsageReporter.report_pending(opts(mirror_ref))
      assert [[first], [second]] = batches()
      assert {first.quantity, second.quantity} == {42, 8}
    end
  end

  describe "done-criterion 1: batch + idempotency + not re-sent" do
    test "pending records batch into one report_usage/2 call, carrying quantity/timestamp/idempotency-key" do
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()

      assert {:ok, %{reported: 2}} = UsageReporter.report_pending(opts(mirror_ref))

      assert [{:report_usage, %{batch: batch}}] = FakeProvider.calls()
      assert length(batch) == 2

      item1 = Enum.find(batch, &(&1.usage_record_id == "ur_1"))
      assert item1.quantity == 42
      assert item1.timestamp == ~U[2026-07-31 23:59:59Z]
      assert item1.idempotency_key == UsageReporter.idempotency_key("ur_1", 0, 42)

      item2 = Enum.find(batch, &(&1.usage_record_id == "ur_2"))
      assert item2.idempotency_key == UsageReporter.idempotency_key("ur_2", 0, 3)
      # Anti-tautology: the two keys are genuinely distinct per record.
      refute item1.idempotency_key == item2.idempotency_key
    end

    test "reported records are marked, and a re-run does NOT re-send them" do
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()

      assert {:ok, %{reported: 2}} = UsageReporter.report_pending(opts(mirror_ref))
      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_2")
      assert FakeUsageMirror.mark_count(mirror_ref) == 1

      FakeProvider.reset()
      assert {:ok, %{reported: 0}} = UsageReporter.report_pending(opts(mirror_ref))
      # No pending rows left ⇒ no second provider call, no second mark.
      assert FakeProvider.calls() == []
      assert FakeUsageMirror.mark_count(mirror_ref) == 1
    end

    test "the SAME idempotency key is reused if a still-pending batch is re-run" do
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()

      # First attempt fails provider-side (nothing marked — see done-criterion 2
      # below), so the SAME records are still pending on the next run.
      FakeProvider.configure_report_usage_result({:error, :temporary_outage})
      assert {:error, :temporary_outage} = UsageReporter.report_pending(opts(mirror_ref))
      [{:report_usage, %{batch: first_batch}}] = FakeProvider.calls()

      FakeProvider.reset()
      FakeProvider.configure_report_usage_result(nil)
      assert {:ok, %{reported: 2}} = UsageReporter.report_pending(opts(mirror_ref))
      [{:report_usage, %{batch: retry_batch}}] = FakeProvider.calls()

      first_keys = first_batch |> Enum.map(& &1.idempotency_key) |> Enum.sort()
      retry_keys = retry_batch |> Enum.map(& &1.idempotency_key) |> Enum.sort()
      assert first_keys == retry_keys
    end
  end

  describe "done-criterion 2: provider failure ⇒ no data loss" do
    test "records stay pending on provider failure, and a later retry succeeds and marks them" do
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()

      FakeProvider.configure_report_usage_result({:error, :temporary_outage})
      assert {:error, :temporary_outage} = UsageReporter.report_pending(opts(mirror_ref))

      # No data loss: both records are STILL pending, nothing marked.
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_2")
      assert FakeUsageMirror.mark_count(mirror_ref) == 0

      FakeProvider.reset()
      FakeProvider.configure_report_usage_result(nil)
      assert {:ok, %{reported: 2}} = UsageReporter.report_pending(opts(mirror_ref))
      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: %DateTime{}} = FakeUsageMirror.get(mirror_ref, "ur_2")
    end
  end

  describe "done-criterion 3: unconfigured provider is fail-honest" do
    test "unconfigured provider refuses, mirror is never read, nothing is marked sent" do
      mirror_ref = FakeUsageMirror.new() |> seed_two_pending()

      assert {:error, :not_configured} =
               UsageReporter.report_pending(opts(mirror_ref, provider_config: %{}))

      # Never even reached the provider (guarded() only records CONFIGURED calls).
      assert FakeProvider.calls() == []

      # Records accumulate, untouched — still pending.
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_1")
      assert %{reported_at: nil} = FakeUsageMirror.get(mirror_ref, "ur_2")
      assert FakeUsageMirror.mark_count(mirror_ref) == 0
    end
  end

  describe "empty backlog" do
    test "zero pending records is a true no-op, never an error" do
      mirror_ref = FakeUsageMirror.new()

      assert {:ok, %{reported: 0}} = UsageReporter.report_pending(opts(mirror_ref))
      assert FakeProvider.calls() == []
    end
  end
end
