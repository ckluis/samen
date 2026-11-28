defmodule PawChart.ApiKeyScopeGuardTest do
  @moduledoc """
  This host exposes no JSON:API (no `ash_json_api` dependency; its keys authenticate only the MCP endpoint, whose
  actor carries no `:api_key` map, so key scopes are not enforced there). The scope policy is therefore never
  injected, and the walk below proves both halves: it saw this host's resources (never vacuous), and none of them
  declares a JSON:API type, so none needs the policy.
  """
  use ExUnit.Case, async: true

  test "the host compiles without JSON:API: the walk sees its resources and none is exposed" do
    refute Code.ensure_loaded?(AshJsonApi.Resource)

    report = Samen.ApiKeyScopeGuard.report(Application.fetch_env!(:pawchart, :ash_domains))

    assert report.walked >= 60, "the walk saw only #{report.walked} resources"
    assert report.exposed == []
    assert report.unguarded == []
  end
end
