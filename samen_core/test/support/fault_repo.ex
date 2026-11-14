defmodule Samen.FaultRepo do
  @moduledoc """
  Test infra: a repo that DELEGATES to `SamenCore.TestRepo` and fails the operations a test names, with a real
  `DBConnection.ConnectionError` (what an outage raises) — not a mock of the code under test. Configure per
  test process with `Samen.FaultRepo.fail(ops)` (e.g. `[:probe]` for the `to_regclass` existence probe,
  `[:one, :all, :exists?, :query!]` for the read callbacks); `Samen.FaultRepo.heal()` clears it.

  Pass it wherever a kernel function takes a `:repo` option. Only the callbacks the kernel's seams use are
  implemented; everything not failed is the real repo, so positive controls run through the same module.
  """
  alias SamenCore.TestRepo, as: Real

  @key {__MODULE__, :fail}

  def fail(ops) when is_list(ops) do
    Process.put(@key, ops)
    :ok
  end
  def heal do
    Process.delete(@key)
    :ok
  end

  # `fail([{:sql, "FROM oban_jobs"}])` fails only the queries whose text contains the fragment.
  defp check_sql!(sql) do
    for {:sql, fragment} <- Process.get(@key, []), String.contains?(sql, fragment) do
      raise DBConnection.ConnectionError, "connection not available (Samen.FaultRepo sql #{fragment})"
    end

    :ok
  end

  defp check!(op) do
    if op in Process.get(@key, []) do
      raise DBConnection.ConnectionError, "connection not available (Samen.FaultRepo #{op})"
    end
  end

  def query!(sql, params \\ [])

  def query!("SELECT to_regclass" <> _ = sql, params) do
    check!(:probe)
    check_sql!(sql)
    Real.query!(sql, params)
  end

  def query!(sql, params) do
    check!(:query!)
    check_sql!(sql)
    Real.query!(sql, params)
  end

  def all(q, opts \\ []) do
    check!(:all)
    Real.all(q, opts)
  end
  def one(q, opts \\ []) do
    check!(:one)
    Real.one(q, opts)
  end
  def exists?(q, opts \\ []) do
    check!(:exists?)
    Real.exists?(q, opts)
  end
  def insert(cs, opts \\ []) do
    check!(:insert)
    Real.insert(cs, opts)
  end
  def insert!(cs, opts \\ []) do
    check!(:insert!)
    Real.insert!(cs, opts)
  end
  def update(cs, opts \\ []) do
    check!(:update)
    Real.update(cs, opts)
  end
  def transaction(fun, opts \\ []), do: Real.transaction(fun, opts)
  def rollback(value), do: Real.rollback(value)
end
