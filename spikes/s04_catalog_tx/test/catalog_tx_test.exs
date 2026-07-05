defmodule S04CatalogTx.CatalogTxTest do
  @moduledoc """
  Acceptance tests for S0.4 — catalog written in the migration transaction.

  Run serially (async: false): every test manipulates the shared spike schema via
  real migrations, so they cannot overlap.
  """
  use ExUnit.Case, async: false

  alias S04CatalogTx.Repo

  alias S04CatalogTx.Migrations.{
    Bootstrap,
    AddPhone,
    AddPhoneCrashAfterDDL
  }

  @bootstrap_v 1
  @addphone_v 2

  setup do
    # Fresh schema every test: drop everything, then run the bootstrap migration.
    reset_schema!()
    run(@bootstrap_v, Bootstrap)
    :ok
  end

  # --- helpers -------------------------------------------------------------

  defp reset_schema! do
    for tbl <- ~w(com_contact fld_field tam_table schema_migrations) do
      Repo.query!("DROP TABLE IF EXISTS #{tbl} CASCADE")
    end
  end

  defp run(version, mod), do: Ecto.Migrator.up(Repo, version, mod, log: false)
  defp rollback(version, mod), do: Ecto.Migrator.down(Repo, version, mod, log: false)

  defp column_exists?(table, column) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    n == 1
  end

  defp catalog_field_rows(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT fld_column_name, fld_logical_name, fld_type FROM fld_field " <>
          "WHERE fld_table_name = $1 ORDER BY fld_column_name",
        [table]
      )

    Enum.map(rows, fn [c, l, t] -> %{column_name: c, logical_name: l, type: t} end)
  end

  defp catalog_has_field?(table, column) do
    Enum.any?(catalog_field_rows(table), &(&1.column_name == column))
  end

  # --- tests ---------------------------------------------------------------

  test "bootstrap: catalog reflects the base columns, com_phone absent from both" do
    assert column_exists?("com_contact", "com_name")
    refute column_exists?("com_contact", "com_phone")

    assert catalog_has_field?("com_contact", "com_name")
    assert catalog_has_field?("com_contact", "com_org_id")
    refute catalog_has_field?("com_contact", "com_phone")
  end

  test "atomic add: migration adds the column AND its catalog row together" do
    run(@addphone_v, AddPhone)

    assert column_exists?("com_contact", "com_phone")
    assert catalog_has_field?("com_contact", "com_phone")
  end

  test "catalog contents match Ash.Resource.Info introspection after add" do
    run(@addphone_v, AddPhone)

    introspected =
      S04CatalogTx.Crm.Contact
      |> Samen.Catalog.fields()
      |> Enum.map(&Map.take(&1, [:column_name, :logical_name, :type]))
      |> Enum.sort_by(& &1.column_name)

    db = catalog_field_rows("com_contact")

    assert db == introspected,
           "catalog rows must equal Ash.Resource.Info.\n db=#{inspect(db)}\n introspection=#{inspect(introspected)}"

    # and the com_phone row specifically carries the abbrev-prefixed storage name
    # with logical name :phone
    phone = Enum.find(db, &(&1.column_name == "com_phone"))
    assert phone == %{column_name: "com_phone", logical_name: "phone", type: "String"}
  end

  test "rollback removes BOTH the column and the catalog row" do
    run(@addphone_v, AddPhone)
    assert column_exists?("com_contact", "com_phone")
    assert catalog_has_field?("com_contact", "com_phone")

    rollback(@addphone_v, AddPhone)

    refute column_exists?("com_contact", "com_phone")
    refute catalog_has_field?("com_contact", "com_phone")
  end

  # ===================== RED PATH =====================
  # Crash injected between the DDL and the catalog insert must leave NEITHER.
  # A version of this that "passes" while the column or a catalog row survives
  # means the atomicity guarantee is broken.
  test "RED PATH: crash between DDL and catalog insert leaves NEITHER column NOR catalog row" do
    # Pre-conditions: neither exists.
    refute column_exists?("com_contact", "com_phone")
    refute catalog_has_field?("com_contact", "com_phone")

    # The crashing migration adds the column, flushes DDL, then raises before the
    # catalog insert. Ecto must abort the whole transaction.
    assert_raise RuntimeError, ~r/injected crash/, fn ->
      run(@addphone_v, AddPhoneCrashAfterDDL)
    end

    # THE GUARANTEE: neither the column nor the catalog row survived the crash.
    refute column_exists?("com_contact", "com_phone"),
           "FAIL-OPEN: com_phone column survived a crash that happened before the catalog write"

    refute catalog_has_field?("com_contact", "com_phone"),
           "FAIL-OPEN: a com_phone catalog row survived the aborted migration"
  end
end
