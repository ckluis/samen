defmodule Samen.SingleNode.Lease do
  @moduledoc """
  The database half of the single-node guard (`Samen.SingleNode`, ADR-054): detects a SECOND serving instance
  on the same database — the real-world failure (two machines behind one load balancer), which is not an Erlang
  cluster and so never reaches `Samen.SingleNode.Peers`.

  ## Mechanism — a shared session advisory lock on a dedicated connection

  Every serving instance owns ONE dedicated Postgres connection (a size-1 `Postgrex` pool, outside the Ecto
  pool and the SQL sandbox). When a session is established, `after_connect/3` takes
  `pg_advisory_lock_shared(k1, k2)` and sets the session variable `samen.single_node_lease`. A SHARED lock never
  blocks anyone, so every instance gets it; each check counts the holders in `pg_locks`:

      other holders = 0  ->  :single
      other holders > 0  ->  :overlap   (symmetric: BOTH instances see it)

  Why this and not an exclusive lock or a heartbeat row:

    * **It cannot go stale.** Postgres releases a session lock the instant the session ends (a crash, a
      `kill -9`, a network partition once the server notices), so a dead instance never leaves an "overlap"
      behind, and a heartbeat TTL (which has to be tuned against deploy time) does not exist.
    * **It is symmetric.** An exclusive try-lock tells only the loser; the incumbent keeps taking traffic
      unaware. Counting shared holders tells both.
    * **Reconnects are handled by construction, not by a retry.** `after_connect` runs on EVERY new session and
      is the only place the lock is taken, so a dropped connection that the pool re-establishes re-takes it
      before the next query is served. Pool recycling of the Ecto pool is irrelevant (different connection).

  The lease also records whose session is older (`backend_start`); strict mode uses it so only the LATE
  instance refuses to become ready (an instance that lost its session and reconnected counts as late).

  ## Fail-honest

  Every check returns `:single`, `{:overlap, peers, late?}` or `{:unknown, reason}`; an unreadable state is never
  `:single`: `:connection_down`, `:query_failed`, `:lease_lost` (session variable present but the lock gone,
  e.g. `pg_advisory_unlock_all()`), `:connection_pooler`, `:starting`.

  ## PgBouncer — what can and cannot be detected

  A session lock lives on a SERVER connection. Behind a pooler in TRANSACTION mode a client's statements can land
  on different server connections, so a lock taken by one statement is invisible to the next and this mechanism
  cannot work. It does not guess: the check statement reads the session variable that only `after_connect`
  sets. A statement served by a session that never ran `after_connect` (the variable is absent) can only be a
  pooled one — `after_connect` runs before the pool serves its first query on a new session — and the answer is
  `{:unknown, :connection_pooler}`, loudly, instead of a false "single". The fix is operational: set `lease_url`
  to a DIRECT (unpooled) URL for this one connection. In session-mode pooling the lock works as is. A pooler
  that happens to pin this client to one server connection is indistinguishable from a direct one, and in that
  case the lock really is held by this client's session, so the answer is right.

  ## Reporting

  First observation of an overlap logs a warning (rolling deploys do this on purpose). Once the overlap has
  lasted `grace_ms` ONE value-free `Samen.Observability.Failure` report is filed per episode and
  `[:samen, :single_node, :overlap]` fires. Entering `:unknown` files a report and fires
  `[:samen, :single_node, :unknown]`. Every check emits `[:samen, :single_node, :state]` (peers, unknown,
  overlap seconds). The state itself is published in a protected ETS table that `Samen.SingleNode.status/1` reads.
  """
  use GenServer

  require Logger

  alias Samen.Observability.Failure

  # ASCII "SAME" / "NODE" as the two int4 halves of the advisory key. Advisory locks are per database.
  @key {0x53414D45, 0x4E4F4445}
  @guc "samen.single_node_lease"
  @table :samen_single_node

  @doc "The default ETS table holding the published status."
  @spec default_table() :: atom()
  def default_table, do: @table

  @doc "The advisory lock key `{int4, int4}`."
  @spec key() :: {pos_integer(), pos_integer()}
  def key, do: @key

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Options: `:repo` (connection settings come from `repo.config/0`) or `:connect_opts` (Postgrex options);
  `:name`, `:table`, `:lock_key`, `:strict`, `:grace_ms`, `:interval_ms`, `:query_timeout_ms` (5 000), `:pool_opts` (extra `DBConnection` options, e.g. `queue_target`, tests), `:lease_url` (default from
  `Samen.SingleNode.config/0`); `:clock` (a 0-arity monotonic-ms function, tests).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Run one check now and return the resolved `Samen.SingleNode.status/1`. Synchronous."
  @spec check_now(GenServer.server()) :: Samen.SingleNode.status()
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now, 15_000)

  @doc false
  # Runs inside the connection process on EVERY new session (see the moduledoc).
  def after_connect(conn, k1, k2) do
    Postgrex.query!(conn, "SELECT pg_advisory_lock_shared(#{k1}, #{k2})", [])
    Postgrex.query!(conn, "SELECT set_config('#{@guc}', 'on', false)", [])
    :ok
  end

  # ---------------------------------------------------------------------------
  # Pure interpretation of the check statement
  # ---------------------------------------------------------------------------

  @doc """
  Interpret the check statement's result: `:single | {:overlap, peers, late?} | {:unknown, reason}`.
  Rows are `[my_pid, holder_pid | nil, holder_session_start_us | nil, session_variable | nil]`.
  """
  @spec interpret(term()) :: :single | {:overlap, pos_integer(), boolean()} | {:unknown, atom()}
  def interpret({:ok, %Postgrex.Result{rows: [[me, _, _, flag] | _] = rows}}) do
    holders = rows |> Enum.reject(fn [_, pid, _, _] -> is_nil(pid) end) |> Enum.uniq_by(fn [_, pid, _, _] -> pid end)

    cond do
      flag in [nil, ""] ->
        {:unknown, :connection_pooler}

      not Enum.any?(holders, fn [_, pid, _, _] -> pid == me end) ->
        {:unknown, :lease_lost}

      true ->
        mine = Enum.find(holders, fn [_, pid, _, _] -> pid == me end)
        others = Enum.reject(holders, fn [_, pid, _, _] -> pid == me end)

        case others do
          [] -> :single
          _ -> {:overlap, length(others), late?(mine, others)}
        end
    end
  end

  def interpret({:error, %DBConnection.ConnectionError{}}), do: {:unknown, :connection_down}
  def interpret(_other), do: {:unknown, :query_failed}

  # Ordered by (session start, pid): late = some peer is strictly older. A session whose start is not visible
  # to this role (NULL) cannot be ordered, so it never makes us "late" (we do not refuse on a guess).
  defp late?([_, my_pid, my_start, _], others) when is_integer(my_start) do
    Enum.any?(others, fn [_, pid, start, _] -> is_integer(start) and {start, pid} < {my_start, my_pid} end)
  end

  defp late?(_mine, _others), do: false

  defp check_sql(k1, k2) do
    """
    SELECT pg_backend_pid(), l.pid, (extract(epoch from a.backend_start) * 1000000)::bigint,
           current_setting('#{@guc}', true)
    FROM (SELECT 1) AS one
    LEFT JOIN pg_locks l ON l.locktype = 'advisory' AND l.classid = #{k1} AND l.objid = #{k2}
         AND l.objsubid = 2 AND l.granted
         AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    LEFT JOIN pg_stat_activity a ON a.pid = l.pid
    """
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Samen.SingleNode.config()
    table = Keyword.get(opts, :table, @table)
    {k1, k2} = Keyword.get(opts, :lock_key, @key)

    # The table is created before the connection so `status/1` is never `:disarmed` while a lease exists.
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    {:ok, conn} =
      Postgrex.start_link(
        connect_opts(opts, config) ++
          [pool_size: 1, after_connect: {__MODULE__, :after_connect, [k1, k2]}] ++ Keyword.get(opts, :pool_opts, [])
      )

    state = %{
      table: table,
      conn: conn,
      sql: check_sql(k1, k2),
      strict: Keyword.get(opts, :strict, config.strict),
      grace_ms: Keyword.get(opts, :grace_ms, config.grace_ms),
      interval_ms: Keyword.get(opts, :interval_ms, config.interval_ms),
      query_timeout_ms: Keyword.get(opts, :query_timeout_ms, 5_000),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      kind: :unknown,
      since: nil,
      reported?: false,
      last_reason: nil
    }

    publish(state, %{state: :unknown, reason: :starting, strict: state.strict})
    {:ok, state, {:continue, :first_check}}
  end

  @impl true
  def handle_continue(:first_check, state) do
    state = check(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    state = check(state)
    {:reply, Samen.SingleNode.status(table: state.table, now: state.clock.()), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = check(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(state), do: Process.send_after(self(), :tick, state.interval_ms)

  defp connect_opts(opts, config) do
    base =
      case Keyword.fetch(opts, :connect_opts) do
        {:ok, connect_opts} ->
          connect_opts

        :error ->
          repo_config = Keyword.fetch!(opts, :repo).config()
          lease_url = Keyword.get(opts, :lease_url, config.lease_url)

          if lease_url,
            do: Keyword.merge(repo_config, Ecto.Repo.Supervisor.parse_url(lease_url)),
            else: repo_config
      end

    Keyword.take(base, [
      :hostname,
      :endpoints,
      :port,
      :username,
      :password,
      :database,
      :ssl,
      :ssl_opts,
      :socket_dir,
      :socket,
      :socket_options,
      :parameters,
      :connect_timeout
    ])
  end

  defp check(state) do
    verdict = Postgrex.query(state.conn, state.sql, [], timeout: state.query_timeout_ms) |> interpret()
    apply_verdict(verdict, state)
  end

  # ---------------------------------------------------------------------------
  # Transitions: publish, report, emit
  # ---------------------------------------------------------------------------

  defp apply_verdict(:single, state) do
    if state.kind == :overlap, do: Logger.notice("[Samen.SingleNode] overlap cleared: this instance is alone on the database again")
    emit(0, 0, 0)
    publish(state, %{state: :single, strict: state.strict})
    %{state | kind: :single, since: nil, reported?: false}
  end

  defp apply_verdict({:overlap, peers, late?}, state) do
    now = state.clock.()
    since = if state.kind == :overlap, do: state.since, else: now

    if state.kind != :overlap do
      Logger.warning(
        "[Samen.SingleNode] another instance shares this database peers=#{peers}; fine during a rolling deploy, " <>
          "reported as CRITICAL after #{div(state.grace_ms, 1000)}s (#{Samen.SingleNode.adr()})"
      )
    end

    exceeded? = now - since >= state.grace_ms
    reported? = state.reported? or (exceeded? and report_overlap(peers, state))

    emit(peers, 0, div(now - since, 1000))

    publish(state, %{
      state: :overlap,
      peers: peers,
      since: since,
      late?: late?,
      grace_ms: state.grace_ms,
      strict: state.strict
    })

    %{state | kind: :overlap, since: since, reported?: reported?}
  end

  defp apply_verdict({:unknown, reason}, state) do
    if state.kind != :unknown or state.last_reason != reason do
      Failure.report(:single_node_state, nil, reason)
      :telemetry.execute([:samen, :single_node, :unknown], %{count: 1}, %{})
    end

    emit(0, 1, 0)
    publish(state, %{state: :unknown, reason: reason, strict: state.strict})
    Map.merge(state, %{kind: :unknown, since: nil, reported?: false, last_reason: reason})
  end

  defp report_overlap(peers, state) do
    Logger.error(
      "[Samen.SingleNode] #{peers} other instance(s) have shared this database for more than " <>
        "#{div(state.grace_ms, 1000)}s — Samen runs as ONE instance per database (#{Samen.SingleNode.adr()})"
    )

    Failure.report(:write, :single_node_overlap, nil, :overlap, [])
    :telemetry.execute([:samen, :single_node, :overlap], %{count: 1}, %{})
    true
  end

  defp emit(peers, unknown, overlap_s) do
    :telemetry.execute([:samen, :single_node, :state], %{peers: peers, unknown: unknown, overlap_seconds: overlap_s}, %{})
  end

  defp publish(state, raw), do: :ets.insert(state.table, {:status, raw})
end
