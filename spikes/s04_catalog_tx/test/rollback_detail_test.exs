defmodule S04CatalogTx.RollbackDetailTest do
  use ExUnit.Case, async: false
  alias S04CatalogTx.Repo
  alias S04CatalogTx.Migrations.{Bootstrap, AddPhone}

  setup do
    for tbl <- ~w(com_contact fld_field tam_table schema_migrations) do
      Repo.query!("DROP TABLE IF EXISTS #{tbl} CASCADE")
    end
    Ecto.Migrator.up(Repo, 1, Bootstrap, log: false)
    :ok
  end

  defp count(sql), do: Repo.query!(sql).rows |> hd() |> hd()

  test "scoped add/rollback removes only com_phone, leaves bootstrap rows + tam entry" do
    assert count("SELECT count(*) FROM fld_field WHERE fld_table_name='com_contact'") == 3
    assert count("SELECT count(*) FROM tam_table WHERE tam_table_name='com_contact'") == 1

    Ecto.Migrator.up(Repo, 2, AddPhone, log: false)
    assert count("SELECT count(*) FROM fld_field WHERE fld_table_name='com_contact'") == 4
    assert count("SELECT count(*) FROM tam_table WHERE tam_table_name='com_contact'") == 1

    Ecto.Migrator.down(Repo, 2, AddPhone, log: false)
    # only com_phone removed; the 3 bootstrap rows and tam entry survive
    assert count("SELECT count(*) FROM fld_field WHERE fld_table_name='com_contact'") == 3
    assert count("SELECT count(*) FROM fld_field WHERE fld_table_name='com_contact' AND fld_column_name='com_phone'") == 0
    assert count("SELECT count(*) FROM tam_table WHERE tam_table_name='com_contact'") == 1
  end
end
