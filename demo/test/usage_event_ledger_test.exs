defmodule Demo.UsageEventLedgerTest do
  @moduledoc """
  T163 (ADR-051 P1) on the DEMO host's real Postgres: the insert-only usage-capture
  ledger (`bux_usage_event`) and its one write path, `Samen.Billing.Meter.record/3`.

    * R1 — a replayed event never double-counts (and a replay inside the caller's own
      transaction does not poison it).
    * R2 — the Meter is the only write path: a direct `Ash.create` is refused.
    * R3 — the ledger is immutable: it has no update or destroy action at all.
    * R5 — no generated key: a capture without a `source_ref` is refused.
    * Token-blind — the default-deny CDC classifier mirrors every column.

  Every red pairs with a positive control that must stay green (a distinct event IS
  recorded; the Meter path DOES write).
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.UsageEvent
  alias Samen.Billing.Meter

  defp org_id, do: Ecto.UUID.generate()

  defp record(org_id, attrs) do
    Meter.record(
      org_id,
      Map.merge(%{metric: :api_calls, quantity: 1}, attrs),
      resource: UsageEvent
    )
  end

  defp count(org_id) do
    {:ok, %{rows: [[n]]}} =
      Repo.query("SELECT count(*) FROM bux_usage_event WHERE bux_org_id = $1", [
        Ecto.UUID.dump!(org_id)
      ])

    n
  end

  describe "R1 — a replayed event never double-counts" do
    test "the same source_ref captured twice is recorded once, the replay answers :duplicate" do
      org = org_id()

      assert {:ok, :recorded} = record(org, %{source_ref: "api_call:req-1"})
      assert {:ok, :duplicate} = record(org, %{source_ref: "api_call:req-1"})
      assert count(org) == 1
    end

    test "POSITIVE CONTROL: distinct events are each recorded (dedup is not a blanket refusal)" do
      org = org_id()

      assert {:ok, :recorded} = record(org, %{source_ref: "api_call:req-1"})
      assert {:ok, :recorded} = record(org, %{source_ref: "api_call:req-2"})
      # The key is per metric: one source event may count once per metric.
      assert {:ok, :recorded} = record(org, %{source_ref: "api_call:req-1", metric: :events})
      assert count(org) == 3
    end

    test "dedup is per org: the same source_ref in another org is a different event" do
      a = org_id()
      b = org_id()

      assert {:ok, :recorded} = record(a, %{source_ref: "api_call:req-1"})
      assert {:ok, :recorded} = record(b, %{source_ref: "api_call:req-1"})
      assert count(a) == 1 and count(b) == 1
    end

    test "a replay inside the caller's transaction does not abort it" do
      org = org_id()

      assert {:ok, :after_replay} =
               Repo.transaction(fn ->
                 {:ok, :recorded} = record(org, %{source_ref: "api_call:tx-1"})
                 {:ok, :duplicate} = record(org, %{source_ref: "api_call:tx-1"})
                 # A caught unique violation would have aborted the transaction here
                 # (Postgres 25P02 on every later statement). The upsert does not.
                 {:ok, _} = Repo.query("SELECT 1")
                 :after_replay
               end)

      assert count(org) == 1
    end
  end

  describe "R2 — the Meter is the only write path" do
    test "a direct Ash.create on :record is refused and writes nothing" do
      org = org_id()

      assert {:error, error} =
               UsageEvent
               |> Ash.Changeset.for_create(:record, %{
                 metric: :api_calls,
                 quantity: 1,
                 idempotency_key: Ecto.UUID.generate(),
                 occurred_at: DateTime.utc_now(),
                 org_id: org
               })
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "ungoverned-usage-row"
      assert count(org) == 0
    end

    test "POSITIVE CONTROL: the same row through the Meter is written" do
      org = org_id()
      assert {:ok, :recorded} = record(org, %{source_ref: "api_call:direct-twin"})
      assert count(org) == 1
    end
  end

  describe "R3 — the ledger is immutable" do
    test "UsageEvent exposes read and ONE create, no update and no destroy" do
      types = UsageEvent |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.sort()
      assert types == [:create, :read]
      assert Ash.Resource.Info.action(UsageEvent, :update) == nil
      assert Ash.Resource.Info.action(UsageEvent, :destroy) == nil
    end
  end

  describe "R5 — no generated key" do
    test "a capture without a source_ref is refused, not given a random key" do
      org = org_id()

      assert {:error, :idempotency_ref_required} = record(org, %{})
      assert {:error, :idempotency_ref_required} = record(org, %{source_ref: nil})
      assert {:error, :idempotency_ref_required} = record(org, %{source_ref: ""})
      assert count(org) == 0
    end

    test "the key is derived from (metric, source_ref) — deterministic, UUIDv8, metric-scoped" do
      k = Meter.idempotency_key(:api_calls, "api_call:req-1")

      assert k == Meter.idempotency_key(:api_calls, "api_call:req-1")
      refute k == Meter.idempotency_key(:api_calls, "api_call:req-2")
      refute k == Meter.idempotency_key(:events, "api_call:req-1")
      assert {:ok, _} = Ecto.UUID.cast(k)
      assert String.at(k, 14) == "8"
    end
  end

  describe "input validation — nothing is written on an error" do
    test "a non-positive quantity, an unknown metric and a bad org id are refused" do
      org = org_id()

      assert {:error, _} = record(org, %{source_ref: "q:0", quantity: 0})
      assert {:error, _} = record(org, %{source_ref: "m:x", metric: :not_a_metric})
      assert {:error, :invalid_metric} = record(org, %{source_ref: "m:nil", metric: nil})
      assert {:error, :invalid_org_id} = record("not-a-uuid", %{source_ref: "o:x"})
      assert count(org) == 0
    end
  end

  describe "token-blind by construction" do
    test "the default-deny CDC classifier mirrors every column (no plaintext_pii)" do
      kinds = Samen.Cdc.Projection.classify_columns(UsageEvent, non_pii_entries: [])
      assert kinds != []
      refute Enum.any?(kinds, fn {_col, kind} -> kind == :plaintext_pii end), inspect(kinds)
    end

    test "the table carries exactly the bounded column set, and never the source_ref" do
      {:ok, %{columns: cols}} = Repo.query("SELECT * FROM bux_usage_event LIMIT 0")

      assert Enum.sort(cols) ==
               Enum.sort(~w(bux_metric bux_quantity bux_subscription_id bux_idempotency_key
                  bux_occurred_at bux_id bux_org_id bux_inserted_at bux_updated_at))
    end
  end
end
