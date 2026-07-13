defmodule Demo.SchemaDictDriftTest do
  @moduledoc """
  Guards the committed `demo/schema.dict.json` against staleness — the same
  invariant `demo/ci.sh` step 1b ("schema.dict.json drift check") enforces, but
  as a fast unit test so drift is caught in the suite (not only in the full gate).

  ## Why this test exists (B2-P1-schema-dict-stale)

  B1 shipped the `mov_subscription_event` resource (the append-only movement
  ledger) + its migration but never regenerated `schema.dict.json`, so the
  committed artifact was missing the `Demo.BillingScope.SubscriptionEvent`
  table block. The next full-gate run (B2) went RED at step 1b. This test is
  the in-suite tripwire for that class of regression: ship a resource, forget
  the dict, and the suite is red *before* the gate is.

  The drift check compares the committed file byte-for-byte against a freshly
  built dict from the live domain config — resolved exactly like
  `mix samen.catalog.dump` (`Application.get_env(:ash, :domains)`).
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Catalog.Dump

  @committed_path Path.expand("../schema.dict.json", __DIR__)

  # Resolve domains → resources exactly as `mix samen.catalog.dump` does, so a
  # divergence between this test and the gate is impossible by construction:
  #   1. config :ash, :domains (explicit)
  #   2. config <app>, :ash_domains (app-level fallback — this is what the demo sets)
  defp domains do
    Application.get_env(:ash, :domains) ||
      Application.get_env(Mix.Project.config()[:app], :ash_domains) ||
      []
  end

  defp fresh_dict do
    Dump.build_dict(Samen.Catalog.resource_modules(domains()))
  end

  defp committed_dict do
    @committed_path |> File.read!() |> Jason.decode!()
  end

  describe "committed schema.dict.json ⇄ live domains" do
    test "GREEN: committed dict is byte-identical to a fresh dump" do
      # Encode both through the SAME serializer the task commits with so the
      # comparison matches the gate's `diff` semantics, not just structural ==.
      committed_json = File.read!(@committed_path)
      fresh_json = Jason.encode!(fresh_dict(), pretty: true) <> "\n"

      assert committed_json == fresh_json,
             "demo/schema.dict.json is stale — run " <>
               "`MIX_ENV=test mix samen.catalog.dump --output schema.dict.json` and commit. " <>
               "This is exactly what demo/ci.sh step 1b would report."
    end

    test "the committed dict actually carries the B1 mov ledger block" do
      # Direct assertion that the specific resource whose omission caused
      # B2-P1-schema-dict-stale is present — so a future regen that drops it
      # (or a fixture that silently excludes it) fails loudly here.
      tables = committed_dict()["tables"]

      block =
        Enum.find(tables, &(&1["table_name"] == "mov_subscription_event"))

      assert block, "mov_subscription_event table block missing from committed dict"

      assert block["resource"] == "Demo.BillingScope.SubscriptionEvent"

      column_names = Enum.map(block["fields"], & &1["column_name"])
      assert "mov_mrr_delta_cents" in column_names
      assert "mov_occurred_at" in column_names

      # Token-blind ledger: no field in the mov block is vault-routed PII.
      refute Enum.any?(block["fields"], & &1["pii"]),
             "mov ledger must be token-blind — no vault-routed PII fields"
    end
  end

  describe "RED PATH — the drift check is not a tautology" do
    test "a mutated dict (dropped table) does NOT match the committed file" do
      # Anti-tautology: prove the byte-equality assertion has teeth. Drop the
      # mov ledger block from the fresh dict and confirm it now diverges from
      # the committed file — i.e. the GREEN test above would genuinely fail if
      # the dict were stale, rather than passing vacuously.
      mutated =
        update_in(fresh_dict()["tables"], fn tables ->
          Enum.reject(tables, &(&1["table_name"] == "mov_subscription_event"))
        end)

      mutated_json = Jason.encode!(mutated, pretty: true) <> "\n"
      committed_json = File.read!(@committed_path)

      refute mutated_json == committed_json,
             "a dict missing mov_subscription_event must NOT equal the committed " <>
               "dict — otherwise the drift check cannot catch a dropped resource"
    end

    test "a mutated dict (renamed column) does NOT match the committed file" do
      # Second teeth-probe on a subtler drift: a field rename inside an existing
      # table. The committed baseline must reject it.
      mutated =
        update_in(fresh_dict()["tables"], fn tables ->
          Enum.map(tables, fn t ->
            if t["table_name"] == "mov_subscription_event" do
              update_in(t["fields"], fn fields ->
                Enum.map(fields, fn f ->
                  if f["column_name"] == "mov_reason",
                    do: %{f | "column_name" => "mov_reason_TAMPERED"},
                    else: f
                end)
              end)
            else
              t
            end
          end)
        end)

      mutated_json = Jason.encode!(mutated, pretty: true) <> "\n"
      committed_json = File.read!(@committed_path)

      refute mutated_json == committed_json,
             "a dict with a renamed mov column must NOT equal the committed dict"
    end
  end
end
