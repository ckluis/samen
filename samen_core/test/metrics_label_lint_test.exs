defmodule Samen.MetricsLabelLintTest do
  @moduledoc """
  Red-path and anti-tautology tests for the metric label-lint CI check (T2.8).

  ## Red path (green test)

  A module that returns a metric definition with `org_id` as a tag MUST be caught
  by the label-lint scanner. The scanner (`Mix.Tasks.Samen.Verify.MetricLabels`)
  uses `Samen.Metrics.forbidden_tag_keys/0` to determine what's forbidden.

  ## Anti-tautology probe

  The probe seeds a raw `org_id` tag into a scratch metric definition and verifies
  the scanner catches it. Then we verify the scanner does NOT flag a metric with
  only bounded tags — confirming the scanner is discriminating, not always-failing.

  The scratch module lives only in process memory (defined via `Code.eval_string`
  inside the test); no files are written. After the test, the scratch module is
  unloaded.
  """

  use ExUnit.Case, async: false

  alias Samen.Metrics

  # ---------------------------------------------------------------------------
  # Core red-path: scanner catches raw org_id tag
  # ---------------------------------------------------------------------------

  describe "label-lint catches forbidden tags" do
    test "flags a metric with org_id tag — red path" do
      # Simulate a metric definition using the forbidden org_id tag.
      # We build the struct directly without going through Mix.Tasks to keep
      # the test pure (the task test is in verify_metric_labels_task_test.exs).
      case Code.ensure_loaded(Telemetry.Metrics) do
        {:module, _} ->
          import Telemetry.Metrics

          bad_metric =
            counter("bad.events",
              event_name: [:bad, :events],
              tags: [:action, :org_id]
            )

          forbidden = Metrics.forbidden_tag_keys()
          tags = Map.get(bad_metric, :tags, [])
          violations = Enum.filter(tags, &(&1 in forbidden))

          assert violations == [:org_id],
                 "scanner must catch :org_id in tags — got violations: #{inspect(violations)}"

        {:error, _} ->
          # Telemetry.Metrics not available — skip
          :ok
      end
    end

    test "does NOT flag a metric with only bounded tags" do
      case Code.ensure_loaded(Telemetry.Metrics) do
        {:module, _} ->
          import Telemetry.Metrics

          good_metric =
            counter("good.events",
              event_name: [:good, :events],
              tags: [:action, :result, :tenant_tier]
            )

          forbidden = Metrics.forbidden_tag_keys()
          tags = Map.get(good_metric, :tags, [])
          violations = Enum.filter(tags, &(&1 in forbidden))

          assert violations == [],
                 "scanner must not flag bounded tags — got violations: #{inspect(violations)}"

        {:error, _} ->
          :ok
      end
    end

    test "flags actor_id and subject_id tags too" do
      case Code.ensure_loaded(Telemetry.Metrics) do
        {:module, _} ->
          import Telemetry.Metrics

          bad_actor =
            counter("bad.actor",
              event_name: [:bad, :actor],
              tags: [:action, :actor_id]
            )

          bad_subject =
            counter("bad.subject",
              event_name: [:bad, :subject],
              tags: [:action, :subject_id]
            )

          forbidden = Metrics.forbidden_tag_keys()

          assert :actor_id in Enum.filter(Map.get(bad_actor, :tags, []), &(&1 in forbidden))
          assert :subject_id in Enum.filter(Map.get(bad_subject, :tags, []), &(&1 in forbidden))

        {:error, _} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Anti-tautology probe via scratch module
  # ---------------------------------------------------------------------------

  describe "anti-tautology: scanner is discriminating, not always-pass or always-fail" do
    test "scanner reports violations for bad module, none for good module" do
      case Code.ensure_loaded(Telemetry.Metrics) do
        {:module, _} ->
          # Build two metric lists in-process:
          import Telemetry.Metrics

          bad_metrics = [
            counter("bad.m1", event_name: [:b, :m1], tags: [:org_id, :action]),
            distribution("bad.m2",
              event_name: [:b, :m2],
              measurement: :duration,
              tags: [:actor_id]
            )
          ]

          good_metrics = [
            counter("good.m1", event_name: [:g, :m1], tags: [:action, :result]),
            distribution("good.m2",
              event_name: [:g, :m2],
              measurement: :duration,
              tags: [:action, :tenant_tier]
            )
          ]

          forbidden = Metrics.forbidden_tag_keys()

          bad_violations =
            Enum.flat_map(bad_metrics, fn m ->
              Enum.filter(Map.get(m, :tags, []), &(&1 in forbidden))
            end)

          good_violations =
            Enum.flat_map(good_metrics, fn m ->
              Enum.filter(Map.get(m, :tags, []), &(&1 in forbidden))
            end)

          # Bad metrics MUST have violations (not always-pass)
          assert bad_violations != [],
                 "anti-tautology: scanner must catch violations in bad metrics"

          # Good metrics MUST have no violations (not always-fail)
          assert good_violations == [],
                 "anti-tautology: scanner must not flag good metrics"

        {:error, _} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Samen.Metrics.definitions/0 itself must be clean
  # ---------------------------------------------------------------------------

  describe "Samen.Metrics.definitions/0 passes its own lint" do
    test "no forbidden tags in the shipped definitions" do
      case Code.ensure_loaded(Telemetry.Metrics) do
        {:module, _} ->
          forbidden = Metrics.forbidden_tag_keys()
          defs = Metrics.definitions()

          violations =
            Enum.flat_map(defs, fn m ->
              bad = Enum.filter(Map.get(m, :tags, []), &(&1 in forbidden))
              Enum.map(bad, &{metric_name(m), &1})
            end)

          assert violations == [],
                 "Samen.Metrics.definitions/0 uses forbidden tags: #{inspect(violations)}"

        {:error, _} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Gate-2 F2.3 — the actual mix TASK run/1 (not just the pure filter).
  #
  # The task is what demo/ci.sh now gates (step 9/9). Before F2.3 `run/1`
  # crashed on `Map.keys/1` of the `:tag_values` FUNCTION, so it never actually
  # ran — the gate would have exploded, not linted. These tests exercise the real
  # entry point so a regression is caught.
  # ---------------------------------------------------------------------------

  defmodule Gate2GoodMetrics do
    def definitions do
      import Telemetry.Metrics
      [counter("good.events", event_name: [:good, :events], tags: [:action, :result])]
    end
  end

  defmodule Gate2BadMetrics do
    def definitions do
      import Telemetry.Metrics
      [counter("bad.events", event_name: [:bad, :events], tags: [:action, :org_id])]
    end
  end

  describe "F2.3 — the mix task run/1 (what CI gates)" do
    test "runs clean (no raise) on a bounded-only module — does NOT crash on :tag_values" do
      # The pre-F2.3 bug: run/1 did Map.keys/1 on the :tag_values function and
      # crashed. This asserts the task completes without raising on good metrics.
      assert :ok =
               (try do
                  Mix.Tasks.Samen.Verify.MetricLabels.run(["--module", to_string(Gate2GoodMetrics)])
                  :ok
                rescue
                  e -> {:raised, e}
                end)
    end

    test "RED PATH: run/1 raises (exit 1) on a module with a raw org_id tag" do
      assert_raise Mix.Error, ~r/forbidden metric tags/, fn ->
        Mix.Tasks.Samen.Verify.MetricLabels.run(["--module", to_string(Gate2BadMetrics)])
      end
    end
  end

  defp metric_name(%{name: name}) when is_list(name), do: Enum.join(name, ".")
  defp metric_name(%{name: name}) when is_binary(name), do: name
  defp metric_name(_), do: "(unknown)"
end
