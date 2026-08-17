defmodule Samen.Backup.Restore.LocalPgDump do
  @moduledoc """
  The LOCALLY-PROVABLE restore target for backup verification (L6 / T92).

  Restores a real `pg_dump` artifact into a real, throwaway scratch database with
  `pg_restore` (or `psql` for a plain-SQL dump) and hands the verifier a live
  connection to it. This is what makes L6 provable WITHOUT cloud credentials: the
  verifier checks bytes that actually round-tripped through Postgres, and a
  truncated/corrupt/missing artifact makes `pg_restore` fail for real.

  Config (`map`):
    * `:dump_path` — path to the dump artifact (required to be configured).
    * `:format` — `:custom` (default, `pg_dump -Fc` → `pg_restore`) or `:plain`
      (`pg_dump` plain SQL → `psql -f`).
    * `:conn` — Postgrex start opts for the SERVER (username/hostname/password/port).
    * `:scratch_database` — name of the scratch DB to (re)create and restore into.

  The real cloud restore target (a Neon PITR branch or an S3-hosted artifact —
  L1/L3) is credential-gated and stays behind `Samen.Backup.Restore.NotConfigured`;
  this adapter proves the verification LOGIC end-to-end on a local server.
  """
  @behaviour Samen.Backup.Restore

  @impl true
  def configured?(config) when is_map(config) do
    is_binary(config[:dump_path]) and
      tool_available?("pg_restore") and
      tool_available?("createdb") and
      tool_available?("dropdb")
  end

  def configured?(_), do: false

  @impl true
  def restore(config, _scratch) do
    dump_path = config[:dump_path]
    scratch_db = config[:scratch_database] || "samen_core_backup_scratch"
    conn_opts = config[:conn] || default_conn()
    format = config[:format] || :custom

    cond do
      is_nil(dump_path) or not File.exists?(dump_path) ->
        {:error, {:artifact_missing, dump_path}}

      true ->
        with :ok <- recreate_scratch(scratch_db, conn_opts),
             :ok <- restore_into(scratch_db, conn_opts, dump_path, format),
             {:ok, pid} <- start_conn(scratch_db, conn_opts) do
          handle = %{
            query: fn sql, params -> safe_query(pid, sql, params) end,
            cleanup: fn ->
              GenServer.stop(pid, :normal, 5_000)
              _ = drop_scratch(scratch_db, conn_opts)
              :ok
            end
          }

          {:ok, handle}
        end
    end
  end

  # ---- pg tooling ---------------------------------------------------------------

  defp recreate_scratch(db, conn) do
    _ = drop_scratch(db, conn)

    case run("createdb", ["-h", conn[:hostname], "-U", conn[:username], db], conn) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:createdb_failed, code, String.slice(out, 0, 500)}}
    end
  end

  defp drop_scratch(db, conn) do
    run("dropdb", ["--if-exists", "-h", conn[:hostname], "-U", conn[:username], db], conn)
    :ok
  end

  defp restore_into(db, conn, dump_path, :custom) do
    # --exit-on-error so a corrupt/partial artifact FAILS loudly (nonzero exit)
    # rather than restoring a half-populated DB that would silently pass.
    args = [
      "--exit-on-error",
      "--no-owner",
      "--no-privileges",
      "-h",
      conn[:hostname],
      "-U",
      conn[:username],
      "-d",
      db,
      dump_path
    ]

    case run("pg_restore", args, conn) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:restore_failed, code, String.slice(out, 0, 500)}}
    end
  end

  defp restore_into(db, conn, dump_path, :plain) do
    args = [
      "-v",
      "ON_ERROR_STOP=1",
      "-h",
      conn[:hostname],
      "-U",
      conn[:username],
      "-d",
      db,
      "-f",
      dump_path
    ]

    case run("psql", args, conn) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:restore_failed, code, String.slice(out, 0, 500)}}
    end
  end

  defp start_conn(db, conn) do
    Postgrex.start_link(
      hostname: conn[:hostname],
      username: conn[:username],
      password: conn[:password] || "",
      port: conn[:port] || 5432,
      database: db
    )
  end

  defp safe_query(pid, sql, params) do
    case Postgrex.query(pid, sql, params) do
      {:ok, res} -> {:ok, %{rows: res.rows}}
      {:error, err} -> {:error, err}
    end
  end

  defp run(bin, args, conn) do
    env = []
    env = if conn[:password] not in [nil, ""], do: [{"PGPASSWORD", conn[:password]} | env], else: env
    System.cmd(bin, args, env: env, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {inspect(e), 127}
  end

  defp tool_available?(bin), do: System.find_executable(bin) != nil

  defp default_conn do
    [
      hostname: "localhost",
      username: System.get_env("USER") || "postgres",
      password: "",
      port: 5432
    ]
  end
end
