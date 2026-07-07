defmodule Demo.SupportScopeCatalogParityRedPathTest do
  @moduledoc """
  Catalog-parity red path for the Support scope (T3.6; scope-authoring guide §9 test 4).

  Proves the anti-tautology discipline: when a Support table's catalog row is deleted,
  `catalog_parity` detects the ghost/uncatalogued column and returns a violation.
  When catalog rows are present, it returns no violations.

  This mirrors `demo/test/identity_catalog_parity_red_path_test.exs` (T3.1).
  """
  use Demo.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.CatalogParity

  test "catalog_parity is GREEN when every Support column is catalogued" do
    violations = CatalogParity.check(Demo.Repo)

    # Expect no support-table violations (the full list should be empty or not mention
    # stk_ticket / smg_message / sag_agent etc.).
    support_violations =
      Enum.filter(violations, fn v ->
        Enum.any?(
          ~w(ssl_sla stk_ticket scv_conversation sag_agent smg_message smc_macro scs_csat),
          &String.contains?(v, &1)
        )
      end)

    assert support_violations == [],
           "Expected no Support catalog-parity violations, got: #{inspect(support_violations)}"
  end

  test "deleting a catalog row for a Support column makes catalog_parity FAIL (red path)" do
    # Sanity: green first for the Support tables.
    violations_before = CatalogParity.check(Demo.Repo)

    support_violations_before =
      Enum.filter(violations_before, fn v -> String.contains?(v, "stk_ticket") end)

    assert support_violations_before == [], "catalog_parity must be green before sabotage"

    # Sabotage: remove the fld_field row for stk_ticket.stk_subject (as if the migration
    # forgot catalog_sync for that column). This runs inside the test's sandbox transaction
    # and is rolled back at test end.
    {:ok, _} =
      Repo.query(
        "DELETE FROM fld_field WHERE fld_table_name = 'stk_ticket' AND fld_column_name = 'stk_subject'"
      )

    violations = CatalogParity.check(Demo.Repo)

    refute violations == [], "catalog_parity must FAIL when a Support column is uncatalogued"

    assert Enum.any?(violations, fn v ->
             v =~ "stk_ticket.stk_subject" and v =~ "uncatalogued"
           end),
           "expected an 'uncatalogued column: stk_ticket.stk_subject' violation, got: #{inspect(violations)}"
  end

  test "removing a whole Support table's tam_table entry is caught as a ghost table" do
    # Delete the tam_table + fld_field rows for ssl_sla.
    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'ssl_sla'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'ssl_sla'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "ssl_sla" and v =~ "ghost table"
           end),
           "expected a 'ghost table: ssl_sla' violation, got: #{inspect(violations)}"
  end

  test "support scope is registered in both :demo and :samen_core ash_domains configs" do
    demo_domains = Application.get_env(:demo, :ash_domains, [])
    core_domains = Application.get_env(:samen_core, :ash_domains, [])

    assert Demo.SupportScope in demo_domains,
           "Demo.SupportScope must be in :demo :ash_domains config"

    assert Demo.SupportScope in core_domains,
           "Demo.SupportScope must be in :samen_core :ash_domains config"
  end

  test "all support tables have correct abbrev-prefixed column names in the catalog" do
    prefix_map = %{
      "ssl_sla" => "ssl_",
      "stk_ticket" => "stk_",
      "scv_conversation" => "scv_",
      "sag_agent" => "sag_",
      "smg_message" => "smg_",
      "smc_macro" => "smc_",
      "scs_csat" => "scs_"
    }

    import Ecto.Query

    Enum.each(prefix_map, fn {table, expected_prefix} ->
      rows =
        Repo.all(
          from(f in "fld_field",
            where: f.fld_table_name == ^table,
            select: f.fld_column_name
          )
        )

      wrong_prefix_cols =
        Enum.reject(rows, fn col ->
          String.starts_with?(col, expected_prefix) or
            String.starts_with?(col, "pii_")
        end)

      assert wrong_prefix_cols == [],
             "Table #{table} has columns without the #{expected_prefix} (or pii_) prefix: " <>
               inspect(wrong_prefix_cols)
    end)
  end
end
