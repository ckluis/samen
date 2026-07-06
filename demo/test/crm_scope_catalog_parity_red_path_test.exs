defmodule Demo.CrmScopeCatalogParityRedPathTest do
  @moduledoc """
  Anti-tautology probe for the CRM scope catalog-parity guarantee (T3.2;
  scope-authoring guide §9 "Catalog-parity red path").

  The `catalog_parity` verifier fails closed on a ghost table (a mounted resource
  with no catalog_sync rows). This test:

    1. Proves the verifier is currently GREEN on the CRM scope (positive control).
    2. Deletes a catalog row inside the sandbox transaction, confirms the verifier
       reports a violation (anti-tautology probe), and the sandbox rolls back the
       delete so other tests are not affected.

  Pattern: same as `Demo.IdentityCatalogParityRedPathTest` — direct call to
  `CatalogParity.check/1` within the SQL sandbox transaction.
  """
  use Demo.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.CatalogParity

  test "catalog_parity is GREEN when all CRM scope columns are catalogued (positive control)" do
    violations = CatalogParity.check(Demo.Repo)

    assert violations == [],
           "Expected no violations; got: #{inspect(violations)}"
  end

  test "deleting a catalog row for a CRM column makes catalog_parity FAIL (anti-tautology probe)" do
    # Sanity: green first.
    assert CatalogParity.check(Demo.Repo) == []

    # Sabotage: remove the fld_field row for cmp_company.cmp_name (as if the CRM
    # migration forgot catalog_sync for that column). Runs inside the sandbox
    # transaction — rolled back at test end.
    {:ok, _} =
      Repo.query(
        "DELETE FROM fld_field WHERE fld_table_name = 'cmp_company' AND fld_column_name = 'cmp_name'"
      )

    violations = CatalogParity.check(Demo.Repo)

    refute violations == [], "catalog_parity must FAIL when a CRM column is uncatalogued"

    assert Enum.any?(violations, fn v ->
             v =~ "cmp_company" and (v =~ "uncatalogued" or v =~ "cmp_name")
           end),
           "expected a violation for cmp_company.cmp_name; got: #{inspect(violations)}"
  end

  test "removing the CRM person table tam_table entry is caught as a ghost table" do
    assert CatalogParity.check(Demo.Repo) == []

    # Delete the tam_table + fld_field rows for per_person (the canonical vault case).
    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'per_person'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'per_person'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "per_person" and v =~ "ghost table"
           end),
           "expected a 'ghost table: per_person' violation; got: #{inspect(violations)}"
  end
end
