defmodule Samen.Web.Readiness do
  @moduledoc """
  The READINESS probe backing the generated app's `GET /readyz` (WS-F1 / F1.2).

  `/healthz` is LIVENESS only — it proves the BEAM is up and can send a response;
  it says nothing about whether the app can actually serve a governed request.
  Fly's `[[http_service.checks]]` GATES TRAFFIC on its check, so a static-200
  `/healthz` behind that gate sends live traffic to a machine whose Postgres, KMS
  wrapped-DEK store, or Oban queue is unreachable — every real request then 500s.

  `check/1` is the readiness signal: it probes the three dependencies a Samen app
  cannot serve a governed request without —

    * `:repo` — `SELECT 1` round-trips the app Postgres (data + queue + audit + catalog).
    * `:kms`  — the configured `Samen.Kms` adapter answers a cheap, READ-ONLY `attest/1`
                probe, proving the external wrapped-DEK store is reachable (no store →
                no vault decrypt → no governed read).
    * `:oban` — the Oban instance is running (durable jobs/cron/workflows are Postgres rows).

  It returns `{:ok, checks}` only when ALL THREE answer; otherwise `{:error, checks}`,
  where `checks` is a keyword list of `component => :ok | {:error, reason}` so the
  endpoint can report WHICH dependency is down — a 503, never a false 200.

  FAIL-CLOSED: any component that raises, exits, or times out is `{:error, _}`,
  never silently treated as ready.

  ## Advisories — what is wrong but does not take the node out of rotation

  `advisories/1` is a SECOND level, deliberately not part of `check/1`: a finding that every node shares and
  that draining a node cannot fix. Today: the audit-partition runway (`:partitions`, ARCH-9). A 503 for it would
  pull every machine out of rotation over a problem no machine can cure by restarting, while the writes it
  warns about still succeed (they land in the DEFAULT partition). So it is reported in the `/readyz` body and as
  telemetry, and paged on from there (docs/runbooks/alerts.md §7):

    * `:ok`
    * `{:warn, detail}` — fewer than `PartitionManager.runway_warn_days/0` days of partitions ahead, rows sit in
      the DEFAULT partition, or the DEFAULT partition is missing;
    * `{:critical, detail}` — runway zero or negative (the next audited write outside the existing months
      lands in DEFAULT, and with no DEFAULT would fail);
    * `{:unknown, reason}` — the runway could not be computed. NEVER `:ok`: a catalog query that fails is not a
      healthy table.

  `report/1` renders `check/1` + `advisories/1` as the `{status, body}` the controllers send.
  """

  alias Samen.AuditEvent.PartitionManager

  # A subject id that never exists — `attest/1` on it is a pure READ that proves the
  # wrapped-DEK store answered, without minting, unwrapping, or mutating any key.
  @kms_probe_subject "__samen_readiness_probe__"

  @type component :: :repo | :kms | :oban
  @type status :: :ok | {:error, term()}

  @spec check(keyword()) ::
          {:ok, [{component(), status()}]} | {:error, [{component(), status()}]}
  def check(opts) do
    repo = Keyword.fetch!(opts, :repo)
    oban = Keyword.get(opts, :oban, Oban)

    checks = [repo: check_repo(repo), kms: check_kms(), oban: check_oban(oban)]

    if Enum.all?(checks, fn {_component, status} -> status == :ok end),
      do: {:ok, checks},
      else: {:error, checks}
  end

  @type advisory :: :ok | {:warn, String.t()} | {:critical, String.t()} | {:unknown, String.t()}

  @doc """
  The non-gating findings: `[partitions: advisory]` (see the moduledoc). Emits the runway as telemetry too
  (`PartitionManager.emit_runway/1`), so the gauge is as fresh as the probe.
  """
  @spec advisories(keyword()) :: [{:partitions, advisory()}]
  def advisories(opts) do
    repo = Keyword.fetch!(opts, :repo)
    [partitions: partitions_advisory(repo)]
  end

  # The probe must never block or slow `/readyz` (Fly's check has a 2 s budget, and every machine runs it):
  #
  #   * the advisory is CACHED for `@advisory_ttl_ms` (60 s) in `:persistent_term` under `{Readiness, :partitions, repo}`
  #     as `{read_at_ms, advisory}` — per node, not shared, and gone on restart;
  #   * past the TTL it is recomputed in a Task with a hard deadline (`@advisory_deadline_ms`, 500 ms), the query
  #     itself carrying `lock_timeout` (`@advisory_lock_ms`, 300 ms) so a partition move holding the exclusive lock
  #     fails the read fast instead of parking it;
  #   * a recompute that fails or misses its deadline is `{:unknown, _}` — NEVER the old cached value, however
  #     recent it was an hour ago: a stale `:ok` past its TTL is exactly the false health this advisory exists
  #     to prevent. Only a successful read is cached; UNKNOWN is not, so the next probe tries again.
  @advisory_ttl_ms 60_000
  @advisory_deadline_ms 500
  @advisory_lock_ms 300

  defp partitions_advisory(repo) do
    key = {__MODULE__, :partitions, repo}
    now_ms = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {read_at, advisory} when now_ms - read_at < @advisory_ttl_ms ->
        advisory

      _expired_or_missing ->
        case read_partitions(repo) do
          {:unknown, _} = unknown ->
            unknown

          advisory ->
            :persistent_term.put(key, {now_ms, advisory})
            advisory
        end
    end
  end

  @doc "Forget the cached partition advisory of `repo` (tests; a deploy that wants the next probe to read)."
  @spec reset_advisory_cache(module()) :: :ok
  def reset_advisory_cache(repo) do
    :persistent_term.erase({__MODULE__, :partitions, repo})
    :ok
  end

  defp read_partitions(repo) do
    task = Task.async(fn -> compute_partitions(repo) end)

    case Task.yield(task, @advisory_deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, advisory} -> advisory
      {:exit, _reason} -> {:unknown, "runway unreadable (task_exit)"}
      nil -> {:unknown, "runway unreadable (deadline_exceeded)"}
    end
  end

  defp compute_partitions(repo) do
    result = PartitionManager.runway(repo, lock_timeout_ms: @advisory_lock_ms)
    PartitionManager.emit_runway(result)

    case result do
      {:ok, rows} -> worst_advisory(rows)
      {:error, reason} -> {:unknown, unknown_detail(reason)}
    end
  rescue
    e -> {:unknown, unknown_detail(e)}
  catch
    :exit, reason -> {:unknown, unknown_detail(reason)}
  end

  # Value-free: module names only, never a message (a Postgres error can quote a value).
  defp unknown_detail(%{__struct__: module}), do: "runway unreadable (#{inspect(module)})"
  # A table NAME is not a row value, and "which table" is what an operator needs.
  defp unknown_detail({tag, table}) when is_atom(tag) and is_binary(table), do: "runway unreadable (#{tag} #{table})"
  defp unknown_detail({tag, _}) when is_atom(tag), do: "runway unreadable (#{tag})"
  defp unknown_detail(tag) when is_atom(tag), do: "runway unreadable (#{tag})"
  defp unknown_detail(_), do: "runway unreadable"

  defp worst_advisory(rows) do
    case Enum.reject(rows, &(&1.status == :ok)) do
      [] ->
        :ok

      bad ->
        level = if Enum.any?(bad, &(&1.status == :critical)), do: :critical, else: :warn

        detail =
          Enum.map_join(bad, "; ", fn r ->
            "#{r.table}: runway_days=#{r.runway_days} default_rows=#{r.default_rows} " <>
              Enum.join(r.reasons, ",")
          end)

        {level, detail}
    end
  end

  @doc """
  `check/1` + `advisories/1` as `{http_status, body}`: 200 `ready` (plus one `partitions: WARN|CRITICAL|UNKNOWN …`
  line per advisory that is not `:ok`) when every dependency answers, else 503 `not ready` + the component lines.
  """
  @spec report(keyword()) :: {200 | 503, String.t()}
  def report(opts) do
    advisory_lines =
      for {component, advisory} <- advisories(opts), advisory != :ok do
        {level, detail} = advisory
        "#{component}: #{level |> to_string() |> String.upcase()} #{detail}"
      end

    case check(opts) do
      {:ok, _checks} ->
        {200, Enum.join(["ready" | advisory_lines], "\n")}

      {:error, checks} ->
        lines =
          Enum.map(checks, fn
            {component, :ok} -> "#{component}: ok"
            {component, {:error, _reason}} -> "#{component}: FAIL"
          end)

        {503, Enum.join(["not ready" | lines ++ advisory_lines], "\n")}
    end
  end

  defp check_repo(repo) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp check_kms do
    adapter = Samen.Kms.adapter()

    case adapter.attest(@kms_probe_subject) do
      # The store answered (absent/active/shredded are all "reachable").
      {:ok, _attestation} -> :ok
      # The adapter reports its store as unreachable — NOT ready.
      {:error, :unavailable} -> {:error, :unavailable}
      # Any other definitive answer still proves the store responded.
      {:error, _definitive} -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp check_oban(oban) do
    _config = Oban.config(oban)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end
end
