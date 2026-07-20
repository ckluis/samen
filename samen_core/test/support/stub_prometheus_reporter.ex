defmodule Samen.Test.StubPrometheusReporter do
  @moduledoc """
  A dependency-free stand-in for a Prometheus reporter (WS-F5 F5.1 tests).

  `Samen.Observability.child_specs/2` resolves the reporter module at RUNTIME and
  starts it as `{reporter, arg}`, so a test can inject THIS module instead of the
  real `TelemetryMetricsPrometheus.Core` — proving the egress child is started (and,
  when the flag is off, is ABSENT) without adding the reporter package to the
  framework's deps. It mirrors the reporter contract the framework relies on:

    * `child_spec/1` — a supervisable child (an `Agent` holding the passed arg);
    * `scrape/1`     — returns a text exposition for the registered name.
  """

  @doc "A benign supervisable child holding the reporter arg (the framework's `{reporter, arg}`)."
  def child_spec(arg) do
    name = Keyword.get(arg, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {Agent, :start_link, [fn -> arg end, [name: name]]},
      type: :worker,
      restart: :transient
    }
  end

  @doc "A stub text exposition — proves the controller's scrape path returns a 200 body."
  def scrape(name) do
    metric_count = name |> Agent.get(& &1) |> Keyword.get(:metrics, []) |> length()
    "# stub exposition for #{inspect(name)} (#{metric_count} metrics)\n"
  end
end
