defmodule Demo.MarketingScopeCatalogParityRedPathTest do
  @moduledoc """
  Catalog parity red path for the Marketing scope (T3.4). Proves the verifier fails
  closed when a Marketing resource is mounted without catalog rows, and passes when
  all catalog rows are present.

  Anti-tautology discipline (guide §9): temporarily delete a catalog row inside the
  test's sandbox transaction (auto-rolled-back at test end), confirm the verifier
  REPORTS a violation naming that column. If catalog_parity were a tautology, step 2
  would still be green — it does not.

  Pattern matches identity_catalog_parity_red_path_test.exs exactly.
  """
  use Demo.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.CatalogParity

  # =========================================================================
  # Green path — the catalog is consistent.
  # =========================================================================

  test "catalog_parity is GREEN when every Marketing column is catalogued" do
    assert CatalogParity.check(Demo.Repo) == []
  end

  # =========================================================================
  # Red path — deleting a Marketing catalog row triggers a violation.
  # Anti-tautology probe: if the check passed regardless, this test would stay
  # green even after deletion. It must flip to a violation.
  # =========================================================================

  test "deleting a catalog row for a Marketing column makes catalog_parity FAIL (red path)" do
    # Sanity: green first.
    assert CatalogParity.check(Demo.Repo) == []

    # Sabotage: remove the fld_field row for mca_campaign.mca_name (as if the mount
    # migration forgot catalog_sync for that column). Runs inside the test's sandbox
    # transaction — rolled back at test end, so no state leak.
    {:ok, _} =
      Repo.query(
        "DELETE FROM fld_field WHERE fld_table_name = 'mca_campaign' AND fld_column_name = 'mca_name'"
      )

    violations = CatalogParity.check(Demo.Repo)

    refute violations == [], "catalog_parity must FAIL when a Marketing column is uncatalogued"

    assert Enum.any?(violations, fn v ->
             v =~ "mca_campaign.mca_name" and v =~ "uncatalogued"
           end),
           "expected an 'uncatalogued column: mca_campaign.mca_name' violation, got: #{inspect(violations)}"
  end

  test "removing the msu_subscriber tam_table entry is caught as a ghost table" do
    assert CatalogParity.check(Demo.Repo) == []

    # Delete the tam_table + fld_field rows for the entire msu_subscriber table.
    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'msu_subscriber'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'msu_subscriber'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "msu_subscriber" and v =~ "ghost table"
           end),
           "expected a 'ghost table: msu_subscriber' violation, got: #{inspect(violations)}"
  end

  test "pii_msu_email column is catalogued in fld_field (PII vault column present)" do
    # The pii_msu_email column is a vault-token column. The catalog should list it
    # because catalog_sync includes all physical DB columns.
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT fld_column_name FROM fld_field WHERE fld_table_name = 'msu_subscriber' AND fld_column_name = 'pii_msu_email'"
      )

    assert length(rows) == 1,
           "Expected pii_msu_email to be catalogued in fld_field for msu_subscriber"
  end
end
