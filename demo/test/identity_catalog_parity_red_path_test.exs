defmodule Demo.IdentityCatalogParityRedPathTest do
  @moduledoc """
  The `unregistered scope resource fails catalog_parity` red path (T3.1; ADR-004 §6.1).

  A mounted Identity table whose catalog rows are missing must be caught by
  `catalog_parity` as an uncatalogued column (fail closed). We prove the verifier is
  a genuine discriminator by:

    1. asserting the verifier is GREEN on the fully-mounted, fully-catalogued demo;
    2. DELETING a catalog row for an Identity column inside the sandbox transaction
       and asserting the verifier now REPORTS a violation naming that column;
    3. (the sandbox rolls back, so the catalog is restored automatically).

  This is the anti-tautology probe for catalog registration: if the check passed
  regardless of catalog contents, step 2 would still be green — it must fail.
  """
  use Demo.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.CatalogParity

  test "catalog_parity is GREEN when every Identity column is catalogued" do
    assert CatalogParity.check(Demo.Repo) == []
  end

  test "deleting a catalog row for an Identity column makes catalog_parity FAIL (red path)" do
    # Sanity: green first.
    assert CatalogParity.check(Demo.Repo) == []

    # Sabotage: remove the fld_field row for usr_user.usr_handle (as if the mount
    # migration forgot catalog_sync for that column). This runs inside the test's
    # sandbox transaction and is rolled back at test end.
    {:ok, _} =
      Repo.query(
        "DELETE FROM fld_field WHERE fld_table_name = 'usr_user' AND fld_column_name = 'usr_handle'"
      )

    violations = CatalogParity.check(Demo.Repo)

    refute violations == [], "catalog_parity must FAIL when an Identity column is uncatalogued"

    assert Enum.any?(violations, fn v ->
             v =~ "usr_user.usr_handle" and v =~ "uncatalogued"
           end),
           "expected an 'uncatalogued column: usr_user.usr_handle' violation, got: #{inspect(violations)}"
  end

  test "removing a whole Identity table's tam_table entry is caught as a ghost table" do
    assert CatalogParity.check(Demo.Repo) == []

    # Delete the tam_table + fld_field rows for the entire inv_invitation table.
    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'inv_invitation'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'inv_invitation'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "inv_invitation" and v =~ "ghost table"
           end),
           "expected a 'ghost table: inv_invitation' violation, got: #{inspect(violations)}"
  end
end
