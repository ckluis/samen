defmodule Samen.MetricsEgressTest do
  @moduledoc """
  WS-F5 F5.1 — `Samen.Observability` metrics egress (the Prometheus reporter child).

  The load-bearing guarantee is the DEFAULT: with `metrics_egress?` unset the child
  list is EXACTLY what it was before this unit — no reporter child, no behavior change.
  A stub reporter (`Samen.Test.StubPrometheusReporter`) stands in for the real
  `TelemetryMetricsPrometheus.Core` so the ON path is proven without the framework
  taking on the reporter dep. The RED path proves fail-honesty: egress ON with an
  unavailable reporter RAISES rather than booting an app that exports nothing.
  """

  use ExUnit.Case, async: false

  alias Samen.Observability
  alias Samen.Test.StubPrometheusReporter

  @app :metrics_egress_test_app

  setup do
    on_exit(fn -> Application.delete_env(@app, Observability) end)
    :ok
  end

  defp prometheus_children(specs) do
    Enum.filter(specs, fn
      {mod, _arg} when is_atom(mod) -> true
      _ -> false
    end)
  end

  describe "flag OFF (the default) — a true no-op" do
    test "no Prometheus child is present and the child list is the pre-F5 set" do
      specs = Observability.child_specs(@app)

      assert prometheus_children(specs) == []

      # Exactly the two pre-existing map-spec children: otel-ecto + contention handlers.
      map_ids =
        specs
        |> Enum.filter(&is_map/1)
        |> Enum.map(& &1.id)

      assert {Observability, :otel_ecto, @app} in map_ids
      assert {Observability, :contention_handlers, @app} in map_ids
      assert length(specs) == 2
    end

    test "an unrelated Observability config does not add an egress child" do
      Application.put_env(@app, Observability, wide_event_sinks: [])
      assert prometheus_children(Observability.child_specs(@app)) == []
    end

    test "explicit metrics_egress?: false is also a no-op" do
      assert prometheus_children(Observability.child_specs(@app, metrics_egress?: false)) == []
    end
  end

  describe "flag ON — the reporter child is started" do
    test "opts turn it on and the reporter child carries the metric definitions + name" do
      specs =
        Observability.child_specs(@app,
          metrics_egress?: true,
          prometheus_reporter: StubPrometheusReporter,
          prometheus_name: :metrics_egress_test_reporter
        )

      assert [{StubPrometheusReporter, arg}] = prometheus_children(specs)
      assert Keyword.get(arg, :name) == :metrics_egress_test_reporter
      assert Keyword.get(arg, :metrics) == Samen.Metrics.definitions()
    end

    test "host config turns it on too (the runtime.exs posture)" do
      Application.put_env(@app, Observability,
        metrics_egress?: true,
        prometheus_reporter: StubPrometheusReporter
      )

      assert [{StubPrometheusReporter, arg}] =
               prometheus_children(Observability.child_specs(@app))

      # Default name is derived from the otp_app.
      assert Keyword.get(arg, :name) == :"#{@app}_prometheus"
    end

    test "the started reporter is scrapeable (end-to-end child spec is valid)" do
      [{StubPrometheusReporter, arg}] =
        Observability.child_specs(@app,
          metrics_egress?: true,
          prometheus_reporter: StubPrometheusReporter,
          prometheus_name: :metrics_egress_scrape_reporter
        )
        |> prometheus_children()

      start_supervised!(StubPrometheusReporter.child_spec(arg))

      body = StubPrometheusReporter.scrape(:metrics_egress_scrape_reporter)
      assert is_binary(body)
      assert body =~ "metrics_egress_scrape_reporter"
    end
  end

  describe "RED — fail-honest when egress is on but the reporter is missing" do
    test "an unavailable reporter raises, naming the fix (never a silent empty export)" do
      assert_raise ArgumentError, ~r/reporter .* is not available/, fn ->
        Observability.child_specs(@app,
          metrics_egress?: true,
          prometheus_reporter: Samen.Test.NoSuchReporterModule
        )
      end
    end

    test "a non-module reporter value also raises" do
      assert_raise ArgumentError, ~r/is not available/, fn ->
        Observability.child_specs(@app, metrics_egress?: true, prometheus_reporter: "nope")
      end
    end
  end
end
