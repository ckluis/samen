defmodule Samen.AuditEvent.ErasureWindowPolicy do
  @moduledoc """
  Behaviour for the erasure-window gate in `Samen.AuditEvent.PartitionManager`.

  Implement this behaviour to control when a partition is safe to detach.

  The default implementation (`Samen.AuditEvent.DefaultErasureWindowPolicy`) keeps
  any partition whose time window ended less than `default_erasure_window_days` ago
  (default: 90, configurable via `:default_erasure_window_days`).

  T2.3 supplies the rollup linkage that replaces the default with a real check.

  ## Configuration

      config :samen_core, :erasure_window_policy, MyApp.CustomErasureWindowPolicy
  """

  @type partition_info :: %{
          partition_name: String.t(),
          from_ts: String.t(),
          to_ts: String.t()
        }

  @doc """
  Is the partition described by `info` still relevant to an active erasure-window
  rollup, such that detaching it now would destroy rebuild capability?

  Return:
    * `{:relevant, detail}` — MUST NOT detach; `detail` is the human explanation.
    * `:not_relevant` — safe to detach.
  """
  @callback still_relevant?(partition_info()) :: {:relevant, String.t()} | :not_relevant
end

defmodule Samen.AuditEvent.DefaultErasureWindowPolicy do
  @moduledoc """
  Default erasure-window gate: keep any partition whose window ended within the
  last `default_erasure_window_days` days (configurable, defaults to 90).

  T2.3 will add the real rollup-linkage override.  Until then this time-based
  floor is the conservative safe default: do not archive a partition that is still
  "fresh" enough that an erasure might want to rebuild a rollup from it.

  ## Configuration

      config :samen_core, :default_erasure_window_days, 90
  """

  @behaviour Samen.AuditEvent.ErasureWindowPolicy

  @default_window_days 90

  @impl true
  def still_relevant?(%{to_ts: to_ts}) do
    window_days =
      Application.get_env(:samen_core, :default_erasure_window_days, @default_window_days)

    cutoff = Date.add(Date.utc_today(), -window_days)

    case parse_bound_date(to_ts) do
      {:ok, partition_end} ->
        if Date.compare(partition_end, cutoff) == :gt do
          detail =
            "partition ends #{partition_end}, within the #{window_days}-day erasure window " <>
              "(cutoff #{cutoff}). Detach is refused until the window expires or T2.3 rollup " <>
              "linkage explicitly marks this partition as rebuild-complete."

          {:relevant, detail}
        else
          :not_relevant
        end

      {:error, _} ->
        # Cannot parse — fail closed: treat as still relevant.
        {:relevant,
         "could not parse partition bound '#{to_ts}' — refusing detach (fail closed)"}
    end
  end

  # Parse "YYYY-MM-DD HH:MM:SS+00" or "YYYY-MM-DD" shapes from the partition spec.
  defp parse_bound_date(ts) when is_binary(ts) do
    ts
    |> String.split(" ")
    |> List.first()
    |> Date.from_iso8601()
  end
end

