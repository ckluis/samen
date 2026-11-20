defmodule Samen.TestDb do
  @moduledoc """
  The one way a test helper, CI bootstrap or verifier drops and re-creates a TEST or SCRATCH database. Sibling of
  `Samen.TestSandbox` / `Samen.Factory`: test infra shipped in lib so every app and every generated app uses it.

  ## Why not `storage_down` then `storage_up`

  `ci.sh` runs ~20 `mix` commands back to back against one `<app>_test` database. Postgres ends a backend
  ASYNCHRONOUSLY after the client socket closes, so a backend of the PREVIOUS mix process can still be alive when the
  next one drops the database. `Ecto.Adapters.Postgres.storage_down/1` then fails ("database ... is being accessed by
  other users"); the old helpers discarded that with `_ =`, and `storage_up/1` answered `{:error, :already_up}` —
  a bare `MatchError` on GitHub Actions (`ci (app_demo)`, step `mix test --only adversarial`).

  ## What this does

      Samen.TestDb.reset!(Repo.config())   # drop (if present) + create, or raise
      Samen.TestDb.drop!(config)           # cleanup of a scratch database, or raise

  The drop is `DROP DATABASE IF EXISTS "<db>" WITH (FORCE)` issued over the maintenance database
  (`:maintenance_database`, default `postgres`, as `storage_down/1` does). `WITH (FORCE)` (PostgreSQL 13+; CI runs
  `pgvector/pgvector:0.8.0-pg16`) makes the SERVER terminate the lingering backends and wait for them to exit, so the
  drop is deterministic — no sleep, no retry window. Every failure raises with the database name and the real
  Postgres/driver error; `{:error, :already_up}` after a successful drop is impossible by construction (and raises
  if it ever happens).

  ## Safety

  FORCE kills other sessions, so both functions REFUSE (`ArgumentError`, before any connection is made) a database
  that is not a test/scratch database: the name must contain a `test` word (`demo_test`, `demo_test_lane2`,
  `samen_core_test_rvbackfill_42`) or end in `_downcheck_<hex>` (the `mix samen.verify.migrations` scratch name).
  """

  @maintenance_default "postgres"
  @test_name ~r/(^|_)test(_|$)|_downcheck_[0-9a-f]+$/

  @doc "Drop (if present) and create the database of `config`. Raises with the real error on any failure."
  @spec reset!(keyword()) :: :ok
  def reset!(config) do
    drop!(config)

    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Samen.TestDb: could not create database #{inspect(db!(config))} after dropping it: #{format(reason)}"
    end
  end

  @doc "Drop the database of `config` if present, terminating any session still connected. Raises on failure."
  @spec drop!(keyword()) :: :ok
  def drop!(config) do
    db = db!(config)
    guard!(db)

    case run(config, "DROP DATABASE IF EXISTS #{quote_ident(db)} WITH (FORCE)") do
      :ok -> :ok
      {:error, error} -> raise "Samen.TestDb: could not drop database #{inspect(db)}: #{format(error)}"
    end
  end

  @doc "True when `name` is a database these helpers will drop."
  @spec test_database?(String.t()) :: boolean()
  def test_database?(name) when is_binary(name), do: Regex.match?(@test_name, name)

  defp guard!(db) do
    unless test_database?(db) do
      raise ArgumentError,
            "Samen.TestDb refuses to drop #{inspect(db)}: not a test/scratch database (the name must contain a " <>
              "`test` word or end in `_downcheck_<hex>`). Dropping uses WITH (FORCE), which kills other sessions."
    end
  end

  defp db!(config), do: Keyword.fetch!(config, :database)

  defp quote_ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  defp format(%{__exception__: true} = e), do: Exception.message(e)
  defp format(other) when is_binary(other), do: other
  defp format(other), do: inspect(other)

  # One short-lived connection to the maintenance database, in a supervised task so a failed connect (backoff
  # :stop) cannot take the caller down. A failed connect surfaces from Postgrex only as a killed connection (the
  # real error reaches nothing but the log), so on failure the connect is replayed ONCE synchronously through
  # `Postgrex.Protocol.connect/1` — the DBConnection callback, which returns the real `{:error, exception}`
  # (refused, unknown role, bad password, ...).
  defp run(config, sql) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    maintenance = Keyword.get(config, :maintenance_database, @maintenance_default)

    opts =
      config
      |> Keyword.drop([:name, :log, :pool, :pool_size])
      |> Keyword.put(:database, maintenance)
      |> Keyword.put(:backoff_type, :stop)
      |> Keyword.put(:max_restarts, 0)

    timeout = Keyword.get(config, :timeout, 15_000) + 15_000
    {:ok, sup} = Task.Supervisor.start_link()

    try do
      task =
        Task.Supervisor.async_nolink(sup, fn ->
          {:ok, conn} = Postgrex.start_link(opts)
          result = Postgrex.query(conn, sql, [], timeout: timeout)
          GenServer.stop(conn)
          result
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {:ok, _}} -> :ok
        {:ok, {:error, %Postgrex.Error{} = error}} -> {:error, error}
        {:ok, {:error, _connection_error}} -> real_connect_error(opts)
        {:exit, {%Postgrex.Error{} = error, _}} -> {:error, error}
        {:exit, reason} -> real_connect_error(opts, reason)
        nil -> {:error, "timed out after #{timeout} ms"}
      end
    after
      Supervisor.stop(sup)
    end
  end

  defp real_connect_error(opts, reason \\ :connection_failed) do
    case Postgrex.Protocol.connect(Keyword.put_new(opts, :types, Postgrex.DefaultTypes)) do
      {:error, error} ->
        {:error, error}

      {:ok, state} ->
        Postgrex.Protocol.disconnect(:normal, state)
        {:error, "the maintenance connection failed (#{Exception.format_exit(reason)}) but an immediate retry connected"}
    end
  end
end
