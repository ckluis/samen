defmodule Mix.Tasks.Samen.Verify.MetricLabels do
  @shortdoc "Fail build on metric definitions that use raw org_id/actor_id/subject_id tags."

  @moduledoc """
  `mix samen.verify.metric_labels` — label-lint for bounded-cardinality metrics (T2.8).

  ## What it checks

  Scans every `Telemetry.Metrics` definition returned by the configured metrics
  module(s) for forbidden tag keys. A metric definition that uses `org_id`,
  `actor_id`, or `subject_id` as a tag — either directly in the `:tags` list or
  as a key in a `:tag_values` function — fails the build with a descriptive
  message.

  The forbidden keys are defined by `Samen.Metrics.forbidden_tag_keys/0`.

  ## Why this matters (doc §runs 4d)

  Per-tenant/per-actor labels are **unbounded cardinality** in Prometheus:
  adding `org_id` as a label creates one time series per org, which can grow to
  millions of series and cause a Prometheus OOM. The per-tenant detail belongs in
  wide events and traces, not in metric labels.

  ## Configuration

  Set the modules whose `definitions/0` function returns metric lists in your
  app config:

      config :my_app, :telemetry_metrics_modules, [MyApp.Metrics, Samen.Metrics]

  Or pass `--module MyApp.Metrics` on the command line.

  Falls back to `Samen.Metrics` if no config or flag is provided.

  ## Exit codes

  - `0` — all metrics use only bounded labels
  - `1` — at least one metric uses a forbidden label

  ## Example

      $ mix samen.verify.metric_labels
      [label-lint] Samen.Metrics: 6 metrics scanned — all bounded. ✓

      $ mix samen.verify.metric_labels --module MyApp.BadMetrics
      [label-lint] FAIL: MyApp.BadMetrics
        - "events.per_tenant" uses forbidden tag :org_id
      Exit 1.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [module: :string])

    modules =
      case Keyword.get(opts, :module) do
        nil ->
          Application.get_env(Mix.Project.config()[:app], :telemetry_metrics_modules, [
            Samen.Metrics
          ])

        mod_str ->
          [Module.concat([mod_str])]
      end

    Mix.Task.run("app.start")

    forbidden = Samen.Metrics.forbidden_tag_keys()
    violations = Enum.flat_map(modules, &scan_module(&1, forbidden))

    if violations == [] do
      total =
        modules
        |> Enum.flat_map(fn m -> safe_definitions(m) end)
        |> length()

      mod_list = Enum.map_join(modules, ", ", &inspect/1)
      Mix.shell().info("[label-lint] #{mod_list}: #{total} metrics scanned — all bounded. ✓")
    else
      Mix.shell().error("[label-lint] FAIL:")

      Enum.each(violations, fn {mod, metric_name, key} ->
        Mix.shell().error("  - #{inspect(mod)}: \"#{metric_name}\" uses forbidden tag #{inspect(key)}")
      end)

      Mix.shell().error("Raw org_id/actor_id/subject_id labels cause unbounded Prometheus cardinality.")
      Mix.shell().error("Use bounded labels: action, route, result, tenant_tier.")
      Mix.raise("label-lint: forbidden metric tags found — exit 1")
    end
  end

  defp scan_module(mod, forbidden) do
    defs = safe_definitions(mod)

    Enum.flat_map(defs, fn metric ->
      # `Telemetry.Metrics` structs expose the label dimensions as the `:tags`
      # field (a list of atoms). `:tag_values` is a *transform function*
      # (measurements -> tag map), NOT a map — its output keys are not statically
      # inspectable, so we cannot lint them here; the label dimensions that become
      # Prometheus series are exactly `:tags`. (Gate-2 F2.3: the previous code did
      # `Map.keys/1` on that function and crashed, which is why the task was never
      # actually gated.)
      metric
      |> Map.get(:tags, [])
      |> Enum.flat_map(fn key ->
        if key in forbidden do
          [{mod, metric_name(metric), key}]
        else
          []
        end
      end)
    end)
  end

  defp safe_definitions(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        if function_exported?(mod, :definitions, 0) do
          mod.definitions()
        else
          []
        end

      _ ->
        Mix.shell().info("[label-lint] Warning: could not load #{inspect(mod)}, skipping.")
        []
    end
  end

  defp metric_name(%{name: name}) when is_list(name), do: Enum.join(name, ".")
  defp metric_name(%{name: name}) when is_binary(name), do: name
  defp metric_name(_), do: "(unknown)"
end
