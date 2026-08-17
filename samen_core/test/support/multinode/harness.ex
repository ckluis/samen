defmodule Samen.MultiNode.Harness do
  @moduledoc """
  Boot/teardown machinery for the L4 two-node Oban proof (T90).

  The primary (test) node owns the dedicated database lifecycle and spawns two
  real BEAM PEER nodes (`:peer`, OTP 25+) on `127.0.0.1`, each of which starts its
  OWN `Samen.MultiNode.Repo` connection pool and its OWN Oban supervisor with
  RUNNING producers against the SAME Postgres. This is a genuine distributed
  topology — leadership and exactly-once are enforced by Postgres, exactly as in
  production — not a single-node simulation.

  Everything spawns and joins within the caller's lifecycle: no backgrounded
  processes, no polling loops that outlive the test.
  """

  @oban_name Samen.MultiNode.Oban
  @primary :"samen_primary@127.0.0.1"

  def oban_name, do: @oban_name

  @doc "The `Samen.MultiNode.Repo` config (creds for the dedicated DB)."
  def repo_config, do: Application.fetch_env!(:samen_core, Samen.MultiNode.Repo)

  @doc """
  Start Erlang distribution on the primary node (idempotent). Requires a running
  `epmd` — the `SAMEN_MULTINODE` ci tier / harness starts one first.
  """
  def ensure_distribution! do
    unless Node.alive?() do
      case :net_kernel.start([@primary, :longnames]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> raise "could not start distribution (is epmd up?): #{inspect(reason)}"
      end

      :erlang.set_cookie(node(), :samen_multinode_cookie)
    end

    :ok
  end

  @doc """
  Drop, create and migrate the dedicated proof database from the SAME migration
  set as `SamenCore.TestRepo`, then (re)create the `mn_exec` execution ledger.
  Repeatable — safe to call twice (drops first).
  """
  def create_and_migrate_db! do
    config = repo_config()
    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok = Ecto.Adapters.Postgres.storage_up(config)

    {:ok, pid} = Samen.MultiNode.Repo.start_link(config)

    migrations = Path.join(:code.priv_dir(:samen_core), "test_repo/migrations")
    Ecto.Migrator.run(Samen.MultiNode.Repo, migrations, :up, all: true)

    Samen.MultiNode.Repo.query!("""
    CREATE TABLE IF NOT EXISTS mn_exec (
      id bigserial PRIMARY KEY,
      job_key text NOT NULL,
      node text NOT NULL,
      worker text NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    reset_ledger!()
    Supervisor.stop(pid)
    :ok
  end

  @doc "Start `Samen.MultiNode.Repo` on the PRIMARY node for setup/assertions."
  def start_primary_repo! do
    {:ok, pid} = Samen.MultiNode.Repo.start_link(repo_config())
    pid
  end

  @doc "Truncate the execution ledger between proof phases."
  def reset_ledger! do
    Samen.MultiNode.Repo.query!("TRUNCATE mn_exec RESTART IDENTITY")
    :ok
  end

  @doc """
  Spawn a peer node, wire its code paths + samen_core app env, and boot a
  `Samen.MultiNode.Repo` + a producing Oban supervisor on it. Returns
  `{peer_pid, node_name}`.
  """
  def start_oban_peer!(short_name, queues) do
    cookie = :erlang.get_cookie()

    paths =
      :code.get_path()
      |> Enum.flat_map(fn p -> [~c"-pa", p] end)

    {:ok, peer_pid, nodename} =
      :peer.start_link(%{
        name: short_name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(cookie)] ++ paths
      })

    # App env is per-node — push the whole :samen_core env, then point the reveal
    # repo + Oban at the dedicated proof DB/instance for THIS node.
    app_env = Application.get_all_env(:samen_core)
    :ok = :erpc.call(nodename, __MODULE__, :configure_peer, [app_env, repo_config()])
    :ok = :erpc.call(nodename, __MODULE__, :boot_oban, [queues])

    {peer_pid, nodename}
  end

  @doc false
  # Runs ON the peer. Installs the app env + proof-DB overrides.
  def configure_peer(app_env, repo_config) do
    Enum.each(app_env, fn {k, v} -> Application.put_env(:samen_core, k, v) end)
    Application.put_env(:samen_core, Samen.MultiNode.Repo, repo_config)
    Application.put_env(:samen_core, :reveal_grant_repo, Samen.MultiNode.Repo)
    :ok
  end

  @doc false
  # Runs ON the peer, INSIDE an ephemeral erpc process. Repo/Oban `start_link` to
  # their caller, so they must be owned by a PERSISTENT process — otherwise they
  # die the instant this erpc call returns. We spawn an unlinked keeper that starts
  # them and then parks forever; it owns the links and lives until `:peer.stop`
  # tears the whole node down.
  def boot_oban(queues) do
    caller = self()

    spawn(fn ->
      try do
        {:ok, _} = Application.ensure_all_started(:ash_postgres)
        {:ok, _} = Application.ensure_all_started(:oban)

        # Oban resolves a job's worker via `String.to_existing_atom/1` — the atom
        # only exists once the module is LOADED on this node. A bare peer has not
        # referenced these yet, so preload every worker the proof enqueues (else
        # Oban discards with "unknown worker").
        Enum.each(
          [
            Samen.MultiNode.CountWorker,
            Samen.MultiNode.UniqueWorker,
            Samen.MultiNode.NoUniqueWorker,
            Samen.Reveal.AutoRevokeWorker
          ],
          &Code.ensure_loaded!/1
        )

        {:ok, _} = Samen.MultiNode.Repo.start_link(repo_config())

        {:ok, _} =
          Oban.start_link(
            name: @oban_name,
            repo: Samen.MultiNode.Repo,
            queues: queues,
            # `Oban.Peers.Database` DB leadership + `Oban.Notifiers.Postgres` —
            # Postgres-coordinated, so leadership/exactly-once hold across nodes that
            # share only the database (the production topology). The 2s peer interval
            # doubles as the leader-lease TTL: when the leader node dies ungracefully,
            # the survivor deletes the expired lease and takes over within ~2s, so the
            # failover proof does not wait the 30s default. Fast stage_interval so the
            # newly-elected leader promotes the scheduled job promptly.
            peer: {Oban.Peers.Database, interval: :timer.seconds(2)},
            stage_interval: 500
          )

        send(caller, {:booted, :ok})
      catch
        kind, reason -> send(caller, {:booted, {:error, {kind, reason}}})
      end

      Process.sleep(:infinity)
    end)

    receive do
      {:booted, :ok} -> :ok
      {:booted, err} -> raise "peer Oban boot failed: #{inspect(err)}"
    after
      20_000 -> raise "peer Oban boot timed out"
    end
  end

  @doc """
  Bulk-enqueue `changesets` through the peer's Oban (counts as that node). Uses
  `insert_all`, which is correct for DISTINCT jobs but deliberately does NOT
  enforce `unique` — the uniqueness proof must use `insert_each_on/2`.
  """
  def enqueue_on(nodename, changesets) do
    :erpc.call(nodename, Oban, :insert_all, [@oban_name, changesets])
  end

  @doc """
  Enqueue `changesets` ONE AT A TIME via `Oban.insert/2` on the peer — the path
  that DOES enforce `unique` (unlike `insert_all`). This is what the uniqueness
  dedup proof needs.
  """
  def insert_each_on(nodename, changesets) do
    :erpc.call(nodename, __MODULE__, :do_insert_each, [changesets])
  end

  @doc false
  def do_insert_each(changesets) do
    Enum.each(changesets, fn cs -> {:ok, _} = Oban.insert(@oban_name, cs) end)
    :ok
  end

  @doc """
  Stop a peer node (a clean simulation of node death for the failover proof).
  Tolerant: the peer is LINKED to its spawning test process, so by the time an
  `on_exit` callback fires it may already be terminating — swallow that race.
  """
  def stop_peer(peer_pid) do
    try do
      :peer.stop(peer_pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc "Keys in `mn_exec` that were executed MORE THAN ONCE (a double-grab)."
  def duplicate_keys do
    %{rows: rows} =
      Samen.MultiNode.Repo.query!(
        "SELECT job_key, count(*) FROM mn_exec GROUP BY job_key HAVING count(*) > 1"
      )

    Enum.map(rows, fn [k, n] -> {k, n} end)
  end

  @doc "How many rows a given key executed (0 if none)."
  def exec_count(key) do
    %{rows: [[n]]} =
      Samen.MultiNode.Repo.query!("SELECT count(*) FROM mn_exec WHERE job_key = $1", [key])

    n
  end

  @doc "Distinct executed keys."
  def distinct_key_count do
    %{rows: [[n]]} = Samen.MultiNode.Repo.query!("SELECT count(DISTINCT job_key) FROM mn_exec")
    n
  end

  @doc "Total executions recorded."
  def total_execs do
    %{rows: [[n]]} = Samen.MultiNode.Repo.query!("SELECT count(*) FROM mn_exec")
    n
  end

  # ---- Reveal auto-revoke failover (done-criteria #3) ---------------------------

  @doc """
  Insert a live (unrevoked) `rvg_reveal_grant` row directly, expiring `in_ms` from
  now. Returns the grant id. Plain Ecto (the grant model is kernel infra, not an
  Ash resource), so no domain wiring is needed on the primary.
  """
  def insert_grant!(in_ms) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, in_ms, :millisecond)
    id = Ecto.UUID.generate()
    request_id = Ecto.UUID.generate()

    Samen.MultiNode.Repo.query!(
      """
      INSERT INTO rvg_reveal_grant
        (rvg_id, rvg_request_id, rvg_subject_id, rvg_requestor_id, rvg_granted_by,
         rvg_reason, rvg_expires_at, rvg_revoked_at, rvg_inserted_at, rvg_updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, $8, $8)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(request_id),
        "subj_failover",
        "requestor:node_a",
        "approver:distinct",
        "L4 failover proof",
        expires,
        now
      ]
    )

    {id, expires}
  end

  @doc "Enqueue the REAL `Samen.Reveal.AutoRevokeWorker` on `nodename`, scheduled at `expires`."
  def enqueue_auto_revoke_on(nodename, grant_id, expires) do
    cs = Samen.Reveal.AutoRevokeWorker.new(%{grant_id: grant_id}, scheduled_at: expires)
    :erpc.call(nodename, Oban, :insert!, [@oban_name, cs])
  end

  @doc "True once the grant's `revoked_at` is set (auto-revoke ran)."
  def grant_revoked?(grant_id) do
    %{rows: [[revoked]]} =
      Samen.MultiNode.Repo.query!(
        "SELECT rvg_revoked_at FROM rvg_reveal_grant WHERE rvg_id = $1",
        [Ecto.UUID.dump!(grant_id)]
      )

    not is_nil(revoked)
  end

  @doc "Count of `expired` audit rows for a grant (must be EXACTLY 1 — no double-revoke)."
  def expired_audit_count(grant_id) do
    %{rows: [[n]]} =
      Samen.MultiNode.Repo.query!(
        "SELECT count(*) FROM rvl_reveal_audit WHERE rvl_grant_id = $1 AND rvl_event = 'expired'",
        [Ecto.UUID.dump!(grant_id)]
      )

    n
  end

  @doc "Which nodes executed jobs (proves BOTH peers actually did work)."
  def executing_nodes do
    %{rows: rows} = Samen.MultiNode.Repo.query!("SELECT DISTINCT node FROM mn_exec")
    Enum.map(rows, fn [n] -> n end)
  end

  @doc """
  Block until `pred.()` is true or `timeout_ms` elapses. Polls the DB on the
  PRIMARY node only (the peers do the async work); this is a join, not a
  background poller — it returns control to the test.
  """
  def wait_until(pred, timeout_ms \\ 15_000, step_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(pred, deadline, step_ms)
  end

  defp do_wait(pred, deadline, step_ms) do
    if pred.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:timeout}
      else
        Process.sleep(step_ms)
        do_wait(pred, deadline, step_ms)
      end
    end
  end
end
