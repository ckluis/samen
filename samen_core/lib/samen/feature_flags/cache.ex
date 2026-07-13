defmodule Samen.FeatureFlags.Cache do
  @moduledoc """
  ETS-backed evaluation cache for the feature-flag engine (ADR-020 §2 decision 4,
  design G6 §3.3). Holds flag CONFIG (`enabled`, `rollout_pct`, `target_rules`,
  `variants`, …) keyed by `flag_name` so `evaluate/2` does NO per-render DB read
  (AC-G6-6). Web-dep free: `:ets` + a `GenServer` owner, no Phoenix.

  ## Read path (no per-render DB read)

  `get/2` reads the ETS table DIRECTLY from the calling process (`:read_concurrency`,
  no GenServer round-trip on a hit) — a hot flag render never touches the DB or the
  owner process. A miss loads the config ONCE (through the configured flag module +
  repo), populates ETS, and returns it; subsequent reads hit ETS.

  ## Invalidation (write-through + TTL — the staleness bound)

  Two mechanisms keep the cache bounded-stale (design §3.3):

    1. **Write-through** — a flag WRITE broadcasts an id-only invalidation; the host
       calls `invalidate/1` (or `invalidate_all/0`), which DELETES the entry so the
       next `get/2` reloads. This is how a kill-switch flip (`enabled → false`)
       propagates: one broadcast hop, then the reload returns the disabled config
       and `evaluate/2` short-circuits OFF. RP-F4 sabotages this: if `invalidate/1`
       is a no-op the disabled flip is not observed and the fail-safe test FAILS.
    2. **TTL** — an entry older than `ttl_ms` (default 60s) is treated as a miss and
       reloaded on read, bounding staleness even absent an explicit invalidation.

  ## Fail-safe (RP-F4)

  If the ETS table is missing (owner never started / crashed) or the DB load errors,
  `get/2` returns `{:error, _}` — NEVER a stale-ON guess. `Samen.FeatureFlags` maps
  that to a fail-SAFE OFF `Decision`. The cache can only ever leave a flag
  OFF-confirmed on error, never wrongly ON.
  """
  use GenServer

  require Logger

  @table :samen_feature_flags_cache
  @default_ttl_ms 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the cache owner (supervised, or lazily via `get/2`)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetch a flag's config map by name. Returns:

    * `{:ok, config}` — a config map (or `nil` for an unknown flag).
    * `{:error, reason}` — the cache is unavailable OR the load failed (fail-SAFE:
      the engine turns this into OFF).

  On a hit within TTL, reads ETS directly (no DB, no GenServer). On a miss or a
  stale entry, loads once through the configured flag module + repo.
  """
  @spec get(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def get(flag_name, opts \\ []) when is_binary(flag_name) do
    ttl = ttl_ms(opts)

    case lookup(flag_name) do
      {:hit, config, loaded_at} ->
        if fresh?(loaded_at, ttl) do
          {:ok, config}
        else
          load_and_cache(flag_name, opts)
        end

      :miss ->
        load_and_cache(flag_name, opts)

      :no_table ->
        # Owner not started — lazily start it, then load. If it still can't start,
        # this is a fail-SAFE {:error, _}.
        case ensure_started() do
          :ok -> load_and_cache(flag_name, opts)
          {:error, _} = err -> err
        end
    end
  rescue
    e ->
      Logger.warning("[FeatureFlags.Cache] get/2 error, fail-safe: #{Exception.message(e)}")
      {:error, :cache_error}
  end

  @doc """
  Invalidate a single flag (delete its entry so the next `get/2` reloads). Called
  on a flag WRITE via the id-only invalidation broadcast (design §3.3). Idempotent;
  safe when the owner is down.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(flag_name) when is_binary(flag_name) do
    if table_exists?(), do: :ets.delete(@table, flag_name)
    :ok
  end

  @doc "Invalidate the whole cache (operator-plane full flush / test reset)."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    if table_exists?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Directly seed a flag's config (used by hosts that push config through the
  invalidation broadcast, and by tests). Overwrites any cached entry.
  """
  @spec put(String.t(), map() | nil) :: :ok
  def put(flag_name, config) when is_binary(flag_name) do
    with :ok <- ensure_started() do
      :ets.insert(@table, {flag_name, config, now_ms()})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # The owner holds the ETS table so it dies with the owner (clean restart).
    # public + read_concurrency: readers hit ETS directly, no GenServer bottleneck.
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # ---------------------------------------------------------------------------
  # Read internals
  # ---------------------------------------------------------------------------

  defp lookup(flag_name) do
    case :ets.lookup(@table, flag_name) do
      [{^flag_name, config, loaded_at}] -> {:hit, config, loaded_at}
      [] -> :miss
    end
  rescue
    ArgumentError -> :no_table
  end

  defp load_and_cache(flag_name, opts) do
    case load_config(flag_name, opts) do
      {:ok, config} ->
        # Populate ETS (best-effort — a failure here still returns the fresh load).
        case ensure_started() do
          :ok -> :ets.insert(@table, {flag_name, config, now_ms()})
          _ -> :ok
        end

        {:ok, config}

      {:error, _} = err ->
        # RP-F4: a load error is fail-SAFE — do NOT cache, do NOT guess ON.
        err
    end
  end

  # Load a flag's config from the configured flag module via the repo. The flag
  # module + repo are DI seams (opts win over config). Returns a plain config map
  # (or nil for an unknown flag) so the engine never depends on the Ash struct.
  defp load_config(flag_name, opts) do
    flag_module = opt(opts, :flag_module)
    loader = opt(opts, :loader)

    cond do
      is_function(loader, 1) ->
        # A test / host-supplied loader: name -> {:ok, config | nil} | {:error, _}.
        loader.(flag_name)

      is_nil(flag_module) ->
        {:error, :no_flag_module}

      true ->
        load_via_ash(flag_module, flag_name)
    end
  rescue
    e -> {:error, {:load_raised, Exception.message(e)}}
  end

  defp load_via_ash(flag_module, flag_name) do
    require Ash.Query

    result =
      flag_module
      |> Ash.Query.filter(name == ^flag_name)
      |> Ash.Query.limit(1)
      |> Ash.read(authorize?: false)

    case result do
      {:ok, [flag | _]} -> {:ok, to_config(flag)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_config(flag) do
    %{
      name: flag.name,
      enabled: flag.enabled,
      rollout_pct: flag.rollout_pct,
      stage: flag.stage,
      target_rules: Map.get(flag, :target_rules) || [],
      variants: Map.get(flag, :variants) || %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Lifecycle / helpers
  # ---------------------------------------------------------------------------

  defp ensure_started do
    cond do
      table_exists?() ->
        :ok

      is_pid(Process.whereis(__MODULE__)) ->
        # Owner is up but table not yet created — race on init; treat as available.
        :ok

      true ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp table_exists?, do: :ets.whereis(@table) != :undefined

  defp fresh?(loaded_at, ttl), do: now_ms() - loaded_at < ttl

  defp ttl_ms(opts), do: opt(opts, :ttl_ms) || @default_ttl_ms

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp opt(opts, key) do
    Keyword.get(opts, key) || Keyword.get(config(), key)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end
