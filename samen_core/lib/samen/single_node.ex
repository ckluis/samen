defmodule Samen.SingleNode do
  @moduledoc """
  ONE application instance per database (ADR-054; evaluation 2026-11-13 ARCH-3, decision issue #121 D2).

  Several mechanisms keep their truth in a single node's memory or disk (the ETS rate limiter, the fleet
  replay-nonce cache, the AI kill switch in `:persistent_term`, node-local flag-cache invalidation and chat
  presence, FileBacked keys, the break-glass local audit; the full table is in the ADR). Two instances
  therefore do not scale a Samen product, they weaken it — a replayed nonce is accepted by the second node, a
  kill switch thrown on one node leaves the other running agents. This module is the guard that makes the
  assumption enforced rather than assumed. It has two halves, for two different ways of getting it wrong.

  ## 1. Distributed Erlang — `Samen.SingleNode.Peers`

  A serving instance refuses to be part of a cluster:

    * at boot `assert_standalone!/1` raises when a node is already connected (`Node.list/0`) or a clustering
      library is configured (`libcluster` topologies, `dns_cluster`'s query);
    * at runtime `Peers` subscribes to `:net_kernel` node events and, on a VISIBLE peer, reports loudly
      (log + `Samen.Observability.Failure` + telemetry) and disconnects it. HIDDEN nodes are accepted: `bin/app
      remote`, `bin/app rpc` and `iex --hidden --remsh` are hidden by construction (Mix releases start them with
      `--hidden`), so the operator console keeps working.

  ## 2. Two instances, one database — `Samen.SingleNode.Lease`

  Behind a load balancer two instances are NOT Erlang-clustered, so half 1 never fires. The only thing they
  share is Postgres, so Postgres is the detector: each serving instance holds a session-level SHARED advisory
  lock on a dedicated long-lived connection and counts the other holders in `pg_locks`. See `Lease` for why
  this survives connection drops, pool recycling and a pooler.

  A rolling deploy overlaps two instances on purpose. So the second instance boots, and:

    * within `grace_ms` (default 300 000 = 5 min) nothing pages — `/readyz` is clean;
    * past it `/readyz` carries `single_node: CRITICAL …`, one value-free failure report is filed and the
      `samen.single_node.overlap.count` series counts it;
    * with `strict: true` the LATE instance (the one whose lease session started later) answers 503 instead,
      so a deploy strategy that does not stop the old instance in time stops being ready by itself.

  If the state cannot be read (database down, lock query fails, a pooler in the way) the answer is
  `{:unknown, reason}` — never "single".

  ## What "serving" means (the guard only arms for it)

  `serving?/2` is Phoenix's own definition: the endpoint will bind a listener — its `server:` key (dev config and
  the generated `runtime.exs` set `true`; `Samen.SeedBoot` forces `false`), else `config :phoenix, :serve_endpoints,
  true` (what `mix phx.server` sets). `mix test` (`server: false`), `mix ecto.*`, `mix samen.*` tasks that only load the app,
  IEx without a server, and the release `eval`/`migrate` commands (which load the app and start only the
  repo, never the supervision tree) therefore never start the guard, never take the lease and never trip a
  running instance.

  Configuration (`config :samen_core, Samen.SingleNode, …`): `strict` (false), `grace_ms` (300 000),
  `interval_ms` (5 000), `lease_url` (nil: use the repo's own connection settings; set a DIRECT, unpooled URL
  when the app connects through PgBouncer in transaction mode).
  """

  alias Samen.SingleNode.{Lease, Peers}

  @adr "ADR-054"

  defmodule ClusteredError do
    defexception [:message]
  end

  @type status ::
          :disarmed
          | %{state: :single, strict?: boolean()}
          | %{
              state: :overlap,
              peers: pos_integer(),
              since_ms: non_neg_integer(),
              exceeded?: boolean(),
              late?: boolean(),
              grace_ms: non_neg_integer(),
              strict?: boolean()
            }
          | %{state: :unknown, reason: atom(), strict?: boolean()}

  @doc "The ADR that governs this module."
  @spec adr() :: String.t()
  def adr, do: @adr

  @doc "Resolved configuration with defaults."
  @spec config() :: %{strict: boolean(), grace_ms: non_neg_integer(), interval_ms: pos_integer(), lease_url: String.t() | nil}
  def config do
    env = Application.get_env(:samen_core, __MODULE__, [])

    %{
      strict: Keyword.get(env, :strict, false),
      grace_ms: Keyword.get(env, :grace_ms, 300_000),
      interval_ms: Keyword.get(env, :interval_ms, 5_000),
      lease_url: Keyword.get(env, :lease_url)
    }
  end

  # ---------------------------------------------------------------------------
  # Arming
  # ---------------------------------------------------------------------------

  @doc """
  Is this instance SERVING (will its endpoint bind a listener)? Phoenix's rule, per endpoint config of `otp_app`:
  its `server:` key, else `config :phoenix, :serve_endpoints` (set by `mix phx.server`).
  `opts[:serving?]` overrides it (tests, a host that knows better).
  """
  @spec serving?(atom(), keyword()) :: boolean()
  def serving?(otp_app, opts \\ []) when is_atom(otp_app) do
    case Keyword.fetch(opts, :serving?) do
      {:ok, bool} when is_boolean(bool) ->
        bool

      :error ->
        serve_endpoints = Application.get_env(:phoenix, :serve_endpoints, false) == true

        # Phoenix's own rule per endpoint: its `:server` key when present, else `:serve_endpoints`. An app with no
        # endpoint config at all is serving only when `mix phx.server` said so.
        case endpoint_confs(otp_app) do
          [] -> serve_endpoints
          confs -> Enum.any?(confs, &(Keyword.get(&1, :server, serve_endpoints) == true))
        end
    end
  end

  defp endpoint_confs(otp_app) do
    for {module, conf} <- Application.get_all_env(otp_app),
        is_atom(module),
        Keyword.keyword?(conf),
        Keyword.has_key?(conf, :server) or Keyword.has_key?(conf, :pubsub_server) or Keyword.has_key?(conf, :http),
        do: conf
  end

  @doc """
  The children of a SERVING instance: the peer monitor and (when `otp_app` has a repo) the database lease.
  `[]` for anything that is not serving. Raises `Samen.SingleNode.ClusteredError` at boot when the instance
  is clustered. Called by `Samen.Observability.child_specs/2`, so every host gets it with no host code.
  """
  @spec child_specs(atom(), keyword()) :: [{module(), term()}]
  def child_specs(otp_app, opts \\ []) when is_atom(otp_app) do
    if serving?(otp_app, opts) do
      assert_standalone!(otp_app)

      repo = Keyword.get_lazy(opts, :repo, fn -> otp_app |> Application.get_env(:ecto_repos, []) |> List.first() end)

      [{Peers, []}] ++ if(repo, do: [{Lease, [repo: repo]}], else: [])
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Half 1 — distributed Erlang
  # ---------------------------------------------------------------------------

  @doc """
  What makes this node part of (or about to become part of) a cluster: visible connected nodes and configured
  clustering libraries. `[]` is standalone. Hidden nodes (operator consoles) are not findings.
  """
  @spec cluster_findings(atom()) :: [String.t()]
  def cluster_findings(otp_app) do
    topologies = Application.get_env(:libcluster, :topologies)
    dns_query = Application.get_env(:dns_cluster, :query)
    host_dns_query = Application.get_env(otp_app, :dns_cluster_query)

    [
      {Node.list() != [], "visible nodes are connected (#{length(Node.list())})"},
      {topologies not in [nil, []], "libcluster topologies are configured"},
      {dns_query not in [nil, :ignore], "dns_cluster :query is configured"},
      {host_dns_query not in [nil, :ignore], "#{otp_app} :dns_cluster_query is configured"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Boot guard: raises `ClusteredError` naming the ADR when `cluster_findings/1` is not empty. Returns `:ok`."
  @spec assert_standalone!(atom()) :: :ok
  def assert_standalone!(otp_app) do
    case cluster_findings(otp_app) do
      [] ->
        :ok

      findings ->
        raise ClusteredError,
              "Samen runs as ONE application instance per database (#{@adr}); refusing to boot clustered: " <>
                Enum.join(findings, "; ") <>
                ". Remove the clustering configuration (the node-local state is not cluster-safe)."
    end
  end

  # ---------------------------------------------------------------------------
  # Half 2 — status of the database lease
  # ---------------------------------------------------------------------------

  @doc """
  The single-node status of THIS instance, read from the lease's ETS table without a database round trip.
  `:disarmed` only when no lease runs here (not serving / no repo); a lease that has not yet read the database
  is `%{state: :unknown, reason: :starting}`, never `:single`. `opts[:now]` is a monotonic millisecond
  clock for tests.
  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    table = Keyword.get(opts, :table, Lease.default_table())

    case :ets.whereis(table) do
      :undefined ->
        :disarmed

      _ref ->
        case :ets.lookup(table, :status) do
          [{:status, raw}] -> resolve(raw, Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end))
          [] -> %{state: :unknown, reason: :starting, strict?: config().strict}
        end
    end
  end

  @doc false
  @spec resolve(map(), integer()) :: status()
  def resolve(%{state: :single, strict: strict}, _now), do: %{state: :single, strict?: strict}
  def resolve(%{state: :unknown, reason: reason, strict: strict}, _now), do: %{state: :unknown, reason: reason, strict?: strict}

  def resolve(%{state: :overlap} = raw, now) do
    since_ms = max(now - raw.since, 0)

    %{
      state: :overlap,
      peers: raw.peers,
      since_ms: since_ms,
      exceeded?: since_ms >= raw.grace_ms,
      late?: raw.late?,
      grace_ms: raw.grace_ms,
      strict?: raw.strict
    }
  end

  @doc """
  The `/readyz` advisory for `status/1`: `:ok | {:critical, detail} | {:unknown, detail}`. Value-free.
  Overlap inside the grace period is `:ok` (a rolling deploy); past it, `:critical`.
  """
  @spec advisory(keyword()) :: :ok | {:critical, String.t()} | {:unknown, String.t()}
  def advisory(opts \\ []) do
    case status(opts) do
      :disarmed -> :ok
      %{state: :single} -> :ok
      %{state: :unknown, reason: reason} -> {:unknown, "single-node state unreadable (#{reason}); see #{@adr}"}
      %{state: :overlap, exceeded?: false} -> :ok
      %{state: :overlap} = s ->
        {:critical,
         "#{s.peers} other instance(s) share this database for #{div(s.since_ms, 1000)}s (grace #{div(s.grace_ms, 1000)}s); " <>
           "Samen runs as one instance per database, see #{@adr}"}
    end
  end

  @doc """
  The strict-mode readiness component: `:not_armed` (nothing to add to `/readyz`), `:ok`, or
  `{:error, :overlap}` — only the LATE instance, only past the grace period, only when `strict` is on. An
  unreadable state is `:ok` here (the repo check already fails a dead database; `advisory/1` says UNKNOWN).
  """
  @spec strict_check(keyword()) :: :not_armed | :ok | {:error, :overlap}
  def strict_check(opts \\ []) do
    case status(opts) do
      :disarmed -> :not_armed
      %{strict?: false} -> :not_armed
      %{state: :overlap, exceeded?: true, late?: true} -> {:error, :overlap}
      _ -> :ok
    end
  end
end
