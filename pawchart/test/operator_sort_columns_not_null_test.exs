defmodule PawChart.OperatorSortColumnsNotNullTest do
  @moduledoc """
  `pmp_plan.pmp_name` and `pqk_ticket.pqk_subject` are the keyset sort columns of `Operator.Plan` / `Operator.Ticket`, whose
  attributes say `allow_nil? false`. The original operator mount left both columns nullable; migration
  `20261117100000_operator_sort_columns_not_null.exs` sets them NOT NULL, and `mix samen.verify.indexes` now FAILS on a
  sort attribute that says non-nil over a nullable column (it was an advisory note).

  Postgres DDL is transactional, so the "before" state is re-created inside the sandbox transaction and rolls back with the
  test: the red path (the verifier flags each mismatch, naming the table and attribute) is paired with the positive control
  (the migrated database is clean) and the recovery (restoring the constraint clears it).
  """
  use PawChart.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.Indexes

  defp opts do
    app = :pawchart
    [domains: Application.fetch_env!(app, :ash_domains), unmounted: Map.new(Application.get_env(app, :index_unmounted, %{}))]
  end

  defp nullable?(table, column) do
    Ecto.Adapters.SQL.query!(PawChart.Repo, "SELECT is_nullable FROM information_schema.columns WHERE table_name = $1 AND column_name = $2", [table, column]).rows ==
      [["YES"]]
  end

  defp ddl!(sql), do: Ecto.Adapters.SQL.query!(PawChart.Repo, sql, [])

  test "POSITIVE CONTROL: the migrated database has both sort columns NOT NULL and the verifier reports no violation" do
    refute nullable?("pmp_plan", "pmp_name")
    refute nullable?("pqk_ticket", "pqk_subject")
    assert Indexes.violations(opts()) == []
  end

  test "RED PATH: re-creating either nullable column makes the verifier flag exactly that table and sort attribute" do
    ddl!("ALTER TABLE pmp_plan ALTER COLUMN pmp_name DROP NOT NULL")
    assert [plan] = Indexes.violations(opts())
    assert plan =~ "PawChart.Operator.Plan (pmp_plan): sort attribute :name is `allow_nil? false`"

    ddl!("ALTER TABLE pqk_ticket ALTER COLUMN pqk_subject DROP NOT NULL")
    violations = Indexes.violations(opts())
    assert length(violations) == 2
    assert Enum.any?(violations, &(&1 =~ "PawChart.Operator.Ticket (pqk_ticket): sort attribute :subject"))

    # recovery: the constraint back, and the verifier is clean again
    ddl!("ALTER TABLE pmp_plan ALTER COLUMN pmp_name SET NOT NULL")
    ddl!("ALTER TABLE pqk_ticket ALTER COLUMN pqk_subject SET NOT NULL")
    assert Indexes.violations(opts()) == []
  end

  test "the NOT NULL is real: a plan without a name and a ticket without a subject are each refused by the database, naming that column" do
    org = Ecto.UUID.dump!(Ecto.UUID.generate())
    plan = "INSERT INTO pmp_plan (pmp_org_id, pmp_name, pmp_inserted_at, pmp_updated_at) VALUES ($1, $2, now(), now())"
    ticket = "INSERT INTO pqk_ticket (pqk_org_id, pqk_subject, pqk_inserted_at, pqk_updated_at) VALUES ($1, $2, now(), now())"

    # each insert is pinned to ITS column: any other missing NOT NULL column would name another one
    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation, column: "pmp_name"}}} =
             Ecto.Adapters.SQL.query(PawChart.Repo, plan, [org, nil])

    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation, column: "pqk_subject"}}} =
             Ecto.Adapters.SQL.query(PawChart.Repo, ticket, [org, nil])

    # POSITIVE CONTROL: the same two inserts WITH a value succeed, so the refusals above are about the NULL and nothing else
    assert {:ok, %{num_rows: 1}} = Ecto.Adapters.SQL.query(PawChart.Repo, plan, [org, "Basic"])
    assert {:ok, %{num_rows: 1}} = Ecto.Adapters.SQL.query(PawChart.Repo, ticket, [org, "Printer on fire"])
  end
end
