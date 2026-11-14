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
  @probes {__MODULE__, :probes}

  def fail(ops) when is_list(ops) do
    Process.put(@key, ops)
    :ok
  end
  def heal do
    Process.delete(@key)
    Process.delete(@probes)
    :ok
  end

  @doc """
  Make this module resolvable by `Ecto.Adapters.SQL.query!(repo, …)` (and anything else that looks a repo up by name
  in `Ecto.Repo.Registry`): it registers a stand-in process under this module's name that carries the real repo's
  adapter meta, so those calls use the SAME pool (and sandbox connection) as `SamenCore.TestRepo`. Idempotent. Call it
  from a test that runs a code path with raw SQL helpers under `repo: Samen.FaultRepo` (e.g. `Samen.Erasure.shred/2`).
  """
  def register_as_repo! do
    if GenServer.whereis(__MODULE__) == nil do
      {:ok, pid} = Agent.start(fn -> :ok end, name: __MODULE__)
      :ok = Ecto.Repo.Registry.associate(pid, __MODULE__, Ecto.Repo.Registry.lookup(Real))
    end

    :ok
  end

  @doc """
  How many `to_regclass` existence probes (one per `Samen.AuditChain.Writer.write/2`) this process has issued through
  this repo since the last `heal/0`. `fail([{:probe_nth, k}])` fails exactly the k-th of them, to take down ONE audit
  write among several in a transaction.
  """
  def probe_count, do: Process.get(@probes, 0)

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
    n = probe_count() + 1
    Process.put(@probes, n)
    check!(:probe)

    for {:probe_nth, k} <- Process.get(@key, []), k == n do
      raise DBConnection.ConnectionError, "connection not available (Samen.FaultRepo probe ##{n})"
    end

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
  def get(queryable, id, opts \\ []) do
    check!(:get)
    Real.get(queryable, id, opts)
  end
  def insert(cs, opts \\ []) do
    check!(:insert)
    Real.insert(cs, opts)
  end
  def insert!(cs, opts \\ []) do
    check!(:insert!)
    Real.insert!(cs, opts)
  end
  def update_all(q, updates, opts \\ []) do
    check!(:update_all)
    Real.update_all(q, updates, opts)
  end
  def aggregate(q, kind, opts \\ []) when is_atom(kind) do
    check!(:aggregate)
    Real.aggregate(q, kind, opts)
  end
  def aggregate(q, kind, field, opts) do
    check!(:aggregate)
    Real.aggregate(q, kind, field, opts)
  end
  def delete_all(q, opts \\ []) do
    check!(:delete_all)
    Real.delete_all(q, opts)
  end
  def update(cs, opts \\ []) do
    check!(:update)
    Real.update(cs, opts)
  end
  # An `Ecto.Multi` must run its steps against THIS module (so `Multi.run` callbacks see the faults), not the
  # real repo: the same wrap/return `Ecto.Repo.Transaction` uses, with `self()` as the repo handed to the steps.
  def transaction(multi, opts \\ [])

  def transaction(%Ecto.Multi{} = multi, opts) do
    check!(:transaction)
    case Ecto.Multi.__apply__(multi, __MODULE__, &Real.transaction(&1, opts), &Real.rollback/1) do
      {:ok, values} -> {:ok, values}
      {:error, {key, error_value, values}} -> {:error, key, error_value, values}
    end
  end

  def transaction(fun, opts) do
    check!(:transaction)
    Real.transaction(fun, opts)
  end
  def in_transaction?, do: Real.in_transaction?()
  def rollback(value), do: Real.rollback(value)
end
