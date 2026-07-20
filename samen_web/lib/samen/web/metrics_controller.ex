defmodule Samen.Web.MetricsController do
  @moduledoc """
  The framework Prometheus scrape endpoint (WS-F5 F5.1) — `GET /metrics`.

  Mounted with the one-line host helper `samen_metrics_route/1` (`Samen.Web.Router`),
  so every vertical + generated app exposes the SAME `/metrics` surface at ~0 authored
  LOC. It serves the text-format exposition of `Samen.Metrics.definitions/0` from the
  Prometheus reporter that `Samen.Observability.child_specs/2` starts when the host's
  `metrics_egress?` flag is on.

  ## Self-gating (no flag read, no compile-time dep)

  The reporter module + registered name travel in the route's `private` metadata
  (baked by the macro). `scrape/2` resolves the reporter at REQUEST time and calls
  its `scrape/1` via `apply/3` — so `samen_web` (and any vertical) compiles WITHOUT
  the reporter package on its dep list. Then:

    * egress ON  → the reporter process is running → `scrape/1` returns the exposition
      → `200 text/plain; version=0.0.4`;
    * egress OFF → the reporter was never started (or the dep is absent) → the call
      raises → rescued → `404 metrics egress disabled`.

  So the endpoint is honest by construction: it returns metrics ONLY when a reporter
  is actually exporting them, and a plain 404 otherwise — it never fabricates an empty
  200 that a scraper would read as "up but silent".

  The `/metrics` route carries no PII: `Samen.Metrics.definitions/0` is the
  bounded-cardinality set (label-linted by `mix samen.verify.metric_labels`); raw
  `org_id`/`actor_id`/`subject_id` can never appear as a series label.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  # Prometheus text exposition content type (OpenMetrics 0.0.4).
  @content_type "text/plain; version=0.0.4; charset=utf-8"

  # The default reporter — a bare alias used only as a VALUE, so samen_web compiles
  # without the reporter dep. Hosts that opt into egress add it to their own deps.
  @default_reporter TelemetryMetricsPrometheus.Core

  @doc "The default Prometheus reporter module the macro bakes in when none is given."
  @spec default_reporter() :: module()
  def default_reporter, do: @default_reporter

  @doc """
  Serve the Prometheus exposition for the mount's reporter, or `404` when egress is off.
  """
  def scrape(conn, _params) do
    cfg = conn.private[:samen_metrics] || %{}
    reporter = Map.get(cfg, :reporter) || @default_reporter
    name = Map.get(cfg, :name)

    case safe_scrape(reporter, name) do
      {:ok, exposition} ->
        conn
        |> put_resp_content_type(@content_type)
        |> send_resp(200, exposition)

      :error ->
        send_resp(conn, 404, "metrics egress disabled")
    end
  end

  # Resolve + call the reporter at runtime. Any failure (dep absent, reporter not
  # started, unexpected return) collapses to :error → a 404. Never a fake empty 200.
  defp safe_scrape(reporter, name) when is_atom(reporter) and not is_nil(name) do
    if Code.ensure_loaded?(reporter) and function_exported?(reporter, :scrape, 1) do
      case apply(reporter, :scrape, [name]) do
        exposition when is_binary(exposition) -> {:ok, exposition}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp safe_scrape(_reporter, _name), do: :error
end
