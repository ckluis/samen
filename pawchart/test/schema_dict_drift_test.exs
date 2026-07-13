defmodule PawChart.SchemaDictDriftTest do
  @moduledoc """
  In-suite tripwire for `pawchart/ci.sh` step 1b ("schema.dict.json drift
  check"). Catches a shipped-resource-without-dict-regen regression in the
  suite, before the full gate goes red.

  ## Why (B2-P1-schema-dict-stale, vertical propagation)

  The B1 movement ledger (`PawChart.Billing.SubscriptionEvent` →
  `pbv_subscription_event`) landed but `schema.dict.json` was not regenerated —
  the same omission that turned the demo gate red, propagated into this
  vertical. This test makes that class of drift fail loudly in `mix test`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Catalog.Dump

  @committed_path Path.expand("../schema.dict.json", __DIR__)
  @mov_tables ~w(pbv_subscription_event)

  defp domains do
    Application.get_env(:ash, :domains) ||
      Application.get_env(Mix.Project.config()[:app], :ash_domains) ||
      []
  end

  defp fresh_dict, do: Dump.build_dict(Samen.Catalog.resource_modules(domains()))

  test "GREEN: committed dict is byte-identical to a fresh dump" do
    committed_json = File.read!(@committed_path)
    fresh_json = Jason.encode!(fresh_dict(), pretty: true) <> "\n"

    assert committed_json == fresh_json,
           "pawchart/schema.dict.json is stale — run " <>
             "`MIX_ENV=test mix samen.catalog.dump --output schema.dict.json` and commit."
  end

  test "committed dict carries the B1 mov ledger block" do
    tables = @committed_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tables")
    present = MapSet.new(Enum.map(tables, & &1["table_name"]))

    for t <- @mov_tables do
      assert MapSet.member?(present, t), "#{t} missing from committed dict"
    end
  end

  test "RED PATH: a dict missing the mov ledger block does NOT match the committed file" do
    mutated =
      update_in(fresh_dict()["tables"], fn tables ->
        Enum.reject(tables, &(&1["table_name"] in @mov_tables))
      end)

    refute (Jason.encode!(mutated, pretty: true) <> "\n") == File.read!(@committed_path),
           "drift check must reject a dict missing the mov ledger block"
  end
end
