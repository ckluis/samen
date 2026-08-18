defmodule Samen.Gen.AgentTest do
  @moduledoc """
  ADR-047 A7 — unit coverage for `mix samen.gen.agent`'s engine. The end-to-end
  correct-by-construction proof is `priv/gen_agent_probe.exs` (a root-ci gate); these pin
  the spec derivation and the generate-time tool validation.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.Agent

  @app_dir Path.expand("..", __DIR__)

  test "build_spec derives the agent module, name, and tools from the app's mix.exs" do
    spec = Agent.build_spec(app_dir: @app_dir, scope: "Support", name: "Triage", tools: "fetch_record")

    assert spec.app_module == "SamenCore"
    assert spec.agent_module == "SamenCore.Support.TriageAgent"
    assert spec.agent_name == "samen_core.support_triage"
    assert spec.tools == ["fetch_record"]
    assert is_binary(spec.goal)
  end

  test "validate! ACCEPTS opted-in tools" do
    spec = Agent.build_spec(app_dir: @app_dir, scope: "S", name: "N", tools: "search_records,fetch_record")
    assert :ok = Agent.validate!(spec)
  end

  test "validate! REFUSES a non-opted-in tool at generate time (correct-by-construction)" do
    spec = Agent.build_spec(app_dir: @app_dir, scope: "S", name: "N", tools: "not_a_real_tool")

    assert_raise Mix.Error, ~r/not opted-in/, fn -> Agent.validate!(spec) end
  end

  test "a tool-less agent is valid (the FINAL-only default)" do
    spec = Agent.build_spec(app_dir: @app_dir, scope: "S", name: "N")
    assert spec.tools == []
    assert :ok = Agent.validate!(spec)
  end
end
