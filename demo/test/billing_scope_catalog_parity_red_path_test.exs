defmodule Demo.BillingScopeCatalogParityRedPathTest do
  @moduledoc """
  Anti-tautology probe for the Billing scope catalog-parity guarantee (T3.3;
  scope-authoring guide §9 "Catalog-parity red path").

  The `catalog_parity` verifier fails closed on a ghost table (a mounted resource
  with no catalog_sync rows). This test:

    1. Proves the verifier is currently GREEN on the Billing scope (positive control).
    2. Deletes a catalog row inside the sandbox transaction, confirms the verifier
       reports a violation (anti-tautology probe), and the sandbox rolls back the
       delete so other tests are not affected.

  Pattern: same as `Demo.IdentityCatalogParityRedPathTest` and
  `Demo.CrmScopeCatalogParityRedPathTest` — direct call to `CatalogParity.check/1`
  within the SQL sandbox transaction.
  """
  use Demo.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.CatalogParity

  test "catalog_parity is GREEN when all Billing scope columns are catalogued (positive control)" do
    violations = CatalogParity.check(Demo.Repo)

    assert violations == [],
           "Expected no violations; got: #{inspect(violations)}"
  end

  test "deleting a catalog row for a Billing column makes catalog_parity FAIL (anti-tautology probe)" do
    # Sanity: green first.
    assert CatalogParity.check(Demo.Repo) == []

    # Sabotage: remove the fld_field row for bcu_customer.bcu_status (as if the
    # migration forgot catalog_sync for that column). Runs inside the sandbox
    # transaction — rolled back at test end.
    {:ok, _} =
      Repo.query(
        "DELETE FROM fld_field WHERE fld_table_name = 'bcu_customer' AND fld_column_name = 'bcu_status'"
      )

    violations = CatalogParity.check(Demo.Repo)

    refute violations == [], "catalog_parity must FAIL when a Billing column is uncatalogued"

    assert Enum.any?(violations, fn v ->
             v =~ "bcu_customer" and (v =~ "uncatalogued" or v =~ "bcu_status")
           end),
           "expected a violation for bcu_customer.bcu_status; got: #{inspect(violations)}"
  end

  test "removing the Billing customer tam_table entry is caught as a ghost table" do
    assert CatalogParity.check(Demo.Repo) == []

    # Delete the tam_table + fld_field rows for bcu_customer (the PII 🔒 resource).
    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'bcu_customer'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'bcu_customer'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "bcu_customer" and v =~ "ghost table"
           end),
           "expected a 'ghost table: bcu_customer' violation; got: #{inspect(violations)}"
  end

  test "removing the ben_entitlement table catalog is caught as a ghost table" do
    assert CatalogParity.check(Demo.Repo) == []

    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'ben_entitlement'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'ben_entitlement'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "ben_entitlement" and v =~ "ghost table"
           end),
           "expected a 'ghost table: ben_entitlement' violation; got: #{inspect(violations)}"
  end
end
