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

  3. **DEFAULT partition + runway** (ARCH-9; ADR-002 amendment) — `aud_event_default`
     catches any row whose `aud_occurred_at` falls outside every monthly partition
     (backdated or future-dated, or a missed roll-forward), so an audited write is never
     refused for want of a partition. It is a safety net, not a destination: a row there is
     reported LOUDLY (`report_default_landing/1`, `[:samen, :audit, :partition, :default_landing]`)
     and counted (`runway/2` → `default_rows`). Creating a monthly partition whose range
     already holds DEFAULT rows is refused by Postgres, so `ensure_partition/2` first moves
     those rows into the new partition, in one transaction (see there). `runway/2` reports,
     per partitioned table, how far ahead partitions exist; `Samen.Web.Readiness` and the
     daily job read it.

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

  (daily at 01:00; the idempotent ensure_partition is cheap). `Samen.Jobs.install_defaults/1`
  installs that entry, and also `Samen.Jobs.BootRun`, which enqueues this worker once when
  Oban starts, so a node never waits until 01:00 for the current month's partition. A fresh
  database has it from the start: the generated migration creates the month it runs in and
  the next two (`upcoming_partition_sql/2`).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [period: 23 * 60 * 60]

  require Logger

  @default_partition "aud_event_default"

  # Below this many days of partitions ahead, the runway is a WARNING (one month; the daily job keeps two
  # ahead, so a healthy table never gets near it). At zero or less it is CRITICAL. Override with
  # `config :samen_core, :partition_runway_warn_days, n`.
  @runway_warn_days 31

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

    # A roll-forward that failed is a failed job (Oban retries, then the discard is visible), never `:ok`: the
    # old `:ok` regardless turned a month that could not be created into a silent runway shrink.
    failed = for {:error, reason} <- results, do: reason

    case failed do
      [] ->
        observe_runway(repo)
        :ok

      [first | _] ->
        Samen.Observability.Failure.report(:write, :audit_partition_roll_forward, nil, first, [])
        observe_runway(repo)
        {:error, {:partition_roll_forward_failed, length(failed)}}
    end
  end

  @doc """
  Read `runway/2`, emit it as telemetry (`emit_runway/1`) and report anything not healthy. Returns the runway result.
  A runway that cannot be read is reported (`:audit_partition_runway`) and emitted as unknown — never as fine.
  """
  @spec observe_runway(module()) :: {:ok, [map()]} | {:error, term()}
  def observe_runway(repo) do
    result = runway(repo)
    emit_runway(result)

    case result do
      {:ok, rows} ->
        for %{status: status, reasons: reasons} <- rows, status != :ok do
          Samen.Observability.Failure.report(:write, :audit_partition_runway, nil, hd(reasons), [])
        end

      {:error, reason} ->
        Samen.Observability.Failure.report(:audit_partition_runway, nil, reason)
    end

    result
  end

  # ---------------------------------------------------------------------------
  # Partition creation
  # ---------------------------------------------------------------------------

  @doc """
  Ensure the monthly `aud_event` partition for `date` exists.

  Idempotent. Returns `{:ok, partition_name}`.

  Postgres refuses to attach a range that the DEFAULT partition already holds rows for ("updated partition
  constraint for default partition would be violated by some row"), and a row lands in DEFAULT exactly when its
  month had no partition yet (a backdated import, a missed roll-forward). So when `aud_event_default` holds
  rows in the new month's range they are MOVED, in the one transaction that creates the partition:

    1. detach the DEFAULT partition and set it aside under another name;
    2. create a fresh, empty DEFAULT and the monthly partition;
    3. re-insert every row of the old DEFAULT through the parent (each is routed to its month, or back to
       DEFAULT), refusing the whole transaction unless the counts match;
    4. drop the old table.

  Nothing is `DELETE`d (the append-only trigger would refuse it) and the rows keep their ids and timestamps.
  A row inserted between the range check and the `CREATE` makes Postgres refuse it; that is returned as an
  error and the job's retry finds the rows and takes the move path.
  """
  @spec ensure_partition(module(), Date.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_partition(repo, %Date{} = date) do
    {name, from_ts, to_ts} = partition_spec(date)

    with {:ok, {exists?, default?}} <- partition_state(repo, name) do
      cond do
        exists? ->
          {:ok, name}

        default? ->
          case default_rows_in_range?(repo, from_ts, to_ts) do
            {:ok, true} -> move_default_rows(repo, name, from_ts, to_ts)
            {:ok, false} -> create_partition(repo, name, from_ts, to_ts)
            {:error, reason} -> {:error, reason}
          end

        true ->
          create_partition(repo, name, from_ts, to_ts)
      end
    end
  end

  defp create_partition(repo, name, from_ts, to_ts) do
    case repo.query(create_partition_sql(name, from_ts, to_ts)) do
      {:ok, _} -> {:ok, name}
      # Already exists — idempotent (a concurrent creator won).
      {:error, %Postgrex.Error{postgres: %{code: :duplicate_table}}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  # {the monthly partition exists?, the DEFAULT partition exists?} — one catalog round trip.
  defp partition_state(repo, name) do
    case repo.query("SELECT to_regclass($1) IS NOT NULL, to_regclass($2) IS NOT NULL", [
           "public." <> name,
           "public." <> @default_partition
         ]) do
      {:ok, %{rows: [[exists?, default?]]}} -> {:ok, {exists?, default?}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_rows_in_range?(repo, from_ts, to_ts) do
    # `from_ts`/`to_ts` are `partition_spec/1`'s own date literals, never caller input.
    sql =
      "SELECT EXISTS (SELECT 1 FROM ONLY #{@default_partition} " <>
        "WHERE aud_occurred_at >= '#{from_ts}'::timestamptz AND aud_occurred_at < '#{to_ts}'::timestamptz)"

    case repo.query(sql) do
      {:ok, %{rows: [[found?]]}} -> {:ok, found?}
      {:error, reason} -> {:error, reason}
    end
  end

  @aside "aud_event_default_moving"
  @cols "aud_id, aud_event_type, aud_subject_id, aud_actor_id, aud_correlation_id, aud_detail, aud_occurred_at"

  defp move_default_rows(repo, name, from_ts, to_ts) do
    result =
      repo.transaction(fn ->
        count_before = scalar!(repo, "SELECT count(*) FROM ONLY #{@default_partition}")

        repo.query!("ALTER TABLE aud_event DETACH PARTITION #{@default_partition}")
        repo.query!("ALTER TABLE #{@default_partition} RENAME TO #{@aside}")
        repo.query!(default_partition_sql())
        repo.query!(create_partition_sql(name, from_ts, to_ts))
        repo.query!("INSERT INTO aud_event (#{@cols}) SELECT #{@cols} FROM #{@aside}")

        # Every row is somewhere under the parent again, or this transaction does not commit.
        moved = scalar!(repo, "SELECT count(*) FROM #{@aside} a WHERE EXISTS (SELECT 1 FROM aud_event e WHERE e.aud_id = a.aud_id AND e.aud_occurred_at = a.aud_occurred_at)")

        if moved != count_before do
          repo.rollback({:default_move_count_mismatch, count_before, moved})
        end

        repo.query!("DROP TABLE #{@aside}")
        name
      end)

    case result do
      {:ok, ^name} ->
        Logger.warning(
          "[PartitionManager] moved rows out of #{@default_partition} into #{name} " <>
            "(they had landed in DEFAULT before their month had a partition)"
        )

        {:ok, name}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Samen.Observability.Failure.report(:audit_partition_move, nil, e)
      {:error, e}
  end

  defp scalar!(repo, sql) do
    %{rows: [[n]]} = repo.query!(sql)
    n
  end

  @doc """
  Ensure partitions exist for the month of `anchor` and each of the next `months_ahead`
  calendar months (`months_ahead + 1` partitions).
  Returns a list of `{:ok, name}` or `{:error, reason}` tuples.

  Months are counted on the calendar, never as 31-day steps: from a 29th–31st, a 31-day
  step lands two months on and skips the month between (from Jan 31: Jan, Mar, Apr).
  """
  @spec ensure_upcoming_partitions(module(), Date.t(), non_neg_integer()) ::
          [{:ok, String.t()} | {:error, term()}]
  def ensure_upcoming_partitions(repo, %Date{} = anchor, months_ahead)
      when is_integer(months_ahead) and months_ahead >= 0 do
    first = first_of_month(anchor)
    ensure_partitions_between(repo, first, Date.shift(first, month: months_ahead))
  end

  @doc """
  Ensure a partition exists for every month from the month of `from` through the month of
  `to`, inclusive. Returns a list of `{:ok, name}` or `{:error, reason}` tuples (empty when
  `to` is before `from`).
  """
  @spec ensure_partitions_between(module(), Date.t(), Date.t()) ::
          [{:ok, String.t()} | {:error, term()}]
  def ensure_partitions_between(repo, %Date{} = from, %Date{} = to) do
    from
    |> months_between(to)
    |> Enum.map(&ensure_partition(repo, &1))
  end

  @doc """
  The `CREATE TABLE IF NOT EXISTS … PARTITION OF aud_event` statements for the month of
  `anchor` and each of the next `months_ahead` calendar months — the partitions
  `ensure_upcoming_partitions/3` makes, as SQL for a migration to `execute`.

  The generated `aud_event` migration runs these with `Date.utc_today()`, so a fresh
  database can take audit writes as soon as it is migrated, not from the first daily
  roll-forward on.
  """
  @spec upcoming_partition_sql(Date.t(), non_neg_integer()) :: [String.t()]
  def upcoming_partition_sql(%Date{} = anchor, months_ahead)
      when is_integer(months_ahead) and months_ahead >= 0 do
    first = first_of_month(anchor)

    first
    |> months_between(Date.shift(first, month: months_ahead))
    |> Enum.map(fn month ->
      {name, from_ts, to_ts} = partition_spec(month)
      create_partition_sql(name, from_ts, to_ts)
    end)
  end

  # The first of each month from the month of `from` through the month of `to`, inclusive.
  defp months_between(from, to) do
    last = first_of_month(to)

    from
    |> first_of_month()
    |> Stream.iterate(&Date.shift(&1, month: 1))
    |> Enum.take_while(&(Date.compare(&1, last) != :gt))
  end

  @doc """
  Ensure a partition for every month from the EARLIEST attached partition through
  `anchor + months_ahead` months: `ensure_upcoming_partitions/3` plus any gap behind it.

  For a database that starts at a migration-seeded launch month and is first used later —
  a test database, which is rebuilt on every run. A production database has a partition
  for every month since launch, each made while it was current; a test database built
  with only the current months lacks last month's, so a test writing a row a day in the
  past failed on the 1st of every month. Not for the production roll-forward: a gap
  behind the latest month there may be a detached partition, which must not be recreated.
  """
  @spec ensure_contiguous_partitions(module(), Date.t(), non_neg_integer()) ::
          [{:ok, String.t()} | {:error, term()}]
  def ensure_contiguous_partitions(repo, %Date{} = anchor, months_ahead)
      when is_integer(months_ahead) and months_ahead >= 0 do
    first = first_of_month(anchor)

    earliest =
      repo
      |> list_partitions()
      |> Enum.flat_map(fn {name, _, _} -> partition_month(name) end)
      |> Enum.min(Date, fn -> first end)

    ensure_partitions_between(repo, Enum.min([earliest, first], Date), Date.shift(first, month: months_ahead))
  end

  defp partition_month("aud_event_y" <> <<y::binary-size(4), "m", m::binary-size(2)>>),
    do: [Date.new!(String.to_integer(y), String.to_integer(m), 1)]

  defp partition_month(_other), do: []

  # ---------------------------------------------------------------------------
  # DEFAULT partition, runway, and the loud signal (ARCH-9)
  # ---------------------------------------------------------------------------

  @doc "The DEFAULT partition's table name (`\"aud_event_default\"`)."
  @spec default_partition_name() :: String.t()
  def default_partition_name, do: @default_partition

  @doc """
  The statement that creates the DEFAULT partition of `aud_event` (idempotent), for a migration to `execute`
  and for the move in `ensure_partition/2`. A row whose `aud_occurred_at` is in no monthly partition lands
  here instead of failing the (audited, hence blocking) write.
  """
  @spec default_partition_sql() :: String.t()
  def default_partition_sql, do: "CREATE TABLE IF NOT EXISTS #{@default_partition} PARTITION OF aud_event DEFAULT"

  @doc "Days of partitions ahead below which the runway is a warning (config `:partition_runway_warn_days`, default 31)."
  @spec runway_warn_days() :: pos_integer()
  def runway_warn_days, do: Application.get_env(:samen_core, :partition_runway_warn_days, @runway_warn_days)

  @runway_sql """
  SELECT p.relname::text,
         c.relname::text,
         COALESCE(pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT', false),
         (m)[1]::timestamptz,
         (m)[2]::timestamptz
  FROM pg_partitioned_table pt
  JOIN pg_class p ON p.oid = pt.partrelid
  JOIN pg_namespace n ON n.oid = p.relnamespace AND n.nspname = 'public'
  LEFT JOIN pg_inherits i ON i.inhparent = p.oid
  LEFT JOIN pg_class c ON c.oid = i.inhrelid
  LEFT JOIN LATERAL regexp_match(
    pg_get_expr(c.relpartbound, c.oid),
    'FROM \\(''([^'']+)''\\) TO \\(''([^'']+)''\\)') AS m ON true
  WHERE pt.partstrat = 'r'
  ORDER BY p.relname, c.relname
  """

  @doc """
  How far ahead partitions exist, for EVERY range-partitioned table in `public` (read from the catalog, so a
  future partitioned table is covered without a code change). `{:ok, rows}`; one map per table:

    * `:table`, `:runway_days` — whole days from now to the end of the contiguous run of partitions that
      starts at the one covering now. `0` when no partition covers now but a later one exists; negative
      (days since the last partition ended) when every partition is in the past.
    * `:covered_until` — that end, a `DateTime`.
    * `:default_partition?`, `:default_rows` — whether a DEFAULT partition exists and how many rows it holds.
    * `:status` — `:ok | :warn | :critical`, and `:reasons` (non-empty unless `:ok`): `:runway_critical`
      (runway <= 0), `:runway_low` (< `runway_warn_days/0`), `:default_rows` (rows are in DEFAULT: they landed
      outside every window), `:no_default_partition` (the safety net is missing).

  `{:error, reason}` when the catalog cannot be read or a bound cannot be understood. That is UNKNOWN, and every
  consumer (`observe_runway/1`, `Samen.Web.Readiness`) reports it as unknown — never as healthy.

  Options: `:now` (a `DateTime`, for tests).
  """
  @spec runway(module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runway(repo, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with {:ok, %{rows: rows}} <- repo.query(@runway_sql),
         {:ok, tables} <- group_runway_rows(rows),
         {:ok, built} <- build_runway(repo, tables, now) do
      {:ok, built}
    end
  end

  # Rows → %{table => %{ranges: [{lo, hi}], default: name | nil}}; an unreadable bound is an error, not a gap.
  defp group_runway_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn [table, child, default?, lo, hi], {:ok, acc} ->
      entry = Map.get(acc, table, %{ranges: [], default: nil})

      cond do
        child == nil ->
          {:cont, {:ok, Map.put(acc, table, entry)}}

        default? ->
          {:cont, {:ok, Map.put(acc, table, %{entry | default: child})}}

        lo != nil and hi != nil ->
          {:cont, {:ok, Map.put(acc, table, %{entry | ranges: [{lo, hi} | entry.ranges]})}}

        true ->
          {:halt, {:error, {:unreadable_partition_bound, table}}}
      end
    end)
  end

  defp build_runway(repo, tables, now) do
    tables
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {table, %{ranges: ranges, default: default}}, {:ok, acc} ->
      case default_row_count(repo, default) do
        {:ok, default_rows} ->
          {:cont, {:ok, [runway_row(table, ranges, default, default_rows, now) | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp default_row_count(_repo, nil), do: {:ok, 0}

  defp default_row_count(repo, default) do
    case repo.query("SELECT count(*) FROM ONLY \"#{String.replace(default, "\"", "\"\"")}\"") do
      {:ok, %{rows: [[n]]}} -> {:ok, n}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runway_row(table, ranges, default, default_rows, now) do
    covered_until = covered_until(Enum.sort(ranges), now)
    runway_days = div(DateTime.diff(covered_until, now, :second), 86_400)
    warn_days = runway_warn_days()

    reasons =
      Enum.reject(
        [
          if(runway_days <= 0, do: :runway_critical),
          if(runway_days > 0 and runway_days < warn_days, do: :runway_low),
          if(default_rows > 0, do: :default_rows),
          if(default == nil, do: :no_default_partition)
        ],
        &is_nil/1
      )

    status =
      cond do
        :runway_critical in reasons -> :critical
        reasons == [] -> :ok
        true -> :warn
      end

    %{
      table: table,
      runway_days: runway_days,
      covered_until: covered_until,
      default_partition?: default != nil,
      default_rows: default_rows,
      status: status,
      reasons: reasons
    }
  end

  # The end of the contiguous run of ranges that starts at the one covering `now`. When none covers now: `now`
  # itself if a later range exists (a hole at now), else the latest range end (already past, so a negative runway).
  defp covered_until(ranges, now) do
    case Enum.find(ranges, fn {lo, hi} -> DateTime.compare(lo, now) != :gt and DateTime.compare(now, hi) == :lt end) do
      nil ->
        case ranges do
          [] -> now
          _ -> ranges |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime) |> min_dt(now)
        end

      {_lo, hi} ->
        extend(ranges, hi)
    end
  end

  # Latest end, unless a range starts after now (a hole at now, not a lapse): then runway is exactly zero.
  defp min_dt(latest_hi, now), do: if(DateTime.compare(latest_hi, now) == :gt, do: now, else: latest_hi)

  defp extend(ranges, edge) do
    case Enum.find(ranges, fn {lo, _hi} -> DateTime.compare(lo, edge) == :eq end) do
      nil -> edge
      {_lo, hi} -> extend(ranges, hi)
    end
  end

  @doc """
  Emit `runway/2`'s result as telemetry: `[:samen, :audit, :partition, :runway]` per table (measurements
  `runway_days`, `default_rows`; metadata `table`, `status`) — or `[:samen, :audit, :partition, :runway_unknown]`
  (count 1) when the runway could not be read, so an unreadable catalog is a series of its own, never a
  missing point that looks like silence. Returns `:ok`.
  """
  @spec emit_runway({:ok, [map()]} | {:error, term()}) :: :ok
  def emit_runway({:ok, rows}) do
    for %{table: table, status: status, runway_days: days, default_rows: default_rows} <- rows do
      :telemetry.execute(
        [:samen, :audit, :partition, :runway],
        %{runway_days: days, default_rows: default_rows},
        %{table: table, status: status}
      )
    end

    :ok
  end

  def emit_runway({:error, _reason}) do
    :telemetry.execute([:samen, :audit, :partition, :runway_unknown], %{count: 1}, %{})
    :ok
  end

  @doc """
  The loud signal for a row that landed in the DEFAULT partition: one `Logger.error` line and a value-free
  `Samen.Observability.Failure` write report (`[:samen, :core, :write, :error]`, name
  `audit_event_in_default_partition`), plus `[:samen, :audit, :partition, :default_landing]` (the series behind
  `samen.audit.partition.default_landing.count`). Carries no row value, no org, no timestamp. Returns `:ok`.
  """
  @spec report_default_landing(String.t()) :: :ok
  def report_default_landing(table \\ "aud_event") do
    Samen.Observability.Failure.report(:write, :audit_event_in_default_partition, nil, :default_partition, [])
    :telemetry.execute([:samen, :audit, :partition, :default_landing], %{count: 1}, %{table: table})
    :ok
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

      {:error, error} ->
        # A failed listing is not "no partitions": reported (the only consumer, `ensure_contiguous_partitions/3`,
        # then ensures from the current month, which is harmless — but the outage is on record).
        Samen.Observability.Failure.report(:audit_partitions_list, nil, error)
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
