defmodule Samen.MetricsTest do
  use ExUnit.Case, async: true

  alias Samen.Metrics

  describe "bounded_tag_keys/0" do
    test "returns bounded label set" do
      keys = Metrics.bounded_tag_keys()
      assert :action in keys
      assert :route in keys
      assert :result in keys
      assert :tenant_tier in keys
    end

    test "does NOT include forbidden keys" do
      bounded = Metrics.bounded_tag_keys()
      forbidden = Metrics.forbidden_tag_keys()
      assert Enum.empty?(forbidden -- (forbidden -- bounded))
    end
  end

  describe "forbidden_tag_keys/0" do
    test "includes org_id, actor_id, subject_id" do
      forbidden = Metrics.forbidden_tag_keys()
      assert :org_id in forbidden
      assert :actor_id in forbidden
      assert :subject_id in forbidden
    end
  end

  describe "hash_tenant_tier/2" do
    test "returns the tier atom for known tiers" do
      assert Metrics.hash_tenant_tier("org_abc", :free) == :free
      assert Metrics.hash_tenant_tier("org_abc", :starter) == :starter
      assert Metrics.hash_tenant_tier("org_abc", :pro) == :pro
      assert Metrics.hash_tenant_tier("org_abc", :enterprise) == :enterprise
    end

    test "returns :unknown_tier for unknown tiers" do
      assert Metrics.hash_tenant_tier("org_abc", :custom) == :unknown_tier
    end

    test "org_id is NOT in the output label" do
      # The return value is a bounded atom, never the raw org_id.
      # We compare to a known value to avoid cross-type comparison warnings.
      result = Metrics.hash_tenant_tier("org_super_secret_id", :pro)
      assert result == :pro
      assert is_atom(result)
    end
  end

  describe "definitions/0" do
    setup do
      # Telemetry.Metrics needs to be available — it's a transitive dep in prod
      # but not in samen_core's direct deps. We check it's loadable.
      case Code.ensure_loaded(Telemetry.Metrics) do
        {:module, _} -> :ok
        {:error, _} -> {:skip, "Telemetry.Metrics not available in this environment"}
      end
    end

    test "returns a non-empty list" do
      defs = Metrics.definitions()
      assert is_list(defs)
      assert length(defs) > 0
    end

    test "no metric definition uses a forbidden tag" do
      defs = Metrics.definitions()
      forbidden = Metrics.forbidden_tag_keys()

      violations =
        Enum.flat_map(defs, fn metric ->
          tags = Map.get(metric, :tags, [])
          Enum.filter(tags, &(&1 in forbidden))
        end)

      assert violations == [],
             "metrics use forbidden tags: #{inspect(violations)}"
    end

    test "all metrics use only bounded tags" do
      defs = Metrics.definitions()
      bounded = Metrics.bounded_tag_keys()

      Enum.each(defs, fn metric ->
        tags = Map.get(metric, :tags, [])

        Enum.each(tags, fn tag ->
          assert tag in bounded,
                 "metric #{metric_name(metric)} has unbounded tag #{inspect(tag)}"
        end)
      end)
    end
  end

  describe "exemplar_trace_id/0" do
    test "returns nil or a hex string" do
      result = Metrics.exemplar_trace_id()
      assert is_nil(result) or (is_binary(result) and String.match?(result, ~r/^[0-9a-f]+$/))
    end

    test "never returns a raw org_id or actor_id" do
      # The exemplar is a trace_id hex string — not an identifier from the app domain
      result = Metrics.exemplar_trace_id()
      if result do
        # A real trace_id is 32 hex chars; an org_id would not look like this
        assert String.match?(result, ~r/^[0-9a-f]+$/)
      end
    end
  end

  defp metric_name(%{name: name}) when is_list(name), do: Enum.join(name, ".")
  defp metric_name(%{name: name}) when is_binary(name), do: name
  defp metric_name(_), do: "(unknown)"
end
