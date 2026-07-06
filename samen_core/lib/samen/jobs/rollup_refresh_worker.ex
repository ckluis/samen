defmodule Samen.Jobs.RollupRefreshWorker do
  @moduledoc """
  The scheduled rollup-refresh worker (T2.1 cron scaffold → T2.3 real
  materialisation; doc §data `trigger :refresh_rollup do … scheduler_cron
  "*/10 * * * *" end`).

  Scheduled every 10 minutes via `Samen.Jobs.default_crontab/0`. Each tick
  rebuilds ALL registered rollups (`Samen.Rollup.rebuild_all/1`) from the raw
  append-only `aud_event` tier — so dashboards read the small `rol_*` summary
  table, never scan raw events live (doc: "dashboards read a rollup, refreshed on
  a schedule — not a live scan").

  ## Repo resolution

  The worker resolves the repo the same way the rest of the kernel does: the Oban
  config's `:repo`, falling back to the configured `:verify_repo` / `:non_pii_repo`
  / `:reveal_grant_repo`. Host apps that configure Oban with their own repo get it
  automatically.

  ## Queue / DLQ

  Queue `:rollups` (concurrency 2 — bounded so refreshes don't compete with OLTP
  writes). `max_attempts: 5` — rollup refreshes are idempotent (truncate +
  recompute), so a transient failure is safely retried and the next cron tick
  also self-heals; discarding after 5 attempts is safe.

  ## Args

  A job may target a subset via `args["rollups"]` (a list of rollup-name strings);
  with no args it rebuilds every registered rollup.
  """
  use Oban.Worker, queue: :rollups, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    case resolve_repo() do
      nil ->
        # Fail closed with a clear diagnostic rather than silently no-op: a rollup
        # refresh with no repo means dashboards go stale without warning.
        Logger.error("[Samen.Jobs.RollupRefreshWorker] no repo configured — cannot refresh rollups")
        {:error, :no_repo_configured}

      repo ->
        {:ok, results} = Samen.Rollup.rebuild_all(repo, spec_opts(args))

        Logger.debug(
          "[Samen.Jobs.RollupRefreshWorker] refreshed rollups job_id=#{job_id} results=#{inspect(results)}"
        )

        :ok
    end
  end

  # Optionally narrow to a subset of rollups by name (args["rollups"]).
  defp spec_opts(%{"rollups" => names}) when is_list(names) do
    wanted = MapSet.new(names, &to_string/1)
    specs = Enum.filter(Samen.Rollup.specs(), fn s -> to_string(s.name) in wanted end)
    [specs: specs]
  end

  defp spec_opts(_), do: []

  defp resolve_repo do
    oban_repo =
      case Application.get_env(:samen_core, Oban) do
        conf when is_list(conf) -> Keyword.get(conf, :repo)
        _ -> nil
      end

    oban_repo ||
      Application.get_env(:samen_core, :verify_repo) ||
      Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo)
  end
end
