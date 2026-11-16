defmodule Samen.SingleNode.Lease do
  @moduledoc """
  The database half of the single-node guard (`Samen.SingleNode`, ADR-054): detects a SECOND serving instance
  on the same database — the real-world failure (two machines behind one load balancer), which is not an Erlang
  cluster and so never reaches `Samen.SingleNode.Peers`.

  ## Mechanism — session advisory locks on a dedicated connection

  Every serving instance owns ONE dedicated Postgres connection (a size-1 `Postgrex` pool, outside the Ecto
  pool and the SQL sandbox). When a session is established, `after_connect/2` runs ONE statement on it that takes
  four SHARED advisory locks and sets a session variable:

    * the presence lock `(k1, k2)`. A shared lock never blocks anyone, so every instance gets it, and each
      check counts the other holders in `pg_locks`;
    * the BOOT EPOCH, two locks `(k1', secs)` and `(k1'', usec)`: microseconds, read from the DATABASE's clock once
      per lease process (so there is no clock skew between machines). It is carried in `pg_locks`, which every role
      can read in full, instead of `pg_stat_activity.backend_start`, which is NULL for another role's session;
    * the BEAT `(k1''', n)`: every verified check replaces it with `n + 1`, so a live holder's beat keeps changing;
    * the session variable `samen.single_node_lease` = a per-boot random token.

      other holders = 0  ->  :single
      other holders > 0  ->  :overlap   (symmetric: BOTH instances see it)

  Why session locks and not an exclusive lock or a heartbeat row:

    * **It is symmetric.** An exclusive try-lock tells only the loser; the incumbent keeps taking traffic
      unaware. Counting shared holders tells both.
    * **Reconnects are handled by construction, not by a retry.** `after_connect` runs on EVERY new session and
      is the only place the locks are taken, so a dropped connection that the pool re-establishes re-takes them
      before the next query is served. The epoch belongs to the lease process, not to the session, so an instance
      that merely lost its connection does NOT become the "late" one.
    * **No table, no migration, no row to expire.**

  ## A lock can go stale: the real bound

  Postgres releases a session lock when the backend ends. A clean exit, a `kill -9` of the BEAM (the kernel sends
  a FIN) and a restart end it at once. A host that dies WITHOUT a FIN (power loss, a partition) leaves its backend
  and locks behind until the server notices, which by default is ~2 h of TCP keepalive. Three layers bound that:

    1. `idle_session_timeout` (Postgres 14+) on the lease session, `session_idle_ms` (default `3 x interval_ms`,
       15 s). While the client lives the session is never idle that long (the lease queries every `interval_ms`, and the pool
       pings an idle connection every `idle_interval`, 1 s by default); a session whose
       client is gone is terminated by the server and its locks vanish. On Postgres < 14 the setting does not
       exist: it is logged, and only layers 2 and 3 apply.
    2. TCP keepalive on both ends (`tcp_keepalives_idle/interval/count` set on the session, `keepalive: true` on the
       client socket): a silent peer is dropped in about 25 s where the transport supports it (not on a unix
       socket).
    3. The BEAT. A holder whose beat has not changed for `stale_ms` (default `3 x interval_ms`) is no longer evidence
       of a second instance: it is `{:unknown, :stale_holder}`, never `:overlap`, so a restarted instance does not
       page, and strict mode does not 503, because of its predecessor's ghost.

  ## Fail-honest

  Every check returns `:single`, `{:overlap, peers, late?, verified?}` or `{:unknown, reason}`; an unreadable state is never
  `:single`: `:connection_down`, `:query_failed`, `:lease_lost` (the session variable is present but the lock is
  gone, e.g. `pg_advisory_unlock_all()`), `:connection_pooler`, `:stale_holder`, `:starting`.

  ## Poolers: what can and cannot be decided (`lease_url` MUST be a direct URL)

  A session lock lives on a SERVER connection. Behind a pooler in TRANSACTION mode (PgBouncer, Neon's pooled
  endpoint) a client's statements can land on different server connections. The lease therefore proves on every
  check that the statement ran on the session it OWNS: the backend pid must equal the one `after_connect` recorded
  (in an `:atomics`, written synchronously by the connection process), the session variable must equal this boot's
  token, and the session must carry exactly this boot's epoch and one beat. Otherwise `{:unknown, :connection_pooler}`:

    * two instances whose statements share ONE server connection: the locks are re-entrant there (one row in
      `pg_locks`), so neither sees "another holder". The variable holds the LAST writer's token, so the other
      fails the token test, and the last writer sees two epochs on its own session. Both are UNKNOWN;
    * a lock and variable left behind on a server connection the lease no longer owns (a pooler keeps it): a
      statement landing there carries this boot's token but not the recorded pid. UNKNOWN.

  The first check that PROVES the statements are multiplexed LATCHES `{:unknown, :connection_pooler}` for the rest of
  the lease process's life (`pooler_proof?/2`) and logs ONE error naming `DATABASE_DIRECT_URL` / `lease_url`. Proof
  is something a direct connection never shows: the session variable absent or holding another boot's token
  (`after_connect` sets it before the pool serves the session, and nobody else runs statements on it), or a backend
  pid that differs from the recorded one with no reconnect while the statement ran. A GENUINE reconnect re-runs
  `after_connect`, which re-records pid and variable, so it never latches; a pid that changed DURING the statement is
  that race, and is not proof. Two epochs or two beats on the session are UNKNOWN for that check but do not latch.

  Be exact about what a pooled lease is: UNKNOWN only from the moment its first statement lands on another server
  connection; until then it can read `single` or `overlap` (a statement that lands on the server connection its own
  `after_connect` locked verifies), and after the pooler recycles that server connection the lease holds no lock
  anywhere, so an instance it shares the database with may read `single` while it serves. A pooled lease also writes
  `idle_session_timeout` and the tcp_keepalives settings onto a SHARED server connection, which every other client on
  it then runs with. It is a misconfiguration to be fixed, not a mode to run in.

  The same leftover is visible to a DIRECT instance sharing the database as a holder it cannot verify: it never
  beats, so after `stale_ms` it is `:stale_holder` (UNKNOWN: not overlap, not a strict 503). A LIVE pooled instance
  looks exactly the same: once latched it never beats again, so to a direct instance it is `:stale_holder` while it
  keeps serving. Before it latches, a pooled instance whose statements happen to land on one server twice in a row
  does beat, and is a second instance to a direct one, but mostly an unconfirmed one. The beat statement checks pid and token IN SQL before it takes anything, so a pooled
  lease cannot leak a lock per check; what it cannot avoid is the lock `after_connect` takes when it connects.

  The fix is operational: `lease_url` must be a DIRECT (unpooled) URL for this one connection (with Neon, the
  host without `-pooler`). In session-mode pooling the lock works as is.

  ## Connection settings

  They come from `repo.config/0`, so a runtime `url`, an `init/2` callback or a `:configure` function that
  resolves dynamic credentials (IAM tokens) applies to the lease too. Everything is passed on to Postgrex except
  the keys that belong to the Ecto pool (`@repo_only`).

  ## Reporting

  First observation of an overlap logs a warning (rolling deploys do this on purpose). Once the overlap has
  lasted `grace_ms` ONE value-free `Samen.Observability.Failure` report is filed per episode and
  `[:samen, :single_node, :overlap]` fires. The overlap clock (`since`) STARTS only on an overlap whose holder is
  confirmed alive (a ghost that never beats must not use up the grace period of a later rolling deploy, and files no
  report); it is reset only by an observed `:single`, and an unreadable or unconfirmed moment in between does not
  restart it. Entering `:unknown` files a report and fires
  `[:samen, :single_node, :unknown]`. Every check emits `[:samen, :single_node, :state]` (peers, unknown,
  overlap seconds) and every new session `[:samen, :single_node, :session]`. The state is published with the time it
  was published (`at`) in a protected ETS table that `Samen.SingleNode.status/1` reads; a state older than
  `stale_ms`, or a lease that should run and does not, reads as UNKNOWN there.
  """
  use GenServer

  require Logger

  alias Samen.Observability.Failure

  # ASCII "SAME" / "NODE" as the two int4 halves of the advisory key. Advisory locks are per database.
  @key {0x53414D45, 0x4E4F4445}
  @guc "samen.single_node_lease"
  @table :samen_single_node
  # 2025-01-01T00:00:00Z: the boot epoch is microseconds since then (secs fits an int4 until 2093).
  @origin_us 1_735_689_600_000_000
  # XOR masks (< 2^31) deriving the epoch/beat lock classes from the presence key's first half.
  @mask_secs 0x2A5A5A5A
  @mask_usec 0x15A5A5A5
  @mask_beat 0x3C3C3C3C
  # atomics slots written by the connection process / the lease
  @a_pid 1
  @a_epoch 3
  # Config keys that belong to the Ecto pool or the repo, not to a dedicated Postgrex connection. EVERYTHING else
  # in `repo.config/0` (`:configure`, `:ssl_opts`, `:parameters`, `:socket_options`, ...) is passed through.
  @repo_only [
    :pool,
    :pool_size,
    :name,
    :after_connect,
    :url,
    :otp_app,
    :repo,
    :telemetry_prefix,
    :log,
    :stacktrace,
    :priv,
    :timeout,
    :loggers,
    :queue_target,
    :queue_interval,
    :ownership_timeout,
    :migration_source,
    :migration_timestamps,
    :migration_lock,
    :migration_default_prefix,
    :migration_primary_key,
    :migration_repo
  ]

  @doc "The default ETS table holding the published status."
  @spec default_table() :: atom()
  def default_table, do: @table

  @doc "The presence advisory lock key `{int4, int4}`."
  @spec key() :: {pos_integer(), pos_integer()}
  def key, do: @key

  @doc "The `{classid, objid}` of the other lock classes of a presence key: `%{secs: k1', usec: k1'', beat: k1'''}`."
  @spec classes({integer(), integer()}) :: %{secs: integer(), usec: integer(), beat: integer()}
  def classes({k1, _k2}) do
    %{secs: Bitwise.bxor(k1, @mask_secs), usec: Bitwise.bxor(k1, @mask_usec), beat: Bitwise.bxor(k1, @mask_beat)}
  end

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
  `:name`, `:table`, `:lock_key`, `:strict`, `:grace_ms`, `:interval_ms`, `:stale_ms` (3 x interval),
  `:session_idle_ms` (3 x interval: `idle_session_timeout` of the lease session), `:query_timeout_ms` (5 000),
  `:pool_opts` (extra `DBConnection` options, e.g. `queue_target`, tests), `:lease_url` (default from
  `Samen.SingleNode.config/0`); `:clock` (a 0-arity monotonic-ms function, tests); `:query_mod` (default `Postgrex`;
  a test double at the connection boundary, see `single_node_lease_test.exs`).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Run one check now and return the resolved `Samen.SingleNode.status/1`. Synchronous."
  @spec check_now(GenServer.server()) :: Samen.SingleNode.status()
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now, 15_000)

  @doc false
  # Runs inside the connection process on EVERY new session (see the moduledoc). `cfg` is built by `init/1`.
  def after_connect(conn, cfg) do
    q = cfg.query_mod
    ref = cfg.ref

    %{rows: [[version, now_us]]} =
      q.query!(
        conn,
        "SELECT current_setting('server_version_num')::int, (extract(epoch from clock_timestamp()) * 1000000)::bigint",
        []
      )

    # Once per lease process: a reconnect keeps the epoch, so it never makes the long-running instance "late".
    epoch =
      case :atomics.get(ref, @a_epoch) do
        0 ->
          e = max(now_us - @origin_us, 1)
          :atomics.put(ref, @a_epoch, e)
          e

        e ->
          e
      end

    {k1, k2} = cfg.key
    c = classes(cfg.key)
    idle? = version >= 140_000

    idle_sql = if idle?, do: ", set_config('idle_session_timeout', $9, false)", else: ""

    %{rows: [[pid | _]]} =
      q.query!(
        conn,
        "SELECT pg_backend_pid(), pg_advisory_lock_shared($1::int, $2::int), pg_advisory_lock_shared($3::int, $4::int), " <>
          "pg_advisory_lock_shared($5::int, $6::int), pg_advisory_lock_shared($7::int, 0), set_config('#{@guc}', $8, false), " <>
          "set_config('tcp_keepalives_idle', '10', false), set_config('tcp_keepalives_interval', '5', false), " <>
          "set_config('tcp_keepalives_count', '3', false)" <> idle_sql,
        [k1, k2, c.secs, div(epoch, 1_000_000), c.usec, rem(epoch, 1_000_000), c.beat, cfg.token] ++
          if(idle?, do: [Integer.to_string(cfg.idle_ms)], else: [])
      )

    unless idle? do
      Logger.warning(
        "[Samen.SingleNode] Postgres #{version} has no idle_session_timeout (14+): a crashed host's lease lock lives until " <>
          "TCP keepalive drops its session; a holder whose beat stops is reported UNKNOWN (:stale_holder) meanwhile"
      )
    end

    :atomics.put(ref, @a_pid, pid)

    :telemetry.execute(
      [:samen, :single_node, :session],
      %{backend_pid: pid, idle_session_timeout_ms: if(idle?, do: cfg.idle_ms, else: 0)},
      %{}
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Pure interpretation of the check statement
  # ---------------------------------------------------------------------------

  @doc """
  Interpret the check statement's result against what this lease KNOWS about its own session
  (`ctx = %{token, pid, epoch}`): `{:view, others} | {:unknown, reason}`. Rows are
  `[my_pid, session_variable | nil, holder_pid | nil, secs | nil, usec | nil, beats | nil]` (the last three
  are `nil` or lists, one entry per lock the holder has in that class).
  """
  @spec interpret(term(), map()) :: {:view, [map()]} | {:unknown, atom()}
  def interpret({:ok, %Postgrex.Result{rows: [[me, var | _] | _] = rows}}, ctx) do
    cond do
      var in [nil, ""] or var != ctx.token or me != ctx.pid ->
        {:unknown, :connection_pooler}

      true ->
        holders =
          rows
          |> Enum.reject(fn [_, _, pid | _] -> is_nil(pid) end)
          |> Enum.uniq_by(fn [_, _, pid | _] -> pid end)
          |> Enum.map(&holder/1)

        case Enum.split_with(holders, &(&1.pid == me)) do
          {[], _} ->
            {:unknown, :lease_lost}

          {[mine | _], others} ->
            # A holder carrying MY boot epoch is a ghost of my own earlier session (a connection the server has
            # not dropped yet, or a pooled server connection still holding my locks): epochs are microseconds of
            # the database clock, unique per lease process, so it can never be a second instance.
            others = Enum.reject(others, &(&1.epoch == ctx.epoch))
            if shared_session?(mine, ctx), do: {:unknown, :connection_pooler}, else: {:view, others}
        end
    end
  end

  def interpret({:error, %DBConnection.ConnectionError{}}, _ctx), do: {:unknown, :connection_down}

  # The server ended the session (a restart, pg_terminate_backend, idle_session_timeout) and the answer to the next
  # query on it is the FATAL error itself: the connection is down, not the query wrong.
  def interpret({:error, %Postgrex.Error{postgres: %{code: code}}}, _ctx)
      when code in [:admin_shutdown, :idle_session_timeout, :crash_shutdown, :cannot_connect_now],
      do: {:unknown, :connection_down}

  def interpret(_other, _ctx), do: {:unknown, :query_failed}

  defp holder([_, _, pid, secs, usec, beats]) do
    secs = secs || []
    usec = usec || []
    beats = Enum.sort(beats || [])

    epoch =
      case {secs, usec} do
        {[s], [u]} -> s * 1_000_000 + u
        _ -> nil
      end

    %{pid: pid, epoch: epoch, beats: beats, identities: max(length(secs), 1)}
  end

  # My own session must carry exactly my epoch and one beat; anything else means another lease also ran its
  # statements on this server connection (a pooler), so "no other holder" would be a lie.
  defp shared_session?(mine, ctx), do: mine.epoch != ctx.epoch or length(mine.beats) != 1

  @doc """
  Turn the other holders into a verdict, remembering what each one's beat looked like and since when
  (`seen`: `pid => {signature, changed_at_ms, changed?}`). A holder whose signature did not change for `stale_ms`
  is NOT evidence of a second instance. One whose signature has changed at least once is CONFIRMED alive
  (`verified?`): a ghost lock, seen for the first time, is not. Returns `{verdict, seen}`, verdict
  `:single | {:overlap, peers, late?, verified?} | {:unknown, :stale_holder}`.
  """
  @spec decide([map()], map(), integer(), non_neg_integer(), {integer(), integer()}) :: {term(), map()}
  def decide(others, seen, now, stale_ms, {my_epoch, my_pid}) do
    seen2 =
      Map.new(others, fn o ->
        sig = {o.beats, o.epoch}

        case Map.get(seen, o.pid) do
          {^sig, at, changed?} -> {o.pid, {sig, at, changed?}}
          nil -> {o.pid, {sig, now, false}}
          _changed -> {o.pid, {sig, now, true}}
        end
      end)

    {live, _stale} = Enum.split_with(others, fn o -> now - elem(Map.fetch!(seen2, o.pid), 1) < stale_ms end)

    verdict =
      cond do
        others == [] ->
          :single

        live == [] ->
          {:unknown, :stale_holder}

        true ->
          verified? = Enum.any?(live, fn o -> elem(Map.fetch!(seen2, o.pid), 2) end)
          {:overlap, live |> Enum.map(& &1.identities) |> Enum.sum(), late?(live, my_epoch, my_pid), verified?}
      end

    {verdict, seen2}
  end

  # Ordered by (boot epoch, pid): late = some LIVE peer is strictly older. A peer whose epoch is not readable
  # cannot be ordered, so it never makes us "late" (we do not refuse on a guess).
  defp late?(live, my_epoch, my_pid) do
    Enum.any?(live, fn o -> is_integer(o.epoch) and {o.epoch, o.pid} < {my_epoch, my_pid} end)
  end

  defp check_sql(k1, k2) do
    c = classes({k1, k2})

    agg = fn class, as ->
      "(SELECT array_agg(e.objid::bigint ORDER BY e.objid) FROM pg_locks e WHERE e.pid = l.pid AND e.locktype = 'advisory' " <>
        "AND e.classid = #{class} AND e.objsubid = 2 AND e.granted AND e.database = l.database) AS #{as}"
    end

    """
    SELECT pg_backend_pid(), current_setting('#{@guc}', true), l.pid, #{agg.(c.secs, "secs")}, #{agg.(c.usec, "usec")}, #{agg.(c.beat, "beats")}
    FROM (SELECT 1) AS one
    LEFT JOIN pg_locks l ON l.locktype = 'advisory' AND l.classid = #{k1} AND l.objid = #{k2}
         AND l.objsubid = 2 AND l.granted
         AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    """
  end

  # Replaces the beat. The guard runs IN the statement, on the session that serves it: a pooled statement that is not
  # this lease's own session takes nothing, so a pooled lease cannot leak a lock per check.
  defp beat_sql(k1, k2) do
    %{beat: b} = classes({k1, k2})

    "SELECT CASE WHEN current_setting('#{@guc}', true) = $1 AND pg_backend_pid() = $2 " <>
      "THEN pg_advisory_lock_shared(#{b}, $3::int)::text || pg_advisory_unlock_shared(#{b}, $4::int)::text END"
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Samen.SingleNode.config()
    table = Keyword.get(opts, :table, @table)
    key = Keyword.get(opts, :lock_key, @key)
    interval_ms = Keyword.get(opts, :interval_ms, config.interval_ms)
    q = Keyword.get(opts, :query_mod, Postgrex)

    # The table is created before the connection so `status/1` is never `:disarmed` while a lease exists.
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    ref = :atomics.new(3, signed: true)
    token = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    cfg = %{
      key: key,
      token: token,
      ref: ref,
      idle_ms: Keyword.get(opts, :session_idle_ms, 3 * interval_ms),
      query_mod: q
    }

    {:ok, conn} =
      q.start_link(connect_opts(opts, config) ++ [pool_size: 1, after_connect: {__MODULE__, :after_connect, [cfg]}] ++ Keyword.get(opts, :pool_opts, []))

    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    {k1, k2} = key

    state = %{
      table: table,
      conn: conn,
      q: q,
      ref: ref,
      token: token,
      sql: check_sql(k1, k2),
      beat_sql: beat_sql(k1, k2),
      strict: Keyword.get(opts, :strict, config.strict),
      grace_ms: Keyword.get(opts, :grace_ms, config.grace_ms),
      interval_ms: interval_ms,
      stale_ms: Keyword.get(opts, :stale_ms, 3 * interval_ms),
      query_timeout_ms: Keyword.get(opts, :query_timeout_ms, 5_000),
      clock: clock,
      kind: :unknown,
      since: nil,
      reported?: false,
      pooled?: false,
      last_reason: nil,
      seen: %{}
    }

    publish(state, clock.(), %{state: :unknown, reason: :starting, strict: state.strict})
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

          if lease_url not in [nil, ""],
            do: Keyword.merge(repo_config, Ecto.Repo.Supervisor.parse_url(lease_url)),
            else: repo_config
      end

    base
    |> Keyword.drop(@repo_only)
    |> Keyword.update(:socket_options, [keepalive: true], &(Enum.reject(&1, fn o -> match?({:keepalive, _}, o) end) ++ [keepalive: true]))
  end

  defp check(state) do
    now = state.clock.()
    # The recorded pid BEFORE the statement: if it is the same after, no reconnect happened while it ran.
    pid_before = :atomics.get(state.ref, @a_pid)
    result = state.q.query(state.conn, state.sql, [], timeout: state.query_timeout_ms)
    # Read AFTER the statement: a reconnect while it waited for the pool updates the recorded pid.
    ctx = %{token: state.token, pid: :atomics.get(state.ref, @a_pid), pid_before: pid_before, epoch: :atomics.get(state.ref, @a_epoch)}
    state = if not state.pooled? and pooler_proof?(result, ctx), do: latch_pooler(state), else: state

    if state.pooled? do
      # Latched for the life of this lease process: even a check that happens to land on its own server connection
      # proves nothing about the lock held elsewhere, and a pooled lease never beats.
      apply_verdict({:unknown, :connection_pooler}, now, state)
    else
      case interpret(result, ctx) do
        {:view, others} ->
          {verdict, seen} = decide(others, state.seen, now, state.stale_ms, {ctx.epoch, ctx.pid})
          beat(state, ctx, own_beat(result))
          apply_verdict(verdict, now, %{state | seen: seen})

        {:unknown, _reason} = verdict ->
          apply_verdict(verdict, now, state)
      end
    end
  end

  @doc """
  Does this check result PROVE that the lease's statements are multiplexed over several server connections (a
  transaction pooler)? Two things a direct connection never shows:

    * the session variable is absent or holds another boot's token. `after_connect` sets it before the pool serves
      the session and nobody else runs statements on it, so a genuine reconnect (which re-runs `after_connect`) never
      produces this;
    * the backend pid differs from the recorded one although no reconnect happened while the statement ran
      (`ctx.pid_before == ctx.pid`). A pid that changed DURING the statement is the benign race of a genuine
      reconnect (the statement ran on the old session, `after_connect` has since re-recorded), not evidence.

  A session that merely carries two epochs or two beats is NOT proof (`interpret/2` reads it as UNKNOWN for that one
  check, without latching). That does not heal by itself: a `pg_cancel_backend` landing between a beat's lock and its
  unlock leaves two beats on the session, `own_beat/1` then returns nil, no beat runs, and the check reads
  `connection_pooler` until the session is replaced by a reconnect.
  """
  @spec pooler_proof?(term(), map()) :: boolean()
  def pooler_proof?({:ok, %Postgrex.Result{rows: [[me, var | _] | _]}}, ctx) do
    var in [nil, ""] or var != ctx.token or (me != ctx.pid and Map.get(ctx, :pid_before, ctx.pid) == ctx.pid)
  end

  def pooler_proof?(_result, _ctx), do: false

  defp latch_pooler(state) do
    Logger.error(
      "[Samen.SingleNode] the lease connection is NOT a dedicated database session: its statements ran on different server " <>
        "connections (a transaction pooler, e.g. a PgBouncer / Neon -pooler URL). The single-node guard is UNKNOWN from now on " <>
        "and stays so until this process restarts, and an instance sharing the database may read single. Set DATABASE_DIRECT_URL " <>
        "(config :samen_core, Samen.SingleNode, lease_url) to a DIRECT, unpooled URL (#{Samen.SingleNode.adr()})"
    )

    %{state | pooled?: true}
  end

  # My own beat, read from the check row itself (not from a counter): a reconnect that resets the session cannot leave
  # a counter and the session disagreeing.
  defp own_beat({:ok, %Postgrex.Result{rows: [[me | _] | _] = rows}}) do
    case Enum.find(rows, fn [_, _, pid | _] -> pid == me end) do
      [_, _, _, _, _, [n]] when is_integer(n) -> n
      _ -> nil
    end
  end

  defp beat(_state, _ctx, nil), do: :ok

  defp beat(state, ctx, n) do
    state.q.query(state.conn, state.beat_sql, [state.token, ctx.pid, n + 1, n], timeout: state.query_timeout_ms)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Transitions: publish, report, emit
  # ---------------------------------------------------------------------------

  defp apply_verdict(:single, now, state) do
    if state.since != nil, do: Logger.notice("[Samen.SingleNode] overlap cleared: this instance is alone on the database again")
    emit(0, 0, 0)
    publish(state, now, %{state: :single, strict: state.strict})
    %{state | kind: :single, since: nil, reported?: false}
  end

  defp apply_verdict({:overlap, peers, late?, verified?}, now, state) do
    # The clock starts only on a CONFIRMED-alive overlap (a ghost that never beats must not use up the grace period
    # of a later, legitimate rolling deploy). It is kept across an unknown or unconfirmed reading and reset only by an
    # observed :single.
    since = state.since || if(verified?, do: now)

    if state.since == nil and state.kind != :overlap do
      Logger.warning(
        "[Samen.SingleNode] another instance shares this database peers=#{peers}; fine during a rolling deploy, " <>
          "reported as CRITICAL after #{div(state.grace_ms, 1000)}s once it is confirmed alive (#{Samen.SingleNode.adr()})"
      )
    end

    exceeded? = since != nil and now - since >= state.grace_ms
    reported? = state.reported? or (verified? and exceeded? and report_overlap(peers, state))

    emit(peers, 0, if(since, do: div(now - since, 1000), else: 0))

    publish(state, now, %{
      state: :overlap,
      peers: peers,
      # An unconfirmed overlap with no clock yet reads as "just now" (exceeded only when grace is 0).
      since: since || now,
      late?: late?,
      verified?: verified?,
      grace_ms: state.grace_ms,
      strict: state.strict
    })

    %{state | kind: :overlap, since: since, reported?: reported?}
  end

  defp apply_verdict({:unknown, reason}, now, state) do
    if state.kind != :unknown or state.last_reason != reason do
      Failure.report(:single_node_state, nil, reason)
      :telemetry.execute([:samen, :single_node, :unknown], %{count: 1}, %{})
    end

    emit(0, 1, 0)
    publish(state, now, %{state: :unknown, reason: reason, strict: state.strict})
    %{state | kind: :unknown, last_reason: reason}
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

  # `at` is the time of publishing (read now), not the start of the check: a slow database must not make a fresh state read stale.
  defp publish(state, _checked_at, raw), do: :ets.insert(state.table, {:status, Map.merge(raw, %{at: state.clock.(), stale_ms: state.stale_ms})})
end