defmodule Samen.AuditEvent.PartitionManager do
  @moduledoc """
  Oban cron worker that manages `aud_event` monthly RANGE partitions (T2.2 (c)).

  ## Responsibilities

  1. **Create next-month partitions ahead of time** — run daily (or on demand),
     ensures the partition for the *next* N calendar months exists before rows arrive.
     Creating ahead avoids a missing-partition error at insert time.

  2. **Detach-for-archival** — `detach_partition/3` is the *one* entry point for
     removing an old partition from the live table.  It refuses to detach a partition
     whose time window still feeds an erasure-relevant rollup (the
     *erasure-window gate*).

  ## Erasure-window gate (T2.2 (c) spec)

  The doc states: "a partition still feeding a rebuildable rollup is retained."
  An erasure event can land in an already-archived window (no raw rows to rebuild
  from), which is fine — the exclude/suppress arm handles that.  BUT: if an active
  erasure may STILL need to rebuild a rollup that reads the raw `aud_event` rows
  in a given partition, we must not detach that partition first.

  The gate is a **policy callback** (`Samen.AuditEvent.ErasureWindowPolicy`) with a
  default implementation and a config override seam:

      config :samen_core, :erasure_window_policy, MyApp.ErasureWindowPolicy

  The default policy keeps any partition whose time window ends less than
  `default_erasure_window_days` days ago.  T2.3 replaces the default with a
  real rollup-linkage check once rollups exist.

  ## Configuration

      config :samen_core, :aud_event_repo, MyApp.Repo
      # Optional: override the erasure-window policy module.
      config :samen_core, :erasure_window_policy, Samen.AuditEvent.DefaultErasureWindowPolicy

  ## Simulation seam (environment note)

  There is NO physical Neon/AWS replica in this environment.  Where a real deployment
  might replicate `aud_event` to a read replica, this implementation targets the
  primary repo only.  The T2.5 PITR game-day task is the operator TODO for wiring
  an actual replica.

  ## T2.1 conventions

  This worker runs in the `:maintenance` Oban queue (concurrency 1, per the queue
  taxonomy in `Samen.Jobs`).  Schedule it in your Oban cron config:

      {"0 1 * * *", Samen.AuditEvent.PartitionManager}

  (daily at 01:00; the idempotent ensure_partition is cheap)
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [period: 23 * 60 * 60]

  require Logger

  # ---------------------------------------------------------------------------
  # Oban.Worker callback
  # ---------------------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    repo = repo!()
    months_ahead = Map.get(args, "months_ahead", 2)

    now = Date.utc_today()
    results = ensure_upcoming_partitions(repo, now, months_ahead)

    Logger.info(
      "[PartitionManager] ensured #{length(results)} partition(s) " <>
        "(months_ahead=#{months_ahead})"
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Partition creation
  # ---------------------------------------------------------------------------

  @doc """
  Ensure the monthly `aud_event` partition for `date` exists.

  Idempotent — uses `CREATE TABLE IF NOT EXISTS ... PARTITION OF`.
  Returns `{:ok, partition_name}`.
  """
  @spec ensure_partition(module(), Date.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_partition(repo, %Date{} = date) do
    {name, from_ts, to_ts} = partition_spec(date)
    sql = create_partition_sql(name, from_ts, to_ts)

    case repo.query(sql) do
      {:ok, _} ->
        {:ok, name}

      {:error, %Postgrex.Error{postgres: %{code: :duplicate_table}}} ->
        # Already exists — idempotent.
        {:ok, name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ensure partitions exist for `date` through `date + months_ahead` months.
  Returns a list of `{:ok, name}` or `{:error, reason}` tuples.
  """
  @spec ensure_upcoming_partitions(module(), Date.t(), non_neg_integer()) ::
          [{:ok, String.t()} | {:error, term()}]
  def ensure_upcoming_partitions(repo, %Date{} = anchor, months_ahead)
      when is_integer(months_ahead) and months_ahead >= 0 do
    0..months_ahead
    |> Enum.map(fn offset ->
      date = Date.add(anchor, offset * 31) |> first_of_month()
      ensure_partition(repo, date)
    end)
  end

  # ---------------------------------------------------------------------------
  # Detach-for-archival (with erasure-window gate)
  # ---------------------------------------------------------------------------

  @doc """
  Detach the `aud_event` partition for `date` from the parent table.

  Refuses if the partition's time window still feeds an erasure-relevant rollup
  (the erasure-window gate; T2.2 (c)).

  Options:
    * `:policy` — override the `ErasureWindowPolicy` implementation (for tests).
    * `:force` — bypass the erasure-window gate (for operator-controlled overrides
      with an explicit sign-off; logs a warning).

  Returns:
    * `{:ok, partition_name}` — detached successfully.
    * `{:error, :erasure_window_active, detail}` — gate refused; the partition
      still feeds a rollup window.
    * `{:error, :not_found}` — partition does not exist.
    * `{:error, term}` — other DB error.
  """
  @spec detach_partition(module(), Date.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :erasure_window_active, String.t()}
          | {:error, :not_found}
          | {:error, term()}
  def detach_partition(repo, %Date{} = date, opts \\ []) do
    {name, from_ts, to_ts} = partition_spec(date)
    force = Keyword.get(opts, :force, false)
    policy = Keyword.get(opts, :policy, erasure_window_policy())

    with :ok <- gate_check(policy, name, from_ts, to_ts, force),
         :ok <- assert_partition_exists(repo, name),
         {:ok, _} <- do_detach(repo, name) do
      {:ok, name}
    end
  end

  # ---------------------------------------------------------------------------
  # Partition naming / SQL helpers
  # ---------------------------------------------------------------------------

  @doc "Compute the partition name and RANGE bounds for the month containing `date`."
  @spec partition_spec(Date.t()) :: {String.t(), String.t(), String.t()}
  def partition_spec(%Date{} = date) do
    first = first_of_month(date)
    last = last_of_month(date)
    name = partition_name(first)
    from_ts = "#{first} 00:00:00+00"
    # Partition RANGE is exclusive on the upper bound; next month's first day.
    to_ts = "#{Date.add(last, 1)} 00:00:00+00"
    {name, from_ts, to_ts}
  end

  @doc "Return the canonical partition table name for the month of `date`."
  @spec partition_name(Date.t()) :: String.t()
  def partition_name(%Date{year: y, month: m}),
    do: "aud_event_y#{y}m#{String.pad_leading(to_string(m), 2, "0")}"

  @doc """
  List all `aud_event` child partitions currently attached (by querying pg_inherits).
  Returns `[{table_name, bounds, bounds}]`.
  """
  @spec list_partitions(module()) :: [{String.t(), String.t(), String.t()}]
  def list_partitions(repo) do
    sql = """
    SELECT
      c.relname AS partition_name,
      pg_get_expr(c.relpartbound, c.oid) AS bounds
    FROM pg_inherits i
    JOIN pg_class p ON p.oid = i.inhparent
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE p.relname = 'aud_event'
    ORDER BY c.relname
    """

    case repo.query(sql) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, bounds] -> {name, bounds, bounds} end)

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp gate_check(_policy, _name, _from_ts, _to_ts, true = _force) do
    Logger.warning(
      "[PartitionManager] detach_partition called with :force=true — " <>
        "bypassing erasure-window gate (operator override)"
    )

    :ok
  end

  defp gate_check(policy, name, from_ts, to_ts, false) do
    case policy.still_relevant?(%{
           partition_name: name,
           from_ts: from_ts,
           to_ts: to_ts
         }) do
      {:relevant, detail} ->
        {:error, :erasure_window_active, detail}

      :not_relevant ->
        :ok
    end
  end

  defp assert_partition_exists(repo, name) do
    sql = """
    SELECT COUNT(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = 'public'
    """

    case repo.query(sql, [name]) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: [[0]]}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_detach(repo, name) do
    repo.query("ALTER TABLE aud_event DETACH PARTITION #{name}")
  end

  defp create_partition_sql(name, from_ts, to_ts) do
    """
    CREATE TABLE IF NOT EXISTS #{name}
    PARTITION OF aud_event
    FOR VALUES FROM ('#{from_ts}') TO ('#{to_ts}')
    """
  end

  defp first_of_month(%Date{year: y, month: m}), do: Date.new!(y, m, 1)

  defp last_of_month(%Date{year: y, month: m}) do
    days = Date.days_in_month(Date.new!(y, m, 1))
    Date.new!(y, m, days)
  end

  defp erasure_window_policy do
    Application.get_env(
      :samen_core,
      :erasure_window_policy,
      Samen.AuditEvent.DefaultErasureWindowPolicy
    )
  end

  defp repo! do
    Application.get_env(:samen_core, :aud_event_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      Application.get_env(:samen_core, :non_pii_repo) ||
      raise """
      Samen.AuditEvent.PartitionManager needs a repo.  Configure it:

          config :samen_core, :aud_event_repo, MyApp.Repo
      """
  end
end
